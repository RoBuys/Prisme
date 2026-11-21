import Foundation

// Report state of Power BI files: filters (report, page, visual), slicer selections, hidden visuals and groups,
// bookmarks, and button actions. Read from the legacy Report/Layout JSON and from the PBIR folder format.

/// A Power BI filter condition on one field.
indirect enum PBICondition {
    case values(PBIField, [CellValue])
    case not(PBICondition)
    case and(PBICondition, PBICondition)
    case or(PBICondition, PBICondition)
    case compare(PBIField, Int, CellValue)   // 0 =, 1 >, 2 >=, 3 <, 4 <=
    case between(PBIField, CellValue, CellValue)
    case contains(PBIField, String)
    case startsWith(PBIField, String)
    case unsupported

    var field: PBIField? {
        switch self {
        case .values(let f, _), .compare(let f, _, _), .between(let f, _, _), .contains(let f, _), .startsWith(let f, _): f
        case .not(let c): c.field
        case .and(let a, _), .or(let a, _): a.field
        case .unsupported: nil
        }
    }

    /// Whether a value passes the condition.
    func test(_ v: CellValue) -> Bool {
        switch self {
        case .values(_, let vs): return vs.contains { PBIFilters.same($0, v) }
        case .not(let c): return !c.test(v)
        case .and(let a, let b): return a.test(v) && b.test(v)
        case .or(let a, let b): return a.test(v) || b.test(v)
        case .compare(_, let k, let x):
            guard let a = PBIFilters.number(v), let b = PBIFilters.number(x) else { return k == 0 && PBIFilters.same(v, x) }
            switch k { case 0: return a == b; case 1: return a > b; case 2: return a >= b; case 3: return a < b; default: return a <= b }
        case .between(_, let lo, let hi):
            guard let a = PBIFilters.number(v), let l = PBIFilters.number(lo), let h = PBIFilters.number(hi) else { return false }
            return a >= l && a <= h
        case .contains(_, let s): return (v.text ?? "").localizedCaseInsensitiveContains(s)
        case .startsWith(_, let s): return (v.text ?? "").lowercased().hasPrefix(s.lowercased())
        case .unsupported: return true
        }
    }

    /// The condition as a range on one field (comparisons and Between), when it is one.
    var range: (lower: Double?, upper: Double?)? {
        switch self {
        case .compare(_, let k, let x) where k != 0:
            guard let b = PBIFilters.number(x) else { return nil }
            switch k { case 1: return (b.nextUp, nil); case 2: return (b, nil); case 3: return (nil, b.nextDown); default: return (nil, b) }
        case .between(_, let lo, let hi):
            guard let l = PBIFilters.number(lo), let h = PBIFilters.number(hi) else { return nil }
            return (l, h)
        case .and(let a, let b):
            guard let x = a.range, let y = b.range else { return nil }
            let lo = [x.lower, y.lower].compactMap { $0 }.max(), hi = [x.upper, y.upper].compactMap { $0 }.min()
            return (lo, hi)
        default: return nil
        }
    }

    var isSupported: Bool {
        switch self {
        case .unsupported: false
        case .not(let c): c.isSupported
        case .and(let a, let b), .or(let a, let b): a.isSupported && b.isSupported
        default: true
        }
    }
}

/// A filter as stored in a report (field and optional condition).
struct PBIFilterEntry {
    var field: PBIField
    var condition: PBICondition?
    var type: String
}

enum PBIFilters {
    static func number(_ v: CellValue) -> Double? { v.number ?? v.date?.timeIntervalSince1970 }

    static func same(_ a: CellValue, _ b: CellValue) -> Bool {
        switch (a, b) {
        case (.empty, .empty): return true
        case (.text(let x), .text(let y)): return x.caseInsensitiveEquals(y)
        case (.number(let x), .number(let y)): return x == y
        case (.date(let x), .date(let y)): return Fmt.calendar.isDate(x, inSameDayAs: y)
        case (.text(let x), _): return x == b.text ?? Fmt.plain(number(b) ?? .nan)
        case (_, .text(let y)): return y == Fmt.plain(number(a) ?? .nan)
        default: return false
        }
    }

    private static let isoFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd"]

    /// `{"Literal": {"Value": "'text'" | "12L" | "1.5D" | "datetime'2020-01-01T00:00:00'" | "true" | "null"}}`
    static func literal(_ x: Any?) -> CellValue? {
        guard let s = ((x as? [String: Any])?["Literal"] as? [String: Any])?["Value"] as? String else { return nil }
        if s == "null" { return .empty }
        if s == "true" || s == "false" { return .text(s.uppercased()) }
        if s.hasPrefix("datetime'") || s.hasPrefix("date'") {
            let body = String(s.drop { $0 != "'" }.dropFirst().dropLast())
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = Fmt.calendar.timeZone
            for fmt in isoFormats { f.dateFormat = fmt; if let d = f.date(from: body) { return .date(d) } }
            return nil
        }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
            return .text(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        if let last = s.last, "LDM".contains(last), let d = Double(s.dropLast()) { return .number(d) }
        return Double(s).map { .number($0) }
    }

    /// Relative dates of RelativeDate filters: Now, DateAdd(…, Amount, TimeUnit), DateSpan(…, TimeUnit).
    static func dateExpression(_ x: Any?) -> Date? {
        guard let d = x as? [String: Any] else { return nil }
        let cal = Fmt.calendar
        let units: [Int: Calendar.Component] = [0: .day, 1: .weekOfYear, 2: .month, 3: .year, 5: .second, 6: .minute, 7: .hour]
        if d["Now"] != nil { return Date() }
        if let a = d["DateAdd"] as? [String: Any], let base = dateExpression(a["Expression"]),
           let n = a["Amount"] as? Int, let u = units[a["TimeUnit"] as? Int ?? 0] {
            return cal.date(byAdding: u, value: n, to: base)
        }
        if let s = d["DateSpan"] as? [String: Any], let base = dateExpression(s["Expression"]) {
            switch s["TimeUnit"] as? Int ?? 0 {
            case 2: return cal.date(from: cal.dateComponents([.year, .month], from: base))
            case 3: return cal.date(from: cal.dateComponents([.year], from: base))
            case 1: return cal.dateInterval(of: .weekOfYear, for: base)?.start
            default: return cal.startOfDay(for: base)
            }
        }
        return literal(d).flatMap(\.date)
    }

    private static func value(_ x: Any?) -> CellValue? {
        if let v = literal(x) { return v }
        return dateExpression(x).map { .date($0) }
    }

    /// A `Where` condition (`From` gives the source aliases).
    static func condition(_ c: Any?, aliases: [String: String]) -> PBICondition {
        guard let c = c as? [String: Any] else { return .unsupported }
        func field(_ x: Any?) -> PBIField? { (x as? [String: Any]).flatMap { PowerBIImporter.field($0, aliases: aliases) } }
        if let i = c["In"] as? [String: Any], let exprs = i["Expressions"] as? [Any], exprs.count == 1, let f = field(exprs[0]) {
            let values = (i["Values"] as? [[Any]] ?? []).compactMap { $0.first.flatMap(literal) }
            return .values(f, values)
        }
        if let n = c["Not"] as? [String: Any] { return .not(condition(n["Expression"], aliases: aliases)) }
        if let a = c["And"] as? [String: Any] {
            return .and(condition(a["Left"], aliases: aliases), condition(a["Right"], aliases: aliases))
        }
        if let o = c["Or"] as? [String: Any] {
            return .or(condition(o["Left"], aliases: aliases), condition(o["Right"], aliases: aliases))
        }
        if let cmp = c["Comparison"] as? [String: Any], let f = field(cmp["Left"]), let v = value(cmp["Right"]) {
            return .compare(f, cmp["ComparisonKind"] as? Int ?? 0, v)
        }
        if let b = c["Between"] as? [String: Any], let f = field(b["Expression"]),
           let lo = value(b["LowerBound"]), let hi = value(b["UpperBound"]) {
            return .between(f, lo, hi)
        }
        for key in ["Contains", "StartsWith"] {
            if let x = c[key] as? [String: Any], let f = field(x["Left"]), let v = literal(x["Right"])?.text {
                return key == "Contains" ? .contains(f, v) : .startsWith(f, v)
            }
        }
        return .unsupported
    }

    /// `{"Version": 2, "From": […], "Where": [{"Condition": …}]}` — the conditions joined with AND.
    static func filterCondition(_ f: Any?) -> PBICondition? {
        guard let f = f as? [String: Any] else { return nil }
        var aliases: [String: String] = [:]
        for from in f["From"] as? [[String: Any]] ?? [] {
            if let n = from["Name"] as? String, let e = from["Entity"] as? String { aliases[n] = e }
        }
        let conds = (f["Where"] as? [[String: Any]] ?? []).map { condition($0["Condition"], aliases: aliases) }
        guard var c = conds.first else { return nil }
        for x in conds.dropFirst() { c = .and(c, x) }
        return c
    }

    /// A filter entry of a report, page, visual or bookmark (`expression` in Layout, `field` in PBIR).
    static func entry(_ e: [String: Any]) -> PBIFilterEntry? {
        let type = e["type"] as? String ?? "Categorical"
        let fieldJSON = (e["field"] ?? e["expression"]) as? [String: Any]
        let condition = filterCondition(e["filter"])
        guard let f = fieldJSON.flatMap({ PowerBIImporter.field($0, aliases: [:]) }) ?? condition?.field else { return nil }
        if ["TopN", "Exclude", "Include", "Passthrough"].contains(type) { return PBIFilterEntry(field: f, condition: .unsupported, type: type) }
        return PBIFilterEntry(field: f, condition: condition, type: type)
    }

    /// Filter entries of a JSON string (Layout) or array (PBIR filterConfig.filters).
    static func entries(_ x: Any?) -> [PBIFilterEntry] {
        var list: [[String: Any]] = []
        if let s = x as? String, let a = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] { list = a }
        else if let a = x as? [[String: Any]] { list = a }
        else if let d = x as? [String: Any] { list = (d["filters"] as? [[String: Any]]) ?? [] }
        return list.compactMap(entry)
    }

    /// Bookmark filters: `{"byExpr": […], "byName": {name: …}}`.
    static func bookmarkEntries(_ x: Any?) -> [PBIFilterEntry] {
        guard let d = x as? [String: Any] else { return [] }
        let byName = (d["byName"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        return ((d["byExpr"] as? [[String: Any]] ?? []) + byName).compactMap(entry)
    }

    /// Selection of a slicer (`objects.general[].properties.filter.filter`).
    static func slicerCondition(_ objects: Any?) -> PBICondition? {
        guard let general = (objects as? [String: Any])?["general"] as? [[String: Any]] else { return nil }
        for g in general {
            if let f = ((g["properties"] as? [String: Any])?["filter"] as? [String: Any])?["filter"] {
                return filterCondition(f)
            }
        }
        return nil
    }

    /// Button action: `visualLink` properties (type, bookmark, navigationSection, webUrl).
    static func link(_ vcObjects: Any?) -> (type: String, target: String?)? {
        guard let items = (vcObjects as? [String: Any])?["visualLink"] as? [[String: Any]] else { return nil }
        var props: [String: Any] = [:]
        for i in items { props.merge(i["properties"] as? [String: Any] ?? [:]) { a, _ in a } }
        func lit(_ k: String) -> String? { literal((props[k] as? [String: Any])?["expr"])?.text }
        guard lit("show")?.uppercased() != "FALSE", let type = lit("type") else { return nil }
        let target = lit("bookmark") ?? lit("navigationSection") ?? lit("webUrl")
        return (type, target)
    }
}

// MARK: - Applying it to the imported report

extension AppState {
    /// Distinct values of a column, from the loaded data.
    private func cells(_ f: FieldRef) -> [CellValue] {
        guard let t = Engine.table(named: f.table, in: tables), let i = t.columnIndex(f.column) else { return [] }
        return Array(Set(t.rows.map { $0[i] }))
    }

    private func fieldRef(_ f: PBIField) -> FieldRef? {
        switch f {
        case .column(let t, let c), .aggregate(let t, let c, _): return FieldRef(table: t, column: c)
        case .level(let t, let c, let l):
            guard l.lowercased() == "year" else { return nil }   // other levels don't match Prisme's labels
            return FieldRef(table: t, column: c, dateLevel: .year)
        case .measure: return nil
        }
    }

    /// Labels a condition keeps, computed on the data when it can't be written as a value list.
    private func labels(_ c: PBICondition, _ f: FieldRef) -> Set<String> {
        if case .values(_, let vs) = c, f.dateLevel == nil {
            return Set(vs.map { GroupKey.of($0, nil).label })
        }
        if f.dateLevel == .year {
            let years = cells(f).compactMap(\.date).map { Fmt.calendar.component(.year, from: $0) }
            return Set(Set(years).filter { c.test(.number(Double($0))) }.map { String($0) })
        }
        return Set(cells(f).filter(c.test).map { GroupKey.of($0, nil).label })
    }

    /// A Prisme filter for a Power BI filter entry (nil when it can't be represented).
    func pageFilter(_ e: PBIFilterEntry, unsupported: inout Int) -> PageFilter? {
        guard let f = fieldRef(e.field), Engine.table(named: f.table, in: tables)?.columnIndex(f.column) != nil else {
            if e.condition != nil { unsupported += 1 }
            return nil
        }
        var pf = PageFilter(field: f)
        guard let c = e.condition else { return pf }
        guard c.isSupported else { unsupported += 1; return pf }
        if f.dateLevel == nil, let r = c.range {
            pf.lower = r.lower
            pf.upper = r.upper
        } else {
            pf.selected = labels(c, f)
            // A condition matching nothing in empty data (templates) would read as "all": keep it visible but say so.
            if pf.selected.isEmpty, case .values = c {} else if pf.selected.isEmpty { unsupported += 1 }
        }
        return pf
    }

    /// Slicer selection for a Power BI slicer condition.
    func slicerSelection(_ c: PBICondition, field: FieldRef?) -> Set<String> {
        guard let f = field, c.isSupported else { return [] }
        return labels(c, FieldRef(table: f.table, column: f.column, dateLevel: f.dateLevel))
    }
}
