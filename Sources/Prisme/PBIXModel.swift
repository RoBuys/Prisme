import Foundation
import CXpress9

/// Reads the data model of a .pbix file: XPress9-compressed Analysis Services backup (ABF)
/// holding `metadata.sqlitedb` (tables, columns, measures, relationships, Power Query partitions).
enum PBIXDataModel {
    static let header = "This backup was created using XPress9 compression."

    /// Decompresses the DataModel stream (102-byte UTF-16 header, then blocks of
    /// [uncompressed size][compressed size][compressed bytes]).
    static func decompress(_ data: Data) throws -> Data {
        let headerSize = 102
        guard data.count > headerSize,
              let text = String(data: data.prefix(100), encoding: .utf16LittleEndian), text.hasPrefix("This backup") else {
            throw ImportError(message: L("Modèle de données au format inconnu."))
        }
        guard text.contains("XPress9") else { return data.dropFirst(headerSize) }
        guard let ctx = prisme_xpress9_create() else { throw ImportError(message: L("Impossible d'initialiser le décodeur XPress9.")) }
        defer { prisme_xpress9_destroy(ctx) }
        var out = Data()
        var offset = headerSize
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        while offset + 8 <= bytes.count {
            let uncompressed = u32(offset), compressed = u32(offset + 4)
            offset += 8
            guard compressed > 0, uncompressed > 0, offset + compressed <= bytes.count else { break }
            var buffer = [UInt8](repeating: 0, count: uncompressed)
            let n = bytes.withUnsafeBufferPointer { src in
                buffer.withUnsafeMutableBufferPointer { dst in
                    prisme_xpress9_decompress(ctx, src.baseAddress! + offset, Int32(compressed), dst.baseAddress!, Int32(uncompressed))
                }
            }
            guard n > 0 else { throw ImportError(message: L("Échec de la décompression du modèle de données.")) }
            out.append(contentsOf: buffer.prefix(Int(n)))
            offset += compressed
        }
        return out
    }

    /// Finds the SQLite metadata database inside the backup (its size comes from the SQLite header).
    static func metadataDatabase(in backup: Data) -> Data? {
        let magic = Data("SQLite format 3\u{0}".utf8)
        var search = backup.startIndex..<backup.endIndex
        while let r = backup.range(of: magic, in: search) {
            let start = r.lowerBound
            guard start + 100 <= backup.endIndex else { return nil }
            let h = [UInt8](backup[start..<start + 100])
            var pageSize = Int(h[16]) << 8 | Int(h[17])
            if pageSize == 1 { pageSize = 65_536 }
            let pages = Int(h[28]) << 24 | Int(h[29]) << 16 | Int(h[30]) << 8 | Int(h[31])
            let size = pageSize * pages
            if pageSize >= 512, pages > 0, start + size <= backup.endIndex {
                return backup[start..<start + size]
            }
            search = r.upperBound..<backup.endIndex
        }
        return nil
    }

    /// Reads tables, columns, measures, Power Query sources and relationships from a DataModel stream.
    static func model(_ dataModel: Data) throws -> ([PBITableSpec], [PBIRelSpec]) {
        let backup = try decompress(dataModel)
        guard let db = metadataDatabase(in: backup) else {
            throw ImportError(message: L("Métadonnées du modèle introuvables."))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-metadata-\(UUID().uuidString).sqlitedb")
        try db.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try parseMetadata(url.path)
    }

    private static func rows(_ path: String, _ sql: String) throws -> [[String]] {
        try SQLiteReader.query(path: path, sql: sql).dropFirst().map { row in
            row.map { c in
                switch c {
                case .text(let s): s
                case .number(let d): Fmt.plain(d)
                default: ""
                }
            }
        }
    }

    static func dataType(_ code: String) -> String {
        switch code {
        case "6": "int64"
        case "8": "double"
        case "9": "dateTime"
        case "10": "decimal"
        case "11": "boolean"
        default: "string"
        }
    }

    static func parseMetadata(_ path: String) throws -> ([PBITableSpec], [PBIRelSpec]) {
        var names: [String: String] = [:]
        var order: [String] = []
        for r in try rows(path, "SELECT ID, Name FROM [Table] ORDER BY ID") {
            let name = r[1]
            if name.hasPrefix("H$") || name.hasPrefix("R$") || name.hasPrefix("U$") || PowerBIImporter.isAutoDateTable(name) { continue }
            names[r[0]] = name
            order.append(r[0])
        }
        var specs: [String: PBITableSpec] = Dictionary(uniqueKeysWithValues: order.map { ($0, PBITableSpec(name: names[$0]!)) })
        var columnNames: [String: (String, String)] = [:]
        let columnSQL = "SELECT ID, TableID, ExplicitName, InferredName, ExplicitDataType, InferredDataType, Type, SourceColumn, Expression FROM Column ORDER BY TableID, ID"
        for r in try rows(path, columnSQL) {
            guard let table = names[r[1]], r[6] != "3" else { continue }
            let name = r[2].isEmpty ? r[3] : r[2]
            columnNames[r[0]] = (table, name)
            let type = dataType(r[4] == "1" || r[4].isEmpty ? r[5] : r[4])
            let calculated = r[6] == "2"
            specs[r[1]]?.columns.append(PBIColumnSpec(name: name, dataType: type, sourceColumn: r[7].isEmpty ? nil : r[7],
                                                      expression: calculated ? r[8] : nil))
        }
        for r in try rows(path, "SELECT TableID, Name, Expression, FormatString FROM Measure ORDER BY ID") {
            specs[r[0]]?.measures.append((r[1], r[2].trimmingCharacters(in: .whitespacesAndNewlines), r[3].isEmpty ? nil : r[3]))
        }
        for r in try rows(path, "SELECT TableID, Type, QueryDefinition FROM Partition ORDER BY ID") {
            guard specs[r[0]] != nil else { continue }
            if r[1] == "2" { specs[r[0]]?.calculated = true; specs[r[0]]?.calcExpression = r[2] }
            else if r[1] == "4", specs[r[0]]?.mExpression == nil, !r[2].isEmpty { specs[r[0]]?.mExpression = r[2] }
        }
        var rels: [PBIRelSpec] = []
        for r in try rows(path, "SELECT FromColumnID, ToColumnID, IsActive, CrossFilteringBehavior FROM Relationship") {
            guard let f = columnNames[r[0]], let t = columnNames[r[1]] else { continue }
            rels.append(PBIRelSpec(fromTable: f.0, fromColumn: f.1, toTable: t.0, toColumn: t.1,
                                   active: r[2] != "0", bothDirections: r[3] == "2"))
        }
        return (order.compactMap { specs[$0] }, rels)
    }
}
