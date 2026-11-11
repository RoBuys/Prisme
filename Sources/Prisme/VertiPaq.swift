import Foundation

// Decodes the column data stored in a .pbix data model (VertiPaq storage).
//
// Format knowledge comes from pbixray (https://github.com/Hugoberry/pbixray, MIT License) and its Huffman kernel
// xmhuffman (https://github.com/Hugoberry/xmhuffman-cython, MIT License), both by Igor Cotruta, and from
// Microsoft's [MS-XLDM] documentation. The Huffman decoder below is a Swift port of xmhuffman's algorithm.

// MARK: - Binary reader

struct BinaryReader {
    let bytes: [UInt8]
    var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var atEnd: Bool { position >= bytes.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, position + n <= bytes.count else { throw ImportError(message: L("Données du modèle tronquées.")) }
        defer { position += n }
        return bytes[position..<position + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u32() throws -> UInt32 {
        try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func u64() throws -> UInt64 {
        try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    mutating func data(_ n: Int) throws -> [UInt8] { Array(try take(n)) }

    mutating func skip(_ n: Int) throws { _ = try take(n) }

    mutating func expect(_ tag: [UInt8]) throws {
        guard Array(try take(tag.count)) == tag else { throw ImportError(message: L("Structure de colonne inattendue.")) }
    }
}

// MARK: - ABF archive (Analysis Services backup)

struct ABFArchive {
    let data: Data
    private(set) var files: [String: (offset: Int, size: Int)] = [:]
    private(set) var errorCode = false
    private(set) var compressed = false

    /// Text of an XML blob in UTF-8 or UTF-16, without its declaration (XMLParser would trust it).
    private static func xml(_ d: Data) -> XNode? {
        var text: String?
        if d.starts(with: [0xFF, 0xFE]) || (d.count > 1 && d[d.startIndex + 1] == 0) {
            text = String(data: d, encoding: .utf16LittleEndian)
        } else {
            text = String(data: d, encoding: .utf8)
        }
        guard var t = text?.replacingOccurrences(of: "\u{0}", with: "") else { return nil }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        if let r = t.range(of: "?>"), t.hasPrefix("<?xml") { t = String(t[r.upperBound...]) }
        return DOMBuilder.parse(Data(t.utf8))
    }

    private static func child(_ n: XNode, _ name: String) -> String? { n.children.first { $0.name == name }?.text }

    init(_ backup: Data) throws {
        data = backup
        guard backup.count > 4096, let header = Self.xml(backup.subdata(in: 72..<4096)) else {
            throw ImportError(message: L("Archive du modèle illisible."))
        }
        errorCode = Self.child(header, "ErrorCode") == "true"
        compressed = Self.child(header, "ApplyCompression") == "true"
        guard let vOffset = Self.child(header, "m_cbOffsetHeader").flatMap(Int.init),
              let vSize = Self.child(header, "DataSize").flatMap(Int.init), vOffset + vSize <= backup.count,
              let directory = Self.xml(backup.subdata(in: vOffset..<vOffset + vSize)) else {
            throw ImportError(message: L("Archive du modèle illisible."))
        }
        var virtual: [String: (Int, Int)] = [:]
        var lastLog: (Int, Int)?
        for f in directory.children where f.name == "BackupFile" {
            guard let path = Self.child(f, "Path"), let size = Self.child(f, "Size").flatMap(Int.init),
                  let offset = Self.child(f, "m_cbOffsetHeader").flatMap(Int.init) else { continue }
            virtual[path] = (offset, size)
            lastLog = (offset, size)
        }
        guard let (lo, ls) = lastLog, lo + ls <= backup.count else { throw ImportError(message: L("Archive du modèle illisible.")) }
        guard let log = Self.xml(backup.subdata(in: lo..<lo + ls - (errorCode ? 4 : 0))) else {
            throw ImportError(message: L("Archive du modèle illisible."))
        }
        for file in log.descendants("BackupFile") {
            guard let path = Self.child(file, "Path"), let storage = Self.child(file, "StoragePath"),
                  let entry = virtual[storage] else { continue }
            let name = path.split(separator: "\\").last.map(String.init) ?? path
            files[name] = entry
        }
    }

    func file(_ name: String) -> Data? {
        guard !compressed, let f = files[name] else { return nil }
        let size = f.size - (errorCode ? 4 : 0)
        guard f.offset >= 0, size >= 0, f.offset + size <= data.count else { return nil }
        return data.subdata(in: f.offset..<f.offset + size)
    }
}

// MARK: - Column storage

enum VertiPaq {
    static let nullID = 2
    static let firstID = 3

    struct Segment {
        var runs: [(value: UInt32, count: UInt32)] = []
        var packed: [UInt64] = []
    }

    struct SegmentMeta {
        var records = 0
        var minID = 0
        var hasNulls = false
        var bitWidth = 0
        var packedCount = 0
    }

    static func parseIDF(_ d: Data) throws -> [Segment] {
        var r = BinaryReader(d)
        var out: [Segment] = []
        while !r.atEnd {
            var s = Segment()
            let n = Int(try r.u64())
            s.runs.reserveCapacity(n)
            for _ in 0..<n { s.runs.append((try r.u32(), try r.u32())) }
            let m = Int(try r.u64())
            s.packed.reserveCapacity(m)
            for _ in 0..<m { s.packed.append(try r.u64()) }
            out.append(s)
        }
        return out
    }

    private static func bitWidth(_ c: UInt32) -> Int {
        switch c {
        case 703_031...703_040: Int(c - 703_030)
        case 703_042: 12
        case 703_046: 16
        case 703_051: 21
        case 703_062: 32
        default: 0
        }
    }

    static func parseIDFMeta(_ d: Data) throws -> [SegmentMeta] {
        var r = BinaryReader(d)
        try r.expect([0x3C, 0x31, 0x3A, 0x43, 0x50, 0x00])   // <1:CP
        let n = Int(try r.u64())
        var out: [SegmentMeta] = []
        func segment(_ isSub: Bool) throws -> SegmentMeta {
            try r.expect([0x3C, 0x31, 0x3A, 0x43, 0x53, 0x00])   // <1:CS
            var m = SegmentMeta()
            m.records = Int(try r.u64())
            _ = try r.u64()   // base id
            if !isSub {
                let comp = try r.u32(), subComp = try r.u32()
                if comp == 703_066 { try r.skip(25) }   // RLE facet data
                _ = try r.u32()   // first run value
                try r.expect([0x3C, 0x31, 0x3A, 0x53, 0x53, 0x00])   // <1:SS
                _ = try r.u64()   // distinct states
                m.minID = Int(try r.u32())
                _ = try r.u32()   // max data id
                _ = try r.u32()   // original min segment data id
                _ = try r.i64()   // RLE sort order
                _ = try r.u64()   // row count
                m.hasNulls = try r.u8() != 0
                _ = try r.u64()   // RLE runs
                _ = try r.u64()   // other RLE runs
                try r.skip(6)   // SS:1>
                m.bitWidth = comp == 703_066 ? bitWidth(subComp) : bitWidth(comp)
            }
            if try r.u8() != 0 {
                let sub = try segment(true)
                m.packedCount = sub.records
            }
            try r.skip(6)   // CS:1>
            return m
        }
        for _ in 0..<n { out.append(try segment(false)) }
        return out
    }

    /// Data ids of one segment: RLE runs, where a run marked 0xFFFFFFFF - offset reads bit-packed values.
    static func decode(_ s: Segment, _ meta: SegmentMeta) -> [Int] {
        let base = meta.hasNulls ? nullID : meta.minID
        var packed: [Int] = []
        if meta.packedCount > 0, meta.bitWidth > 0 {
            if s.packed.count == 1 && s.packed[0] == 0 {
                packed = Array(repeating: base, count: meta.packedCount)
            } else {
                let w = meta.bitWidth, perWord = 64 / w
                let mask: UInt64 = w == 64 ? .max : (1 << UInt64(w)) - 1
                packed.reserveCapacity(s.packed.count * perWord)
                for word in s.packed {
                    for k in 0..<perWord { packed.append(Int((word >> UInt64(k * w)) & mask) + base) }
                }
            }
        }
        var out: [Int] = []
        out.reserveCapacity(meta.records)
        var offset = 0
        for run in s.runs {
            var count = Int(run.count)
            if meta.records > 0 {
                if out.count >= meta.records { break }
                count = min(count, meta.records - out.count)
            }
            if count == 0 { continue }
            if Int(run.value) + offset == 0xFFFF_FFFF {
                for i in 0..<count { out.append(offset + i < packed.count ? packed[offset + i] : base) }
                offset += count
            } else {
                out.append(contentsOf: repeatElement(Int(run.value), count: count))
            }
        }
        return out
    }

    // MARK: Dictionaries

    enum DictionaryValues {
        case numbers([Double])
        case strings([String])
    }

    static func parseDictionary(_ d: Data) throws -> DictionaryValues {
        var r = BinaryReader(d)
        let type = try r.i32()
        try r.skip(24)   // hash information
        if type == 0 || type == 1 {
            let n = Int(try r.u64())
            let size = try r.u32()
            var values: [Double] = []
            values.reserveCapacity(n)
            for _ in 0..<n {
                if size == 4 { values.append(Double(try r.i32())) }
                else if type == 1 { values.append(try r.f64()) }
                else { values.append(Double(try r.i64())) }
            }
            return .numbers(values)
        }
        guard type == 2 else { throw ImportError(message: L("Dictionnaire de type inconnu.")) }
        _ = try r.i64()   // string count
        _ = try r.u8()    // store compressed
        _ = try r.i64()   // longest string
        let pageCount = Int(try r.i64())
        enum Page {
            case plain([String])
            case huffman(bits: [UInt8], lengths: [UInt8], totalBits: Int, mode: Int, charset: UInt8)
        }
        var pages: [Page] = []
        for _ in 0..<pageCount {
            _ = try r.u64()   // page mask
            _ = try r.u8()    // contains nulls
            _ = try r.u64()   // start index
            _ = try r.u64()   // string count
            let compressed = try r.u8() != 0
            try r.expect([0xDD, 0xCC, 0xBB, 0xAA])
            if compressed {
                let totalBits = Int(try r.u32())
                let charsetType = try r.u32()
                let length = Int(try r.u64())
                var charset: UInt8 = 0
                if charsetType == 703_121 { charset = try r.u8() }
                _ = try r.u32()   // decode bits
                let packedLengths = try r.data(128)
                _ = try r.u64()   // buffer size
                let bits = try r.data(length)
                var lengths = [UInt8](repeating: 0, count: 256)
                for i in 0..<128 { lengths[2 * i] = packedLengths[i] & 0x0F; lengths[2 * i + 1] = packedLengths[i] >> 4 }
                // mode: 0 = UTF-16 bytes (general), 1 = Latin-1, 2 = single charset byte.
                let mode = charsetType == 703_122 ? 0 : (charset == 0 ? 1 : 2)
                pages.append(.huffman(bits: bits, lengths: lengths, totalBits: totalBits, mode: mode, charset: charset))
            } else {
                _ = try r.u64()   // remaining store available
                let used = Int(try r.u64())
                let allocation = Int(try r.u64())
                let buffer = try r.data(used * 2)
                try r.skip(max(0, allocation - used * 2))
                let text = String(decoding: buffer.withUnsafeBufferPointer { p in
                    Array(UnsafeRawBufferPointer(p).bindMemory(to: UInt16.self))
                }, as: UTF16.self)
                var parts = text.components(separatedBy: "\u{0}")
                parts.removeLast()
                pages.append(.plain(parts))
            }
            try r.expect([0xCD, 0xAB, 0xCD, 0xAB])
        }
        let handleCount = Int(try r.u64())
        try r.skip(4)
        var handles: [Int: [Int]] = [:]
        for _ in 0..<handleCount {
            let offset = Int(try r.u32()), page = Int(try r.u32())
            handles[page, default: []].append(offset)
        }
        var strings: [String] = []
        for (i, p) in pages.enumerated() {
            switch p {
            case .plain(let s): strings += s
            case .huffman(let bits, let lengths, let total, let mode, let charset):
                strings += Huffman.decodePage(bits: bits, lengths: lengths, offsets: handles[i] ?? [], totalBits: total,
                                              mode: mode, charset: charset)
            }
        }
        return .strings(strings)
    }
}

/// Canonical Huffman decoding of dictionary pages (port of xmhuffman's kernel).
enum Huffman {
    static func decodePage(bits raw: [UInt8], lengths: [UInt8], offsets: [Int], totalBits: Int,
                           mode: Int, charset: UInt8) -> [String] {
        // Bytes come pair-swapped.
        var bytes = raw
        var i = 0
        while i + 1 < bytes.count { bytes.swapAt(i, i + 1); i += 2 }
        var count = [Int](repeating: 0, count: 17)
        var maxLen = 0
        for l in lengths where l > 0 { count[Int(l)] += 1; maxLen = max(maxLen, Int(l)) }
        guard maxLen > 0 else { return offsets.map { _ in "" } }
        var first = [Int](repeating: 0, count: 17)
        var code = 0
        for l in 1...maxLen { code = (code + count[l - 1]) << 1; first[l] = code }
        var table = [UInt16](repeating: 0, count: 1 << maxLen)
        var next = first
        for s in 0..<256 {
            let l = Int(lengths[s])
            guard l > 0 else { continue }
            let c = next[l]
            next[l] += 1
            let pad = maxLen - l
            let entry = UInt16(s << 8 | l)
            for k in 0..<(1 << pad) where (c << pad) + k < table.count { table[(c << pad) + k] = entry }
        }
        func word(_ byte: Int) -> UInt64 {
            var w: UInt64 = 0
            for k in 0..<8 { w = w << 8 | UInt64(byte + k < bytes.count ? bytes[byte + k] : 0) }
            return w
        }
        let mask = UInt64((1 << maxLen) - 1)
        var out: [String] = []
        out.reserveCapacity(offsets.count)
        for (n, start) in offsets.enumerated() {
            let end = n + 1 < offsets.count ? offsets[n + 1] : totalBits
            var bit = start
            var symbols: [UInt8] = []
            while bit < end {
                let w = word(bit >> 3)
                let idx = Int((w >> UInt64(64 - maxLen - (bit & 7))) & mask)
                let e = table[idx]
                let len = Int(e & 0xFF)
                if len == 0 { break }
                symbols.append(UInt8(e >> 8))
                bit += len
            }
            switch mode {
            case 0:
                let units = stride(from: 0, to: symbols.count - 1, by: 2).map { UInt16(symbols[$0]) | UInt16(symbols[$0 + 1]) << 8 }
                out.append(String(decoding: units, as: UTF16.self))
            case 1:
                out.append(String(symbols.map { Character(UnicodeScalar($0)) }))
            default:
                out.append(String(decoding: symbols.map { UInt16($0) | UInt16(charset) << 8 }, as: UTF16.self))
            }
        }
        return out
    }
}

// MARK: - Tables

extension PBIXDataModel {
    struct StoredColumn {
        var table: String
        var name: String
        var dictionary: String?
        var hidx: String?
        var idfs: [String]
        var dataType: Int
        var baseID: Double
        var magnitude: Double
    }

    static func storedColumns(_ metadataPath: String) throws -> [StoredColumn] {
        let sql = """
        SELECT t.Name, COALESCE(c.ExplicitName, c.InferredName), sfd.FileName, sfh.FileName, sfi.FileName,
               CASE WHEN c.ExplicitDataType = 1 THEN c.InferredDataType ELSE c.ExplicitDataType END, ds.BaseId, ds.Magnitude
        FROM Column c
        JOIN [Table] t ON c.TableID = t.ID
        JOIN ColumnStorage cs ON c.ColumnStorageID = cs.ID
        JOIN AttributeHierarchy ah ON ah.ColumnID = c.ID
        JOIN AttributeHierarchyStorage ahs ON ah.AttributeHierarchyStorageID = ahs.ID
        LEFT JOIN StorageFile sfh ON sfh.ID = ahs.StorageFileID
        LEFT JOIN DictionaryStorage ds ON ds.ID = cs.DictionaryStorageID
        LEFT JOIN StorageFile sfd ON sfd.ID = ds.StorageFileID
        JOIN ColumnPartitionStorage cps ON cps.ColumnStorageID = cs.ID
        JOIN StorageFile sfi ON sfi.ID = cps.StorageFileID
        JOIN PartitionStorage ps ON ps.ID = cps.PartitionStorageID
        WHERE c.Type IN (1, 2, 4)
        ORDER BY t.Name, cs.StoragePosition, ps.StoragePosition
        """
        func text(_ c: RawCell) -> String? { if case .text(let s) = c { return s }; if case .number(let d) = c { return Fmt.plain(d) }; return nil }
        func num(_ c: RawCell) -> Double? { if case .number(let d) = c { return d }; return text(c).flatMap(Double.init) }
        var out: [StoredColumn] = []
        for r in try SQLiteReader.query(path: metadataPath, sql: sql).dropFirst() {
            guard let t = text(r[0]), let n = text(r[1]), let idf = text(r[4]) else { continue }
            if let last = out.last, last.table == t, last.name == n { out[out.count - 1].idfs.append(idf); continue }
            out.append(StoredColumn(table: t, name: n, dictionary: text(r[2]), hidx: text(r[3]), idfs: [idf],
                                    dataType: Int(num(r[5]) ?? 2), baseID: num(r[6]) ?? 0, magnitude: num(r[7]) ?? 1))
        }
        return out
    }

    /// Decodes one column's values in row order (all partitions).
    static func decodeColumn(_ c: StoredColumn, in archive: ABFArchive) throws -> [CellValue] {
        var dictionary: VertiPaq.DictionaryValues?
        if let d = c.dictionary, let data = archive.file(d) { dictionary = try VertiPaq.parseDictionary(data) }
        let valueEncoded = dictionary == nil && c.hidx != nil
        guard dictionary != nil || valueEncoded else { return [] }
        var out: [CellValue] = []
        for idf in c.idfs {
            guard let data = archive.file(idf), let meta = archive.file(idf + "meta") else {
                throw ImportError(message: L("Données de la colonne « %@ » introuvables.", c.name))
            }
            let segments = try VertiPaq.parseIDF(data)
            let metas = try VertiPaq.parseIDFMeta(meta)
            for (s, m) in zip(segments, metas) {
                for id in VertiPaq.decode(s, m) {
                    out.append(cell(id, c, dictionary, valueEncoded: valueEncoded, hasNulls: m.hasNulls))
                }
            }
        }
        return out
    }

    private static let excelEpoch = Date(timeIntervalSince1970: -2_209_161_600)   // 1899-12-30

    private static func cell(_ id: Int, _ c: StoredColumn, _ dict: VertiPaq.DictionaryValues?, valueEncoded: Bool, hasNulls: Bool) -> CellValue {
        var number: Double?
        if valueEncoded {
            if hasNulls && id == VertiPaq.nullID { return .empty }
            number = (Double(id) + c.baseID) / (c.magnitude == 0 ? 1 : c.magnitude)
        } else if let dict {
            let i = id - VertiPaq.firstID
            switch dict {
            case .strings(let s):
                guard i >= 0, i < s.count else { return .empty }
                return s[i].isEmpty ? .empty : .text(s[i])
            case .numbers(let v):
                guard i >= 0, i < v.count else { return .empty }
                number = v[i]
            }
        }
        guard let n = number else { return .empty }
        switch c.dataType {
        case 9: return .date(excelEpoch.addingTimeInterval((n * 86_400).rounded()))
        case 10: return .number(n / 10_000)
        case 11: return .text(n != 0 ? "TRUE" : "FALSE")
        default: return .number(n)
        }
    }

    /// Every stored table's rows, keyed by table then column name.
    static func storedTables(backup: Data, metadataPath: String) throws -> [String: [String: [CellValue]]] {
        let archive = try ABFArchive(backup)
        var out: [String: [String: [CellValue]]] = [:]
        for c in try storedColumns(metadataPath) {
            if let values = try? decodeColumn(c, in: archive), !values.isEmpty {
                out[c.table, default: [:]][c.name] = values
            }
        }
        return out
    }
}

extension PBIXDataModel {
    /// Decodes every stored table of a DataModel stream (compressed backup).
    static func storedTables(_ dataModel: Data) throws -> [String: [String: [CellValue]]] {
        let backup = try decompress(dataModel)
        guard let db = metadataDatabase(in: backup) else { throw ImportError(message: L("Métadonnées du modèle introuvables.")) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-metadata-\(UUID().uuidString).sqlitedb")
        try db.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try storedTables(backup: backup, metadataPath: url.path)
    }
}
