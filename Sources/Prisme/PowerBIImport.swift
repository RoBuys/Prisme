import Foundation
import AppKit
import UniformTypeIdentifiers

// Imports Power BI files:
//   .pbit  — zip with DataModelSchema (TMSL JSON) and Report/Layout (JSON), both usually UTF-16
//   .pbip  — project folder: <Name>.SemanticModel (model.bim or TMDL definition/) + <Name>.Report (PBIR definition/ or report.json)
//   .pbix  — zip; only Report/Layout is readable (the data model is a proprietary binary)
// Data isn't stored in .pbit / .pbip: it is reloaded from the sources found in the M queries when Prisme can.

// MARK: - Intermediate description

enum PBIField: Hashable {
    case column(String, String)
    case aggregate(String, String, Int)
    case measure(String, String)
    case level(String, String, String)
}

struct PBIVisualSpec {
    var type: String
    var frame: CGRect
    var title: String?
    var roles: [String: [PBIField]] = [:]
}

struct PBIPageSpec {
    var name: String
    var width: Double
    var height: Double
    var visuals: [PBIVisualSpec] = []
}

struct PBIColumnSpec {
    var name: String
    var dataType: String
    var sourceColumn: String?
    var expression: String?
}

struct PBITableSpec {
    var name: String
    var columns: [PBIColumnSpec] = []
    var measures: [(name: String, expression: String, format: String?)] = []
    var mExpression: String?
    var calculated = false
}

struct PBIRelSpec {
    var fromTable: String, fromColumn: String, toTable: String, toColumn: String
    var active = true
    var bothDirections = false
}

struct PBIProject {
    var tables: [PBITableSpec] = []
    var relationships: [PBIRelSpec] = []
    var pages: [PBIPageSpec] = []
    var hasModel = true
    var folder: URL
}

enum PowerBIImporter {
    static let extensions = ["pbit", "pbip", "pbix"]

    static func read(_ url: URL) throws -> PBIProject {
        switch url.pathExtension.lowercased() {
        case "pbit", "pbix": return try readZip(url)
        case "pbip": return try readProject(url)
        default: throw ImportError(message: L("Format de fichier non pris en charge : .%@", url.pathExtension))
        }
    }

    // MARK: Containers

    private static func readZip(_ url: URL) throws -> PBIProject {
        let dir = try unzip(url)
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = PBIProject(folder: url.deletingLastPathComponent())
        if let schema = try? Data(contentsOf: dir.appendingPathComponent("DataModelSchema")),
           let json = jsonObject(schema) as? [String: Any] {
            (p.tables, p.relationships) = parseTMSL(json)
        } else {
            p.hasModel = false
        }
        guard let layout = try? Data(contentsOf: dir.appendingPathComponent("Report/Layout")),
              let json = jsonObject(layout) as? [String: Any] else {
            throw ImportError(message: L("Mise en page du rapport introuvable dans « %@ ».", url.lastPathComponent))
        }
        p.pages = parseLayout(json)
        return p
    }

    private static func readProject(_ url: URL) throws -> PBIProject {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var reportDir = folder.appendingPathComponent("\(base).Report")
        if let json = jsonObject(try Data(contentsOf: url)) as? [String: Any],
           let artifacts = json["artifacts"] as? [[String: Any]],
           let path = artifacts.compactMap({ ($0["report"] as? [String: Any])?["path"] as? String }).first {
            reportDir = folder.appendingPathComponent(path)
        }
        var modelDir = folder.appendingPathComponent("\(base).SemanticModel")
        if let pbir = try? Data(contentsOf: reportDir.appendingPathComponent("definition.pbir")),
           let json = jsonObject(pbir) as? [String: Any],
           let path = ((json["datasetReference"] as? [String: Any])?["byPath"] as? [String: Any])?["path"] as? String {
            modelDir = reportDir.appendingPathComponent(path).standardizedFileURL
        }
        if !FileManager.default.fileExists(atPath: modelDir.path) {
            modelDir = folder.appendingPathComponent("\(base).Dataset")
        }
        var p = PBIProject(folder: folder)
        if let bim = try? Data(contentsOf: modelDir.appendingPathComponent("model.bim")), let json = jsonObject(bim) as? [String: Any] {
            (p.tables, p.relationships) = parseTMSL(json)
        } else if FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("definition").path) {
            (p.tables, p.relationships) = parseTMDL(modelDir.appendingPathComponent("definition"))
        } else {
            p.hasModel = false
        }
        let defDir = reportDir.appendingPathComponent("definition")
        if FileManager.default.fileExists(atPath: defDir.appendingPathComponent("pages").path) {
            p.pages = parsePBIR(defDir)
        } else if let legacy = try? Data(contentsOf: reportDir.appendingPathComponent("report.json")),
                  let json = jsonObject(legacy) as? [String: Any] {
            p.pages = parseLayout(json)
        } else {
            throw ImportError(message: L("Rapport introuvable dans le projet « %@ ».", url.lastPathComponent))
        }
        return p
    }

    static func unzip(_ url: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-pbi-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "-d", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 1 else {
            throw ImportError(message: L("Le fichier « %@ » n'est pas une archive Power BI valide.", url.lastPathComponent))
        }
        return tmp
    }

    /// JSON in UTF-8 or UTF-16 (Power BI writes Layout and DataModelSchema in UTF-16 LE).
    static func jsonObject(_ data: Data) -> Any? {
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || (data.count > 1 && data[1] == 0) {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard var t = text else { return nil }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return try? JSONSerialization.jsonObject(with: Data(t.utf8))
    }

    // MARK: Model (TMSL JSON)

    private static func text(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let a = v as? [String] { return a.joined(separator: "\n") }
        return nil
    }

    static func isAutoDateTable(_ name: String) -> Bool {
        name.hasPrefix("LocalDateTable_") || name.hasPrefix("DateTableTemplate_")
    }

    static func parseTMSL(_ root: [String: Any]) -> ([PBITableSpec], [PBIRelSpec]) {
        let model = root["model"] as? [String: Any] ?? root
        var tables: [PBITableSpec] = []
        for t in model["tables"] as? [[String: Any]] ?? [] {
            guard let name = t["name"] as? String, !isAutoDateTable(name) else { continue }
            var spec = PBITableSpec(name: name)
            for c in t["columns"] as? [[String: Any]] ?? [] {
                guard let n = c["name"] as? String, (c["type"] as? String) != "rowNumber" else { continue }
                let calc = (c["type"] as? String) == "calculated"
                spec.columns.append(PBIColumnSpec(name: n, dataType: c["dataType"] as? String ?? "string",
                                                  sourceColumn: c["sourceColumn"] as? String,
                                                  expression: calc ? text(c["expression"]) : nil))
            }
            for m in t["measures"] as? [[String: Any]] ?? [] {
                if let n = m["name"] as? String, let e = text(m["expression"]) {
                    spec.measures.append((n, e, m["formatString"] as? String))
                }
            }
            if let part = (t["partitions"] as? [[String: Any]])?.first, let src = part["source"] as? [String: Any] {
                if (src["type"] as? String) == "calculated" { spec.calculated = true }
                else { spec.mExpression = text(src["expression"]) }
            }
            tables.append(spec)
        }
        var rels: [PBIRelSpec] = []
        for r in model["relationships"] as? [[String: Any]] ?? [] {
            guard let ft = r["fromTable"] as? String, let fc = r["fromColumn"] as? String,
                  let tt = r["toTable"] as? String, let tc = r["toColumn"] as? String,
                  !isAutoDateTable(ft), !isAutoDateTable(tt) else { continue }
            rels.append(PBIRelSpec(fromTable: ft, fromColumn: fc, toTable: tt, toColumn: tc,
                                   active: (r["isActive"] as? Bool) ?? true,
                                   bothDirections: (r["crossFilteringBehavior"] as? String) == "bothDirections"))
        }
        return (tables, rels)
    }

    // MARK: Model (TMDL)

    /// Unquotes a TMDL name ('Sales Amount' → Sales Amount, '' → ').
    static func tmdlName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("'"), t.hasSuffix("'"), t.count >= 2 {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return t
    }

    /// Splits "Table.Column" / 'My Table'.'My Column' into its two names.
    static func tmdlQualified(_ s: String) -> (String, String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        var inQuote = false
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "'" {
                let next = t.index(after: i)
                if inQuote, next < t.endIndex, t[next] == "'" { i = t.index(after: next); continue }
                inQuote.toggle()
            } else if c == ".", !inQuote {
                return (tmdlName(String(t[..<i])), tmdlName(String(t[t.index(after: i)...])))
            }
            i = t.index(after: i)
        }
        return nil
    }

    /// Splits "keyword name = value" into (name, value?) honoring quoted names.
    static func tmdlHeader(_ rest: String) -> (name: String, value: String?) {
        var inQuote = false
        let chars = Array(rest)
        var i = 0
        while i < chars.count {
            if chars[i] == "'" { inQuote.toggle() }
            if chars[i] == "=", !inQuote {
                let name = tmdlName(String(chars[..<i]))
                let value = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                return (name, value)
            }
            i += 1
        }
        return (tmdlName(rest), nil)
    }

    private struct TLine {
        let indent: Int
        let text: String
        let raw: String
    }

    private static func tmdlLines(_ s: String) -> [TLine] {
        s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map { raw in
            var tabs = 0, spaces = 0
            for c in raw { if c == "\t" { tabs += 1 } else if c == " " { spaces += 1 } else { break } }
            return TLine(indent: tabs + spaces / 4, text: raw.trimmingCharacters(in: .whitespaces), raw: raw)
        }
    }

    /// Reads a multi-line expression starting after line `i` (lines indented deeper than `level`).
    private static func tmdlExpression(_ lines: [TLine], _ i: inout Int, level: Int, inline: String) -> String {
        if inline == "```" {
            var out: [String] = []
            i += 1
            while i < lines.count, lines[i].text != "```" { out.append(lines[i].raw); i += 1 }
            return dedent(out)
        }
        if !inline.isEmpty { return inline }
        var out: [String] = []
        while i + 1 < lines.count, lines[i + 1].text.isEmpty || lines[i + 1].indent > level {
            i += 1
            out.append(lines[i].raw)
        }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return dedent(out)
    }

    private static func dedent(_ lines: [String]) -> String {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == "\t" || $0 == " " }.count }
        let cut = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(cut, $0.prefix { $0 == "\t" || $0 == " " }.count))) }.joined(separator: "\n")
    }

    static func parseTMDL(_ dir: URL) -> ([PBITableSpec], [PBIRelSpec]) {
        let fm = FileManager.default
        var texts: [String] = []
        let tablesDir = dir.appendingPathComponent("tables")
        for f in (try? fm.contentsOfDirectory(atPath: tablesDir.path))?.sorted() ?? [] where f.hasSuffix(".tmdl") {
            if let s = try? String(contentsOf: tablesDir.appendingPathComponent(f), encoding: .utf8) { texts.append(s) }
        }
        for f in ["relationships.tmdl", "model.tmdl"] {
            if let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) { texts.append(s) }
        }
        var tables: [PBITableSpec] = []
        var rels: [PBIRelSpec] = []
        for text in texts {
            let lines = tmdlLines(text)
            var table: Int?
            var rel: Int?
            var objectKind = "", objectLevel = 0
            var i = 0
            while i < lines.count {
                let l = lines[i]
                defer { i += 1 }
                if l.text.isEmpty || l.text.hasPrefix("///") { continue }
                let parts = l.text.split(separator: " ", maxSplits: 1).map(String.init)
                let keyword = parts[0].lowercased(), rest = parts.count > 1 ? parts[1] : ""
                if l.indent == 0 {
                    table = nil; rel = nil; objectKind = ""
                    if keyword == "table" {
                        let name = tmdlHeader(rest).name
                        if isAutoDateTable(name) { continue }
                        tables.append(PBITableSpec(name: name))
                        table = tables.count - 1
                    } else if keyword == "relationship" {
                        rels.append(PBIRelSpec(fromTable: "", fromColumn: "", toTable: "", toColumn: ""))
                        rel = rels.count - 1
                    }
                    continue
                }
                if let r = rel {
                    let kv = l.text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 || kv.count == 1 else { continue }
                    switch kv[0].lowercased() {
                    case "fromcolumn": if let q = tmdlQualified(kv[1]) { rels[r].fromTable = q.0; rels[r].fromColumn = q.1 }
                    case "tocolumn": if let q = tmdlQualified(kv[1]) { rels[r].toTable = q.0; rels[r].toColumn = q.1 }
                    case "isactive": rels[r].active = kv.count < 2 || kv[1].lowercased() != "false"
                    case "crossfilteringbehavior": rels[r].bothDirections = kv.count > 1 && kv[1].lowercased() == "bothdirections"
                    default: break
                    }
                    continue
                }
                guard let t = table else { continue }
                if l.indent == 1 {
                    objectKind = keyword
                    objectLevel = 1
                    let h = tmdlHeader(rest)
                    switch keyword {
                    case "column":
                        var c = PBIColumnSpec(name: h.name, dataType: "string")
                        if let v = h.value { c.expression = tmdlExpression(lines, &i, level: 2, inline: v) }
                        tables[t].columns.append(c)
                    case "measure":
                        let e = tmdlExpression(lines, &i, level: 2, inline: h.value ?? "")
                        tables[t].measures.append((h.name, e, nil))
                    case "partition":
                        if h.value?.lowercased() == "calculated" { tables[t].calculated = true }
                    default:
                        break
                    }
                    continue
                }
                guard l.indent == objectLevel + 1 else { continue }
                let kv = l.text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let key = kv[0].lowercased()
                switch objectKind {
                case "column":
                    guard var c = tables[t].columns.popLast() else { continue }
                    if key == "datatype", kv.count > 1 { c.dataType = kv[1] }
                    if key == "sourcecolumn", kv.count > 1 { c.sourceColumn = tmdlName(kv[1]) }
                    tables[t].columns.append(c)
                case "measure":
                    if key == "formatstring", kv.count > 1, var m = tables[t].measures.popLast() {
                        m.format = tmdlName(kv[1])
                        tables[t].measures.append(m)
                    }
                case "partition":
                    if l.text.lowercased().hasPrefix("source") {
                        let h = tmdlHeader(String(l.text.dropFirst("source".count)))
                        tables[t].mExpression = tmdlExpression(lines, &i, level: objectLevel + 1, inline: h.value ?? "")
                    }
                default:
                    break
                }
            }
        }
        rels.removeAll { $0.fromTable.isEmpty || $0.toTable.isEmpty || isAutoDateTable($0.fromTable) || isAutoDateTable($0.toTable) }
        // Tables split across files: merge by name.
        var merged: [PBITableSpec] = []
        for t in tables {
            if let i = merged.firstIndex(where: { $0.name == t.name }) {
                merged[i].columns += t.columns
                merged[i].measures += t.measures
                merged[i].mExpression = merged[i].mExpression ?? t.mExpression
                merged[i].calculated = merged[i].calculated || t.calculated
            } else {
                merged.append(t)
            }
        }
        return (merged, rels)
    }

    // MARK: Report (legacy Layout / report.json)

    static func field(_ d: [String: Any], aliases: [String: String]) -> PBIField? {
        func entity(_ e: Any?) -> String? {
            guard let sr = (e as? [String: Any])?["SourceRef"] as? [String: Any] else { return nil }
            return (sr["Entity"] as? String) ?? (sr["Source"] as? String).flatMap { aliases[$0] }
        }
        if let c = d["Column"] as? [String: Any], let p = c["Property"] as? String, let t = entity(c["Expression"]) {
            return .column(t, p)
        }
        if let m = d["Measure"] as? [String: Any], let p = m["Property"] as? String, let t = entity(m["Expression"]) {
            return .measure(t, p)
        }
        if let a = d["Aggregation"] as? [String: Any], let inner = a["Expression"] as? [String: Any],
           case .column(let t, let c)? = field(inner, aliases: aliases) {
            return .aggregate(t, c, a["Function"] as? Int ?? 0)
        }
        if let h = d["HierarchyLevel"] as? [String: Any], let level = h["Level"] as? String,
           let hier = (h["Expression"] as? [String: Any])?["Hierarchy"] as? [String: Any] {
            if let pv = (hier["Expression"] as? [String: Any])?["PropertyVariationSource"] as? [String: Any],
               let col = pv["Property"] as? String, let t = entity(pv["Expression"]) {
                return .level(t, col, level)
            }
            if let t = entity(hier["Expression"]) { return .column(t, level) }
        }
        return nil
    }

    private static func literal(_ v: Any?) -> String? {
        guard let s = ((((v as? [String: Any])?["expr"] as? [String: Any])?["Literal"] as? [String: Any])?["Value"] as? String) else { return nil }
        return s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 ? String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") : s
    }

    private static func title(_ objects: Any?) -> String? {
        guard let t = (objects as? [String: Any])?["title"] as? [[String: Any]],
              let props = t.first?["properties"] as? [String: Any] else { return nil }
        if literal(props["show"]) == "false" { return "" }
        return literal(props["text"])
    }

    static func parseLayout(_ json: [String: Any]) -> [PBIPageSpec] {
        let sections = (json["sections"] as? [[String: Any]] ?? []).sorted { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }
        return sections.map { s in
            var page = PBIPageSpec(name: s["displayName"] as? String ?? L("Page"),
                                   width: s["width"] as? Double ?? 1280, height: s["height"] as? Double ?? 720)
            for vc in s["visualContainers"] as? [[String: Any]] ?? [] {
                guard let cfgText = vc["config"] as? String,
                      let cfg = (try? JSONSerialization.jsonObject(with: Data(cfgText.utf8))) as? [String: Any],
                      let sv = cfg["singleVisual"] as? [String: Any], let type = sv["visualType"] as? String else { continue }
                let frame = CGRect(x: vc["x"] as? Double ?? 0, y: vc["y"] as? Double ?? 0,
                                   width: vc["width"] as? Double ?? 300, height: vc["height"] as? Double ?? 200)
                var spec = PBIVisualSpec(type: type, frame: frame, title: title(sv["vcObjects"]))
                let query = sv["prototypeQuery"] as? [String: Any] ?? [:]
                var aliases: [String: String] = [:]
                for f in query["From"] as? [[String: Any]] ?? [] {
                    if let n = f["Name"] as? String, let e = f["Entity"] as? String { aliases[n] = e }
                }
                var byName: [String: PBIField] = [:]
                for sel in query["Select"] as? [[String: Any]] ?? [] {
                    if let n = sel["Name"] as? String, let f = field(sel, aliases: aliases) { byName[n] = f }
                }
                for (role, items) in sv["projections"] as? [String: [[String: Any]]] ?? [:] {
                    spec.roles[role] = items.compactMap { ($0["queryRef"] as? String).flatMap { byName[$0] } }
                }
                page.visuals.append(spec)
            }
            return page
        }
    }

    // MARK: Report (PBIR)

    static func parsePBIR(_ def: URL) -> [PBIPageSpec] {
        let fm = FileManager.default
        let pagesDir = def.appendingPathComponent("pages")
        var order = (try? fm.contentsOfDirectory(atPath: pagesDir.path))?.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".json") }.sorted() ?? []
        if let meta = try? Data(contentsOf: pagesDir.appendingPathComponent("pages.json")),
           let json = jsonObject(meta) as? [String: Any], let o = json["pageOrder"] as? [String] {
            order = o + order.filter { !o.contains($0) }
        }
        return order.compactMap { name in
            let dir = pagesDir.appendingPathComponent(name)
            guard let pd = try? Data(contentsOf: dir.appendingPathComponent("page.json")),
                  let pj = jsonObject(pd) as? [String: Any] else { return nil }
            var page = PBIPageSpec(name: pj["displayName"] as? String ?? name,
                                   width: pj["width"] as? Double ?? 1280, height: pj["height"] as? Double ?? 720)
            let vDir = dir.appendingPathComponent("visuals")
            for v in (try? fm.contentsOfDirectory(atPath: vDir.path))?.sorted() ?? [] {
                guard let vd = try? Data(contentsOf: vDir.appendingPathComponent(v).appendingPathComponent("visual.json")),
                      let vj = jsonObject(vd) as? [String: Any], let visual = vj["visual"] as? [String: Any],
                      let type = visual["visualType"] as? String else { continue }
                let pos = vj["position"] as? [String: Any] ?? [:]
                let frame = CGRect(x: pos["x"] as? Double ?? 0, y: pos["y"] as? Double ?? 0,
                                   width: pos["width"] as? Double ?? 300, height: pos["height"] as? Double ?? 200)
                var spec = PBIVisualSpec(type: type, frame: frame, title: title(visual["visualContainerObjects"]))
                let state = (visual["query"] as? [String: Any])?["queryState"] as? [String: Any] ?? [:]
                for (role, value) in state {
                    let projections = (value as? [String: Any])?["projections"] as? [[String: Any]] ?? []
                    spec.roles[role] = projections.compactMap { ($0["field"] as? [String: Any]).flatMap { field($0, aliases: [:]) } }
                }
                page.visuals.append(spec)
            }
            return page
        }
    }
}

// MARK: - Data sources from M queries

enum MSource {
    /// String literals of an M expression ("" escapes a quote).
    static func strings(_ m: String) -> [String] {
        var out: [String] = []
        var cur = "", inString = false
        let chars = Array(m)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cur.append("\""); i += 1 }
                    else { out.append(cur); cur = ""; inString = false }
                } else { cur.append(c) }
            } else if c == "\"" {
                inString = true
            }
            i += 1
        }
        return out
    }

    /// First string literal following `function(` in the expression.
    static func argument(_ m: String, after function: String, index: Int = 0) -> String? {
        guard let r = m.range(of: function + "(") else { return nil }
        return strings(String(m[r.upperBound...])).dropFirst(index).first
    }

    /// [Item="x",Kind="Sheet"] style navigation values.
    static func navigation(_ m: String, _ key: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: key + "\\s*=\\s*\"((?:[^\"]|\"\")*)\""),
              let match = re.firstMatch(in: m, range: NSRange(m.startIndex..., in: m)),
              let r = Range(match.range(at: 1), in: m) else { return nil }
        return String(m[r]).replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// Recognizes common sources: CSV / Excel / JSON files, web JSON, PostgreSQL, MySQL.
    static func source(_ m: String) -> (DataSource, String?)? {
        if let path = argument(m, after: "File.Contents") {
            if m.contains("Excel.Workbook") {
                return (DataSource(path: path, sheet: navigation(m, "Item")), path)
            }
            return (DataSource(path: path), path)
        }
        if m.contains("Web.Contents"), let url = argument(m, after: "Web.Contents") {
            return (DataSource(kind: .web, url: url), nil)
        }
        for (fn, kind, defaultPort) in [("PostgreSQL.Database", SourceKind.postgres, 5432), ("MySQL.Database", SourceKind.mysql, 3306)] {
            guard m.contains(fn), let server = argument(m, after: fn), let db = argument(m, after: fn, index: 1) else { continue }
            let hp = server.split(separator: ":")
            var query = navigation(m, "Query")
            if query == nil, let item = navigation(m, "Item") {
                let schema = navigation(m, "Schema")
                query = "SELECT * FROM " + (schema.map { "\($0)." } ?? "") + item
            }
            return (DataSource(kind: kind, query: query, host: String(hp[0]),
                               port: hp.count > 1 ? Int(hp[1]) : defaultPort, database: db), nil)
        }
        return nil
    }
}

// MARK: - Building the Prisme report

extension AppState {
    func importPowerBIWithPanel() {
        let panel = NSOpenPanel()
        panel.title = L("Importer un rapport Power BI")
        panel.allowedContentTypes = PowerBIImporter.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPowerBI(url)
    }

    /// Finds a source file moved from Windows: same name next to the report or in a data/ folder, else asks.
    private func locate(_ original: String, near folder: URL, ask: Bool) -> String? {
        if FileManager.default.fileExists(atPath: original) { return original }
        let name = original.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? original
        for dir in [folder, folder.appendingPathComponent("data"), folder.appendingPathComponent("Data")] {
            let p = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        guard ask else { return nil }
        let panel = NSOpenPanel()
        panel.title = L("Localiser « %@ »", name)
        panel.message = L("Le rapport utilise « %@ ». Indiquez où se trouve ce fichier sur ce Mac (Annuler pour l'ignorer).", original)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func columnType(_ pbi: String) -> ColumnType {
        switch pbi.lowercased() {
        case "int64", "double", "decimal": .number
        case "datetime", "date", "time": .date
        default: .text
        }
    }

    static func measureFormat(_ f: String?) -> MeasureFormat {
        guard let f else { return .auto }
        if f.contains("%") { return .percent }
        if f.contains("€") || f.contains("$") || f.contains("£") { return .currency }
        if f.contains(".0") || f.contains(",0") && f.contains("0.") { return .decimal }
        if f == "0" || f == "#,0" || f == "#,##0" { return .integer }
        return .auto
    }

    func importPowerBI(_ url: URL, askForFiles: Bool = true) {
        let project: PBIProject
        do { project = try PowerBIImporter.read(url) } catch { alertMessage = error.localizedDescription; return }
        guard confirmDiscard() else { return }
        resetDocument()

        var notes: [String] = []
        var loadedCount = 0
        var specs = project.tables
        if !project.hasModel {
            // .pbix: rebuild empty tables from the fields the visuals use.
            var cols: [String: [String: ColumnType]] = [:]
            for p in project.pages { for v in p.visuals { for f in v.roles.values.flatMap({ $0 }) {
                switch f {
                case .column(let t, let c): cols[t, default: [:]][c] = cols[t]?[c] ?? .text
                case .aggregate(let t, let c, let fn): cols[t, default: [:]][c] = [0, 1, 3, 4].contains(fn) ? .number : (cols[t]?[c] ?? .text)
                case .level(let t, let c, _): cols[t, default: [:]][c] = .date
                case .measure: break
                }
            } } }
            specs = cols.keys.sorted().map { t in
                PBITableSpec(name: t, columns: cols[t]!.keys.sorted().map { c in
                    PBIColumnSpec(name: c, dataType: cols[t]![c] == .number ? "double" : cols[t]![c] == .date ? "dateTime" : "string")
                })
            }
            notes.append(L("Fichier .pbix : le modèle et les données ne sont pas lisibles. Les tables ont été recréées vides à partir des champs des visuels ; utilisez « Changer la source… » sur chaque table, et recréez les mesures."))
        }

        for spec in specs {
            if spec.calculated { notes.append(L("Table calculée ignorée : %@", spec.name)); continue }
            let dataCols = spec.columns.filter { $0.expression == nil }
            var table = DataTable(name: spec.name, columns: dataCols.map { DataColumn(name: $0.name, type: Self.columnType($0.dataType)) }, rows: [])
            if let m = spec.mExpression, var (source, path) = MSource.source(m) {
                if let p = path {
                    if let found = locate(p, near: project.folder, ask: askForFiles) { source.path = found } else { path = nil; source.path = "" }
                }
                if source.sourceKind != .file || !source.path.isEmpty {
                    do {
                        let loaded = try Importer.load(source: source, name: spec.name)
                        let pick = loaded.first { source.sheet == nil || $0.source?.sheet == source.sheet || $0.name == source.sheet } ?? loaded.first
                        if let l = pick {
                            table.rows = Self.align(l, to: dataCols, types: table.columns.map(\.type))
                            table.source = source
                            loadedCount += 1
                        }
                    } catch {
                        notes.append(L("« %@ » : %@", spec.name, error.localizedDescription))
                    }
                } else {
                    notes.append(L("« %@ » : fichier source introuvable, table vide.", spec.name))
                }
            } else if project.hasModel {
                notes.append(L("« %@ » : source non reconnue (seuls CSV, Excel, JSON, web, PostgreSQL et MySQL sont rechargés), table vide.", spec.name))
            }
            for c in spec.columns where c.expression != nil {
                table.columns.append(DataColumn(name: c.name, type: Self.columnType(c.dataType), expression: c.expression))
                for r in table.rows.indices { table.rows[r].append(.empty) }
            }
            tables.append(table)
            for m in spec.measures {
                measures.append(Measure(name: m.name, table: spec.name, expression: m.expression, format: Self.measureFormat(m.format)))
            }
        }
        if !project.hasModel {
            // Placeholder measures so the visuals stay wired; their DAX has to be re-entered.
            var seen = Set<String>()
            for p in project.pages { for v in p.visuals { for f in v.roles.values.flatMap({ $0 }) {
                if case .measure(let t, let n) = f, seen.insert(t + "|" + n).inserted, Engine.table(named: t, in: tables) != nil {
                    measures.append(Measure(name: n, table: t, expression: "BLANK()"))
                }
            } } }
            if !seen.isEmpty { notes.append(L("%@ mesure(s) créées vides (BLANK()) : saisissez leur formule DAX.", seen.count)) }
        }
        for r in project.relationships {
            guard let ft = Engine.table(named: r.fromTable, in: tables), ft.columnIndex(r.fromColumn) != nil,
                  let tt = Engine.table(named: r.toTable, in: tables), tt.columnIndex(r.toColumn) != nil else { continue }
            relationships.append(Relationship(fromTable: r.fromTable, fromColumn: r.fromColumn, toTable: r.toTable,
                                              toColumn: r.toColumn, isActive: r.active))
            if r.bothDirections { notes.append(L("Relation %@ → %@ : le filtrage bidirectionnel n'est pas pris en charge (sens unique conservé).", r.fromTable, r.toTable)) }
        }
        recomputeCalculatedColumns()
        let invalid = measures.filter { MeasureCompiler.validate($0.expression, home: $0.table, name: $0.name, model) != nil }
        if !invalid.isEmpty {
            notes.append(L("%@ mesure(s) utilisent du DAX non pris en charge : %@", invalid.count, invalid.prefix(6).map(\.name).joined(separator: ", ")))
        }

        var skipped: [String: Int] = [:]
        var visualCount = 0
        pages = project.pages.map { p in
            var page = ReportPage(name: p.name)
            let sx = PageSize.width / max(p.width, 1), sy = PageSize.height / max(p.height, 1)
            for spec in p.visuals {
                if var v = makeVisual(spec) {
                    v.frame = CGRect(x: spec.frame.minX * sx, y: spec.frame.minY * sy,
                                     width: max(120, spec.frame.width * sx), height: max(70, spec.frame.height * sy))
                    page.visuals.append(v)
                    visualCount += 1
                } else {
                    skipped[spec.type, default: 0] += 1
                }
            }
            return page
        }
        if pages.isEmpty { pages = [ReportPage(name: L("Page 1"))] }
        currentPageID = pages[0].id
        dataTableName = tables.first?.name
        mode = .report
        resetHistory()
        isDirty = true

        var summary = L("« %@ » importé : %@ table(s) dont %@ avec données, %@ mesure(s), %@ relation(s), %@ page(s), %@ visuel(s).",
                        url.lastPathComponent, tables.count, loadedCount, measures.count, relationships.count, pages.count, visualCount)
        if !skipped.isEmpty {
            summary += "\n\n" + L("Visuels non pris en charge : %@", skipped.map { "\($0.key) ×\($0.value)" }.sorted().joined(separator: ", "))
        }
        if !notes.isEmpty { summary += "\n\n" + notes.joined(separator: "\n") }
        alertMessage = summary
    }

    private func resetDocument() {
        tables = []
        relationships = []
        measures = []
        bookmarks = []
        modelLayout = [:]
        theme = Theme.defaultName
        pages = []
        selectedVisualID = nil
        crossFilter = nil
        fileURL = nil
    }

    /// Reorders and converts loaded columns to the model's columns (matched by source column, then by name).
    static func align(_ loaded: DataTable, to cols: [PBIColumnSpec], types: [ColumnType]) -> [[CellValue]] {
        let columnValues: [[CellValue]] = zip(cols, types).map { c, type in
            let key = c.sourceColumn ?? c.name
            let idx = loaded.columnIndex(key) ?? loaded.columns.firstIndex { $0.name.caseInsensitiveEquals(key) || $0.name.caseInsensitiveEquals(c.name) }
            guard let i = idx else { return Array(repeating: .empty, count: loaded.rows.count) }
            return Importer.coerce(Importer.cellsToRaw(loaded.rows.map { $0[i] }), to: type)
        }
        return (0..<loaded.rows.count).map { r in columnValues.map { $0[r] } }
    }

    // MARK: Visuals

    private static let visualTypes: [String: VisualType] = [
        "clusteredColumnChart": .column, "columnChart": .stackedColumn, "hundredPercentStackedColumnChart": .percentColumn,
        "clusteredBarChart": .bar, "barChart": .stackedBar, "hundredPercentStackedBarChart": .stackedBar,
        "lineChart": .line, "areaChart": .area, "stackedAreaChart": .area, "hundredPercentStackedAreaChart": .area,
        "lineClusteredColumnComboChart": .combo, "lineStackedColumnComboChart": .combo,
        "pieChart": .pie, "donutChart": .donut, "card": .card, "cardVisual": .card, "multiRowCard": .card,
        "tableEx": .table, "table": .table, "pivotTable": .matrix, "slicer": .slicer, "advancedSlicerVisual": .slicer,
        "scatterChart": .scatter, "gauge": .gauge, "kpi": .kpi, "map": .map, "filledMap": .map, "azureMap": .map,
        "shapeMap": .map, "waterfallChart": .waterfall, "funnel": .funnel, "treemap": .donut, "ribbonChart": .stackedColumn,
    ]

    private func fieldRef(_ f: PBIField) -> FieldRef? {
        switch f {
        case .column(let t, let c), .aggregate(let t, let c, _): return FieldRef(table: t, column: c)
        case .level(let t, let c, let l):
            let level: DateLevel? = ["year": .year, "quarter": .quarter, "month": .month, "day": .day][l.lowercased()]
            return FieldRef(table: t, column: c, dateLevel: level)
        case .measure: return nil
        }
    }

    private func valueField(_ f: PBIField) -> ValueField? {
        switch f {
        case .measure(let t, let n):
            return ValueField(field: FieldRef(table: t, column: n), aggregation: .sum, isMeasure: true)
        case .aggregate(let t, let c, let fn):
            let agg: Aggregation = [0: .sum, 1: .average, 2: .distinctCount, 3: .min, 4: .max, 5: .count][fn] ?? .count
            return ValueField(field: FieldRef(table: t, column: c), aggregation: agg)
        case .column(let t, let c), .level(let t, let c, _):
            let f = FieldRef(table: t, column: c)
            return ValueField(field: f, aggregation: defaultAggregation(for: f))
        }
    }

    private func makeVisual(_ s: PBIVisualSpec) -> Visual? {
        guard let type = Self.visualTypes[s.type] else { return nil }
        var v = Visual(type: type, frame: .zero)
        func role(_ names: String...) -> [PBIField] { names.lazy.compactMap { s.roles[$0] }.first { !$0.isEmpty } ?? [] }
        func values(_ names: String...) -> [ValueField] { names.lazy.compactMap { s.roles[$0] }.first { !$0.isEmpty }?.compactMap(valueField) ?? [] }
        func axis(_ names: String...) -> [FieldRef] { names.lazy.compactMap { s.roles[$0] }.first { !$0.isEmpty }?.compactMap(fieldRef) ?? [] }
        switch type {
        case .table:
            for f in role("Values") {
                if case .column = f, let r = fieldRef(f) { v.axis.append(r) }
                else if case .level = f, let r = fieldRef(f) { v.axis.append(r) }
                else if let vf = valueField(f) { v.values.append(vf) }
            }
        case .matrix:
            v.axis = axis("Rows")
            v.legend = axis("Columns").first
            v.values = values("Values")
        case .card:
            v.values = Array(values("Values", "Fields", "Data").prefix(1))
        case .slicer:
            v.axis = Array(axis("Values", "Field").prefix(1))
        case .scatter:
            v.axis = Array(axis("Details", "Category").prefix(1))
            v.values = Array(values("X").prefix(1) + values("Y").prefix(1) + values("Size").prefix(1))
        case .combo:
            v.axis = axis("Category")
            v.values = Array(values("Y").prefix(1) + values("Y2").prefix(1))
        case .gauge:
            v.values = Array(values("Y").prefix(1) + values("TargetValue").prefix(1) + values("MaxValue").prefix(1))
        case .kpi:
            v.values = Array(values("Indicator").prefix(1) + values("Goal", "TargetGoal").prefix(1))
            v.axis = Array(axis("TrendLine").prefix(1))
        case .map:
            v.axis = Array(axis("Category", "Location").prefix(1))
            v.values = Array(values("Size", "Y").prefix(1))
        default:
            v.axis = axis("Category", "Axis", "Rows")
            if type.isCartesian { v.legend = axis("Series", "Legend").first }
            v.values = values("Y", "Values")
            if type.isPie || type == .waterfall || type == .funnel { v.values = Array(v.values.prefix(1)) }
        }
        if let t = s.title {
            if t.isEmpty { v.showTitle = false } else { v.title = t }
        }
        return v
    }

    /// Reattaches a table to a file (used after importing a .pbix, or when a source moved).
    func changeSource(of tableName: String) {
        guard let ti = tables.firstIndex(where: { $0.name == tableName }) else { return }
        let panel = NSOpenPanel()
        panel.title = L("Nouvelle source pour « %@ »", tableName)
        panel.allowedContentTypes = Importer.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try Importer.load(url)
            guard let l = loaded.first(where: { $0.name == tableName }) ?? loaded.first else { return }
            let current = tables[ti].columns.filter { $0.expression == nil }
            let specs = current.map { PBIColumnSpec(name: $0.name, dataType: "string") }
            let keepSchema = !current.isEmpty && current.contains { c in l.columnIndex(c.name) != nil }
            var newTable = tables[ti]
            if keepSchema {
                newTable.rows = Self.align(l, to: specs, types: current.map(\.type))
                newTable.columns = current
            } else {
                newTable.columns = l.columns
                newTable.rows = l.rows
            }
            newTable.source = l.source
            let calculated = tables[ti].columns.filter { $0.expression != nil }
            newTable.columns += calculated
            newTable.rows = newTable.rows.map { $0 + Array(repeating: CellValue.empty, count: calculated.count) }
            if !newTable.steps.isEmpty {
                var base = newTable
                base.columns = newTable.columns.filter { $0.expression == nil }
                base.rows = newTable.rows.map { Array($0.prefix(base.columns.count)) }
                base.steps = []
                base.base = []
                newTable.base = [base]
            }
            tables[ti] = newTable
            if !tables[ti].steps.isEmpty { reapplySteps(ti) }
            recomputeCalculatedColumns()
            didChange()
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
