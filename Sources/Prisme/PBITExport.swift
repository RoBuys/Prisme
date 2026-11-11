import AppKit
import Compression
import Foundation
import UniformTypeIdentifiers

/// Writes a Power BI template (.pbit): data model (TMSL) with the data embedded as "Enter data" queries
/// (or the database query for PostgreSQL / MySQL tables), measures, relationships, and the report layout.
enum PBITExporter {
    struct Result {
        var data: Data
        /// What couldn't be exported (visual types, elements).
        var skipped: [String]
    }

    static func export(tables: [DataTable], measures: [Measure], relationships: [Relationship], pages: [ReportPage],
                       culture: String) throws -> Result {
        var skipped: [String] = []
        let schema = modelSchema(tables: tables, measures: measures, relationships: relationships, culture: culture)
        let layout = reportLayout(pages: pages, measures: measures, skipped: &skipped)
        var zip = ZipWriter()
        let parts: [(String, Data)] = [
            ("Version", utf16("1.28")),
            ("DataModelSchema", utf16(try json(schema))),
            ("Report/Layout", utf16(try json(layout))),
            ("Settings", utf16(#"{"Version":4,"ReportSettings":{},"QueriesSettings":{"TypeDetectionEnabled":true,"RelationshipImportEnabled":true}}"#)),
            ("Metadata", utf16(#"{"Version":5,"AutoCreatedRelationships":[],"FileDescription":""}"#)),
        ]
        let overrides = parts.map { name, _ in
            let type = name == "Settings" || name == "Metadata" ? "application/json" : ""
            return #"<Override PartName="/\#(name)" ContentType="\#(type)"/>"#
        }.joined()
        zip.add("[Content_Types].xml", Data((#"<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType=""/>"#
            + overrides + "</Types>").utf8))
        for (name, data) in parts { zip.add(name, data) }
        return Result(data: zip.finish(), skipped: skipped)
    }

    /// UTF-16 little-endian without BOM, as Power BI writes its parts.
    static func utf16(_ s: String) -> Data {
        var d = Data(capacity: s.utf16.count * 2)
        for u in s.utf16 { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        return d
    }

    private static func json(_ o: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    // MARK: Model

    static func dataType(_ c: DataColumn, values: [CellValue]) -> String {
        switch c.type {
        case .text: return "string"
        case .date: return "dateTime"
        case .number:
            return values.allSatisfy { v in v.number.map { $0 == $0.rounded() && abs($0) < 9e15 } ?? true } ? "int64" : "double"
        }
    }

    static func formatString(_ f: MeasureFormat) -> String? {
        switch f {
        case .auto: nil
        case .integer: "#,0"
        case .decimal: "#,0.00"
        case .percent: "0.00%"
        case .currency: "#,0.00 €"
        }
    }

    private static func modelSchema(tables: [DataTable], measures: [Measure], relationships: [Relationship], culture: String) -> [String: Any] {
        var out: [[String: Any]] = []
        for t in tables {
            var columns: [[String: Any]] = []
            var types: [String: String] = [:]
            for (i, c) in t.columns.enumerated() {
                let type = dataType(c, values: t.rows.map { $0[i] })
                types[c.name] = type
                var col: [String: Any] = ["name": c.name, "dataType": type,
                                          "summarizeBy": c.type == .number && type != "string" ? "sum" : "none"]
                if let e = c.expression {
                    col["type"] = "calculated"
                    col["expression"] = e
                    col["isDataTypeInferred"] = true
                } else if t.expression != nil {
                    col["type"] = "calculatedTableColumn"
                    col["sourceColumn"] = "[\(c.name)]"
                    col["isNameInferred"] = true
                    col["isDataTypeInferred"] = true
                } else {
                    col["sourceColumn"] = c.name
                }
                if c.type == .date { col["formatString"] = "General Date" }
                columns.append(col)
            }
            let source: [String: Any]
            if let e = t.expression {
                source = ["type": "calculated", "expression": e]
            } else {
                source = ["type": "m", "expression": mQuery(t, types: types).components(separatedBy: "\n")]
            }
            var table: [String: Any] = ["name": t.name, "columns": columns,
                                        "partitions": [["name": t.name, "mode": "import", "source": source]]]
            let ms = measures.filter { $0.table == t.name }.map { m -> [String: Any] in
                var d: [String: Any] = ["name": m.name, "expression": m.expression]
                if let f = formatString(m.format) { d["formatString"] = f }
                return d
            }
            if !ms.isEmpty { table["measures"] = ms }
            out.append(table)
        }
        let rels = relationships.map { r -> [String: Any] in
            var d: [String: Any] = ["name": UUID().uuidString.lowercased(), "fromTable": r.fromTable, "fromColumn": r.fromColumn,
                                    "toTable": r.toTable, "toColumn": r.toColumn]
            if !r.isActive { d["isActive"] = false }
            return d
        }
        return [
            "name": UUID().uuidString.lowercased(),
            "compatibilityLevel": 1550,
            "model": [
                "culture": culture,
                "dataAccessOptions": ["legacyRedirects": true, "returnErrorValuesAsNull": true],
                "defaultPowerBIDataSourceVersion": "powerBI_V3",
                "sourceQueryCulture": culture,
                "tables": out,
                "relationships": rels,
                "annotations": [["name": "__PBI_TimeIntelligenceEnabled", "value": "0"]],
            ] as [String: Any],
        ]
    }

    // MARK: Power Query

    static func mString(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func mName(_ s: String) -> String {
        let simple = !s.isEmpty && s.first!.isLetter && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return simple ? s : "#" + mString(s)
    }

    private static func mType(_ dataType: String) -> String {
        switch dataType {
        case "int64": "Int64.Type"
        case "double": "type number"
        case "dateTime": "type datetime"
        default: "type text"
        }
    }

    /// The query that loads a table: its PostgreSQL / MySQL query when it has one (and no Prisme steps),
    /// otherwise its current rows embedded in the query.
    static func mQuery(_ t: DataTable, types: [String: String]) -> String {
        if let s = t.source, t.steps.isEmpty, let q = s.query, let host = s.host, let db = s.database,
           s.kind == .postgres || s.kind == .mysql {
            let server = host + (s.port.map { ":\($0)" } ?? "")
            let fn = s.kind == .postgres ? "PostgreSQL.Database" : "MySQL.Database"
            let options = s.kind == .mysql ? "[ReturnSingleDatabase=true, Query=\(mString(q))]" : "[Query=\(mString(q))]"
            return "let\n    Source = \(fn)(\(mString(server)), \(mString(db)), \(options))\nin\n    Source"
        }
        let dataCols = t.columns.enumerated().filter { $0.element.expression == nil }
        let rows: [[Any]] = t.rows.map { r in dataCols.map { i, _ in cellText(r[i]) ?? NSNull() } }
        let json = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        let b64 = deflate(json).base64EncodedString()
        let typeTable = dataCols.map { "\(mName($0.element.name)) = _t" }.joined(separator: ", ")
        let conversions = dataCols.map { "{\(mString($0.element.name)), \(mType(types[$0.element.name] ?? "string"))}" }.joined(separator: ", ")
        return """
        let
            Source = Table.FromRows(Json.Document(Binary.Decompress(Binary.FromText(\(mString(b64)), BinaryEncoding.Base64), Compression.Deflate)), let _t = ((type nullable text) meta [Serialized.Text = true]) in type table [\(typeTable)]),
            #"Changed Type" = Table.TransformColumnTypes(Source, {\(conversions)}, "en-US")
        in
            #"Changed Type"
        """
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fmt.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fmt.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Invariant text of a cell (what "Enter data" stores).
    static func cellText(_ c: CellValue) -> String? {
        switch c {
        case .empty: return nil
        case .text(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .date(let d): return Fmt.calendar.startOfDay(for: d) == d ? isoDay.string(from: d) : isoTime.string(from: d)
        }
    }

    /// Raw DEFLATE (Power Query's Compression.Deflate).
    static func deflate(_ data: Data) -> Data {
        var capacity = data.count + 1024
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = data.withUnsafeBytes { src in
                compression_encode_buffer(&out, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 { return Data(out.prefix(n)) }
            capacity *= 2
        }
    }

    // MARK: Report layout

    static let visualTypes: [VisualType: String] = [
        .column: "clusteredColumnChart", .bar: "clusteredBarChart", .line: "lineChart", .area: "areaChart",
        .pie: "pieChart", .donut: "donutChart", .card: "card", .table: "tableEx", .slicer: "slicer", .matrix: "pivotTable",
        .scatter: "scatterChart", .combo: "lineClusteredColumnComboChart", .gauge: "gauge", .kpi: "kpi", .map: "map",
        .stackedColumn: "columnChart", .stackedBar: "barChart", .percentColumn: "hundredPercentStackedColumnChart",
        .waterfall: "waterfallChart", .funnel: "funnel",
    ]

    private static func hexName() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
    }

    private static func literal(_ s: String) -> [String: Any] {
        ["expr": ["Literal": ["Value": "'" + s.replacingOccurrences(of: "'", with: "''") + "'"]]]
    }

    private static func reportLayout(pages: [ReportPage], measures: [Measure], skipped: inout [String]) -> [String: Any] {
        var sections: [[String: Any]] = []
        for (pi, page) in pages.enumerated() {
            var containers: [[String: Any]] = []
            for (vi, v) in page.visuals.enumerated() {
                let z = Double(vi + 1) * 1000
                let position: [String: Any] = ["x": v.frame.minX, "y": v.frame.minY, "z": z, "width": v.frame.width,
                                               "height": v.frame.height, "tabOrder": z]
                var config: [String: Any] = ["name": hexName(), "layouts": [["id": 0, "position": position]]]
                if v.type == .text {
                    config["singleVisual"] = ["visualType": "textbox", "drillFilterOtherVisuals": true,
                                              "objects": ["general": [["properties": ["paragraphs":
                                                v.element.text.components(separatedBy: "\n").map { ["textRuns": [["value": $0]]] }]]]]]
                } else if let type = visualTypes[v.type] {
                    config["singleVisual"] = singleVisual(v, type: type, measures: measures)
                } else {
                    skipped.append(v.type.label)
                    continue
                }
                containers.append(["x": v.frame.minX, "y": v.frame.minY, "z": z, "width": v.frame.width, "height": v.frame.height,
                                   "config": (try? json(config)) ?? "{}", "filters": "[]"])
            }
            sections.append(["name": "ReportSection" + hexName(), "displayName": page.name, "ordinal": pi, "displayOption": 1,
                             "width": Double(PageSize.width), "height": Double(PageSize.height), "filters": "[]", "config": "{}",
                             "visualContainers": containers])
        }
        let config = #"{"version":"5.43","activeSectionIndex":0,"defaultDrillFilterOtherVisuals":true,"settings":{"useStylableVisualContainerHeader":true}}"#
        return ["id": 0, "sections": sections, "config": config, "layoutOptimization": 0, "resourcePackages": [] as [Any]]
    }

    private static func singleVisual(_ v: Visual, type: String, measures: [Measure]) -> [String: Any] {
        var aliases: [String: String] = [:]
        var from: [[String: Any]] = []
        var select: [[String: Any]] = []
        var names = Set<String>()
        func alias(_ table: String) -> String {
            if let a = aliases[table] { return a }
            let base = String(table.lowercased().first { $0.isLetter } ?? "t")
            var a = base, k = 1
            while aliases.values.contains(a) { a = base + String(k); k += 1 }
            aliases[table] = a
            from.append(["Name": a, "Entity": table, "Type": 0])
            return a
        }
        func source(_ table: String) -> [String: Any] { ["SourceRef": ["Source": alias(table)]] }
        func add(_ item: [String: Any], _ name: String) -> String {
            if names.insert(name).inserted { select.append(item.merging(["Name": name]) { a, _ in a }) }
            return name
        }
        func column(_ f: FieldRef) -> String {
            add(["Column": ["Expression": source(f.table), "Property": f.column]], "\(f.table).\(f.column)")
        }
        func value(_ vf: ValueField) -> String {
            let f = vf.field
            if vf.measure || measures.contains(where: { $0.table == f.table && $0.name == f.column }) {
                return add(["Measure": ["Expression": source(f.table), "Property": f.column]], "\(f.table).\(f.column)")
            }
            let fn: Int = [.sum: 0, .average: 1, .distinctCount: 2, .min: 3, .max: 4, .count: 5][vf.aggregation] ?? 0
            let fname = ["Sum", "Avg", "CountNonNull", "Min", "Max", "Count"][fn]
            return add(["Aggregation": ["Expression": ["Column": ["Expression": source(f.table), "Property": f.column]], "Function": fn]],
                       "\(fname)(\(f.table).\(f.column))")
        }
        func refs(_ names: [String]) -> [[String: Any]] { names.map { ["queryRef": $0] } }

        var projections: [String: [[String: Any]]] = [:]
        let axis = v.axis.map(column)
        let values = v.values.map(value)
        let legend = v.legend.map(column)
        switch v.type {
        case .table:
            projections["Values"] = refs(axis + values)
        case .matrix:
            projections["Rows"] = refs(axis)
            if let l = legend { projections["Columns"] = refs([l]) }
            projections["Values"] = refs(values)
        case .card:
            projections["Values"] = refs(Array(values.prefix(1)))
        case .slicer:
            projections["Values"] = refs(Array(axis.prefix(1)))
        case .scatter:
            projections["Category"] = refs(Array(axis.prefix(1)))
            for (i, role) in ["X", "Y", "Size"].enumerated() where i < values.count { projections[role] = refs([values[i]]) }
        case .combo:
            projections["Category"] = refs(axis)
            for (i, role) in ["Y", "Y2"].enumerated() where i < values.count { projections[role] = refs([values[i]]) }
        case .gauge:
            for (i, role) in ["Y", "TargetValue", "MaxValue"].enumerated() where i < values.count { projections[role] = refs([values[i]]) }
        case .kpi:
            for (i, role) in ["Indicator", "Goal"].enumerated() where i < values.count { projections[role] = refs([values[i]]) }
            projections["TrendLine"] = refs(Array(axis.prefix(1)))
        case .map:
            projections["Category"] = refs(Array(axis.prefix(1)))
            projections["Size"] = refs(Array(values.prefix(1)))
        default:
            projections["Category"] = refs(axis)
            if let l = legend, v.type.isCartesian { projections["Series"] = refs([l]) }
            projections["Y"] = refs(v.type.isPie || v.type == .waterfall || v.type == .funnel ? Array(values.prefix(1)) : values)
        }
        projections = projections.filter { !$0.value.isEmpty }
        var sv: [String: Any] = ["visualType": type, "projections": projections, "drillFilterOtherVisuals": true,
                                 "prototypeQuery": ["Version": 2, "From": from, "Select": select]]
        if !v.showTitle {
            sv["vcObjects"] = ["title": [["properties": ["show": ["expr": ["Literal": ["Value": "false"]]]]]]]
        } else if !v.title.isEmpty {
            sv["vcObjects"] = ["title": [["properties": ["show": ["expr": ["Literal": ["Value": "true"]]], "text": literal(v.title)]]]]
        }
        return sv
    }
}

// MARK: - ZIP (stored entries)

struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le(_ v: UInt32, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }) }

    mutating func add(_ name: String, _ data: Data) {
        let n = Data(name.utf8), crc = Self.crc32(data), size = UInt32(data.count)
        let offset = UInt32(body.count)
        // 0x0800: UTF-8 names. Fixed date (1 Jan 2026) keeps output reproducible.
        let common = Self.le(20, 2) + Self.le(0x0800, 2) + Self.le(0, 2) + Self.le(0, 2) + Self.le(0x5C21, 2)
            + Self.le(crc, 4) + Self.le(size, 4) + Self.le(size, 4) + Self.le(UInt32(n.count), 2) + Self.le(0, 2)
        body += Self.le(0x0403_4B50, 4) + common + n + data
        directory += Self.le(0x0201_4B50, 4) + Self.le(20, 2) + common + Self.le(0, 2) + Self.le(0, 2) + Self.le(0, 2)
            + Self.le(0, 4) + Self.le(offset, 4) + n
        count += 1
    }

    func finish() -> Data {
        body + directory + Self.le(0x0605_4B50, 4) + Self.le(0, 2) + Self.le(0, 2) + Self.le(UInt32(count), 2)
            + Self.le(UInt32(count), 2) + Self.le(UInt32(directory.count), 4) + Self.le(UInt32(body.count), 4) + Self.le(0, 2)
    }
}

// MARK: - Menu action

extension AppState {
    func pbitData() throws -> PBITExporter.Result {
        try PBITExporter.export(tables: tables, measures: measures, relationships: relationships, pages: pages,
                                culture: Loc.language == .fr ? "fr-FR" : "en-US")
    }

    func exportPBIT() {
        let panel = NSSavePanel()
        panel.title = L("Exporter en modèle Power BI")
        panel.allowedContentTypes = [UTType(filenameExtension: "pbit") ?? .data]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? L("Rapport")) + ".pbit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let r = try pbitData()
            try r.data.write(to: url)
            if !r.skipped.isEmpty {
                alertMessage = L("Modèle Power BI exporté. Éléments non exportés : %@.", Array(Set(r.skipped)).sorted().joined(separator: ", "))
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
