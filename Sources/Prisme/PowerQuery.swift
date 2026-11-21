import Foundation

// Power Query (M) steps translated into Prisme transformation steps, so imported queries keep their
// transformations (shown in "Applied steps" and replayed on refresh). Covers the common Table.* functions;
// `each` expressions are translated into DAX formulas evaluated row by row.

/// A parsed M value or expression (only what step arguments need).
indirect enum MNode {
    case string(String)
    case number(Double)
    case list([MNode])
    case record([(String, MNode)])
    case ident(String)
    case call(String, [MNode])
    case each(String)
    case null
    case bool(Bool)
    case other(String)

    var text: String? {
        switch self {
        case .string(let s): s
        case .number(let d): Fmt.plain(d)
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .null: ""
        default: nil
        }
    }

    var strings: [String] {
        switch self {
        case .string(let s): [s]
        case .list(let l): l.compactMap { if case .string(let s) = $0 { return s }; return nil }
        default: []
        }
    }
}

enum PowerQuery {
    struct Translation {
        var steps: [TransformStep] = []
        /// Steps that couldn't be translated (function names), in order.
        var unsupported: [String] = []
    }

    // MARK: Scanning

    /// Removes comments, keeping strings intact.
    static func stripComments(_ m: String) -> String {
        var out = "", i = m.startIndex, inString = false
        while i < m.endIndex {
            let c = m[i]
            let next = m.index(after: i) < m.endIndex ? m[m.index(after: i)] : nil
            if inString {
                out.append(c)
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "/", next == "/" {
                while i < m.endIndex, m[i] != "\n" { i = m.index(after: i) }
                continue
            } else if c == "/", next == "*" {
                i = m.index(i, offsetBy: 2)
                while i < m.endIndex, !(m[i] == "*" && m.index(after: i) < m.endIndex && m[m.index(after: i)] == "/") { i = m.index(after: i) }
                if i < m.endIndex { i = m.index(i, offsetBy: 2) }
                continue
            } else {
                out.append(c)
            }
            i = m.index(after: i)
        }
        return out
    }

    /// Steps of a `let … in …` query, in order (nil when the query isn't a let expression).
    static func letSteps(_ query: String) -> [(name: String, expr: String)]? {
        let c = Array(stripComments(query))
        var i = 0
        func skipSpace() { while i < c.count, c[i].isWhitespace { i += 1 } }
        func keyword(_ w: String) -> Bool {
            let a = Array(w)
            guard i + a.count <= c.count, Array(c[i..<i + a.count]).map({ Character($0.lowercased()) }) == a else { return false }
            let after = i + a.count == c.count || !(c[i + a.count].isLetter || c[i + a.count].isNumber || c[i + a.count] == "_" || c[i + a.count] == ".")
            let before = i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "_" || c[i - 1] == ".")
            return after && before
        }
        skipSpace()
        guard keyword("let") else { return nil }
        i += 3
        var steps: [(String, String)] = []
        while i < c.count {
            skipSpace()
            if keyword("in") { break }
            var name = ""
            if c[i] == "#", i + 1 < c.count, c[i + 1] == "\"" {
                i += 2
                while i < c.count {
                    if c[i] == "\"" { if i + 1 < c.count, c[i + 1] == "\"" { name.append("\""); i += 2; continue }; i += 1; break }
                    name.append(c[i]); i += 1
                }
            } else {
                while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "." { name.append(c[i]); i += 1 }
            }
            skipSpace()
            guard !name.isEmpty, i < c.count, c[i] == "=" else { return steps.isEmpty ? nil : steps }
            i += 1
            let start = i
            var depth = 0, inString = false, letDepth = 0
            while i < c.count {
                let ch = c[i]
                if inString {
                    if ch == "\"" { if i + 1 < c.count, c[i + 1] == "\"" { i += 2; continue }; inString = false }
                } else if ch == "\"" { inString = true
                } else if ch == "#", i + 1 < c.count, c[i + 1] == "\"" {
                    i += 2
                    while i < c.count { if c[i] == "\"" { if i + 1 < c.count, c[i + 1] == "\"" { i += 2; continue }; break }; i += 1 }
                } else if "([{".contains(ch) { depth += 1
                } else if ")]}".contains(ch) { depth -= 1
                } else if depth == 0, keyword("let") { letDepth += 1; i += 3; continue
                } else if depth == 0, keyword("in") {
                    if letDepth == 0 { break }
                    letDepth -= 1; i += 2; continue
                } else if depth == 0, ch == ",", letDepth == 0 { break }
                i += 1
            }
            steps.append((name, String(c[start..<min(i, c.count)]).trimmingCharacters(in: .whitespacesAndNewlines)))
            if i < c.count, c[i] == "," { i += 1 }
        }
        return steps
    }

    /// Parses one M expression into an `MNode` (calls, lists, records, literals, identifiers, `each`).
    static func parse(_ expr: String) -> MNode {
        var p = NodeParser(chars: Array(expr))
        return p.node()
    }

    /// M string escapes: #(lf), #(cr), #(tab), #(cr,lf), #(#) and #(000D) style code points.
    static func unescape(_ s: String) -> String {
        guard s.contains("#(") else { return s }
        var out = s
        for (k, v) in [("#(cr,lf)", "\r\n"), ("#(lf)", "\n"), ("#(cr)", "\r"), ("#(tab)", "\t")] { out = out.replacingOccurrences(of: k, with: v) }
        if let re = try? NSRegularExpression(pattern: "#\\(([0-9A-Fa-f]{4,8})\\)") {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let r = Range(m.range, in: out), let h = Range(m.range(at: 1), in: out),
                      let code = UInt32(out[h], radix: 16), let u = UnicodeScalar(code) else { continue }
                out.replaceSubrange(r, with: String(Character(u)))
            }
        }
        return out.replacingOccurrences(of: "#(#)", with: "#")
    }

    /// Arguments of the first call to `function` in `m` (nil when there is none).
    static func callArguments(_ m: String, function: String) -> [MNode]? {
        guard let r = m.range(of: function + "(") else { return nil }
        var p = NodeParser(chars: Array(m[r.upperBound...]))
        return p.list(close: ")")
    }

    private struct NodeParser {
        let chars: [Character]
        var i = 0

        mutating func skip() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        /// Raw text until a top-level `,`, `)`, `}` or `]`.
        mutating func raw() -> String {
            let start = i
            var depth = 0, inString = false
            while i < chars.count {
                let ch = chars[i]
                if inString { if ch == "\"" { inString = false } }
                else if ch == "\"" { inString = true }
                else if "([{".contains(ch) { depth += 1 }
                else if ")]}".contains(ch) { if depth == 0 { break }; depth -= 1 }
                else if ch == ",", depth == 0 { break }
                i += 1
            }
            return String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func name() -> String {
            if i + 1 < chars.count, chars[i] == "#", chars[i + 1] == "\"" {
                i += 2
                var s = ""
                while i < chars.count {
                    if chars[i] == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }; i += 1; break }
                    s.append(chars[i]); i += 1
                }
                return s
            }
            var s = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." { s.append(chars[i]); i += 1 }
            return s
        }

        mutating func list(close: Character) -> [MNode] {
            var out: [MNode] = []
            skip()
            if i < chars.count, chars[i] == close { i += 1; return out }
            while i < chars.count {
                out.append(node())
                skip()
                if i < chars.count, chars[i] == "," { i += 1; continue }
                if i < chars.count, chars[i] == close { i += 1 }
                break
            }
            return out
        }

        mutating func node() -> MNode {
            skip()
            guard i < chars.count else { return .other("") }
            let start = i
            let ch = chars[i]
            var result: MNode
            if ch == "\"" {
                i += 1
                var s = ""
                while i < chars.count {
                    if chars[i] == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }; i += 1; break }
                    s.append(chars[i]); i += 1
                }
                result = .string(PowerQuery.unescape(s))
            } else if ch == "{" {
                i += 1
                result = .list(list(close: "}"))
            } else if ch == "[" {
                // Record [A = 1, B = "x"]
                i += 1
                var fields: [(String, MNode)] = []
                skip()
                while i < chars.count, chars[i] != "]" {
                    skip()
                    let n = name()
                    skip()
                    guard i < chars.count, chars[i] == "=" else { i = start; return .other(raw()) }
                    i += 1
                    fields.append((n, node()))
                    skip()
                    if i < chars.count, chars[i] == "," { i += 1 }
                    skip()
                }
                if i < chars.count { i += 1 }
                result = .record(fields)
            } else if ch.isNumber || (ch == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = String(ch)
                i += 1
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" { s.append(chars[i]); i += 1 }
                result = Double(s).map { .number($0) } ?? .other(s)
            } else if ch.isLetter || ch == "#" || ch == "_" {
                let n = name()
                skip()
                switch n {
                case "each":
                    return .each(raw())
                case "null": result = .null
                case "true": result = .bool(true)
                case "false": result = .bool(false)
                case "type":
                    result = .ident("type " + name())
                default:
                    if i < chars.count, chars[i] == "(" {
                        i += 1
                        result = .call(n, list(close: ")"))
                    } else {
                        result = .ident(n)
                    }
                }
            } else {
                return .other(raw())
            }
            // Anything else after the value (operators, navigation `{…}[…]`, `meta`) makes it an expression.
            skip()
            if i < chars.count, !",)}]".contains(chars[i]) {
                i = start
                return .other(raw())
            }
            return result
        }
    }

    // MARK: M expressions → DAX

    /// DAX equivalent of an M row expression (`each` body); `_` stands for `underscore` when given.
    static func dax(_ m: String, underscore: String? = nil) -> String? {
        var t = Tokenizer(chars: Array(m))
        let tokens = t.all()
        var p = DaxWriter(tokens: tokens, underscore: underscore)
        guard let out = p.expression(), p.pos == tokens.count else { return nil }
        return out
    }

    private enum Tok: Equatable { case str(String), num(String), ident(String), field(String), op(String), lp, rp, lb, rb, comma }

    private struct Tokenizer {
        let chars: [Character]
        var i = 0
        mutating func all() -> [Tok] {
            var out: [Tok] = []
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c == "\"" {
                    i += 1
                    var s = ""
                    while i < chars.count {
                        if chars[i] == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { s.append("\""); i += 2; continue }; i += 1; break }
                        s.append(chars[i]); i += 1
                    }
                    out.append(.str(s))
                } else if c == "[" {
                    i += 1
                    var s = ""
                    if i + 1 < chars.count, chars[i] == "#", chars[i + 1] == "\"" {
                        i += 2
                        while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                        i += 1
                    }
                    while i < chars.count, chars[i] != "]" { s.append(chars[i]); i += 1 }
                    i += 1
                    out.append(.field(s.trimmingCharacters(in: .whitespaces)))
                } else if c.isNumber {
                    var s = ""
                    while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                    out.append(.num(s))
                } else if c.isLetter || c == "_" || c == "#" {
                    var s = ""
                    if c == "#", i + 1 < chars.count, chars[i + 1] == "\"" {
                        i += 2
                        while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                        i += 1
                        out.append(.ident(s))
                        continue
                    }
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." || chars[i] == "#" { s.append(chars[i]); i += 1 }
                    out.append(.ident(s))
                } else if c == "(" { out.append(.lp); i += 1
                } else if c == ")" { out.append(.rp); i += 1
                } else if c == "{" { out.append(.lb); i += 1
                } else if c == "}" { out.append(.rb); i += 1
                } else if c == "," { out.append(.comma); i += 1
                } else {
                    let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
                    if ["<>", "<=", ">="].contains(two) { out.append(.op(two)); i += 2 } else { out.append(.op(String(c))); i += 1 }
                }
            }
            return out
        }
    }

    /// M functions with a direct DAX equivalent (argument order unchanged).
    private static let functions: [String: String] = [
        "Text.Upper": "UPPER", "Text.Lower": "LOWER", "Text.Trim": "TRIM", "Text.Length": "LEN", "Text.Start": "LEFT",
        "Text.End": "RIGHT", "Text.Replace": "SUBSTITUTE", "Text.Contains": "CONTAINSSTRING", "Text.Clean": "TRIM",
        "Date.Year": "YEAR", "Date.Month": "MONTH", "Date.Day": "DAY", "Number.Abs": "ABS", "Number.Mod": "MOD",
        "Number.Power": "POWER", "Number.Sqrt": "SQRT", "Number.RoundDown": "ROUNDDOWN", "Number.RoundUp": "ROUNDUP",
        "Number.From": "VALUE", "Number.FromText": "VALUE",
    ]

    private struct DaxWriter {
        let tokens: [Tok]
        let underscore: String?
        var pos = 0

        var current: Tok? { pos < tokens.count ? tokens[pos] : nil }
        mutating func eat(_ t: Tok) -> Bool { if current == t { pos += 1; return true }; return false }
        func isWord(_ w: String) -> Bool { if case .ident(let s) = current { return s == w }; return false }

        mutating func expression() -> String? {
            if isWord("if") {
                pos += 1
                guard let c = expression(), isWord("then") else { return nil }
                pos += 1
                guard let a = expression(), isWord("else") else { return nil }
                pos += 1
                guard let b = expression() else { return nil }
                return "IF(\(c), \(a), \(b))"
            }
            return or()
        }

        mutating func or() -> String? {
            guard var l = and() else { return nil }
            while isWord("or") { pos += 1; guard let r = and() else { return nil }; l = "(\(l) || \(r))" }
            return l
        }

        mutating func and() -> String? {
            guard var l = not() else { return nil }
            while isWord("and") { pos += 1; guard let r = not() else { return nil }; l = "(\(l) && \(r))" }
            return l
        }

        mutating func not() -> String? {
            if isWord("not") { pos += 1; return not().map { "NOT(\($0))" } }
            return comparison()
        }

        mutating func comparison() -> String? {
            guard let l = additive() else { return nil }
            if case .op(let o) = current, ["=", "<>", "<", "<=", ">", ">="].contains(o) {
                pos += 1
                if isWord("null") {
                    pos += 1
                    return o == "=" ? "ISBLANK(\(l))" : o == "<>" ? "NOT(ISBLANK(\(l)))" : nil
                }
                guard let r = additive() else { return nil }
                return "\(l) \(o) \(r)"
            }
            return l
        }

        mutating func additive() -> String? {
            guard var l = multiplicative() else { return nil }
            while case .op(let o) = current, ["+", "-", "&"].contains(o) {
                pos += 1
                guard let r = multiplicative() else { return nil }
                l = "(\(l) \(o) \(r))"
            }
            return l
        }

        mutating func multiplicative() -> String? {
            guard var l = unary() else { return nil }
            while case .op(let o) = current, ["*", "/"].contains(o) {
                pos += 1
                guard let r = unary() else { return nil }
                l = "(\(l) \(o) \(r))"
            }
            return l
        }

        mutating func unary() -> String? {
            if case .op("-") = current { pos += 1; return unary().map { "-\($0)" } }
            return primary()
        }

        mutating func args() -> [String]? {
            guard eat(.lp) else { return nil }
            var out: [String] = []
            if eat(.rp) { return out }
            while true {
                guard let a = expression() else { return nil }
                out.append(a)
                if eat(.comma) { continue }
                guard eat(.rp) else { return nil }
                return out
            }
        }

        mutating func primary() -> String? {
            guard let t = current else { return nil }
            pos += 1
            switch t {
            case .str(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            case .num(let n): return n
            case .field(let f): return "[\(f)]"
            case .lp:
                guard let e = expression(), eat(.rp) else { return nil }
                return "(\(e))"
            case .lb:
                // {a, b} only as List.Contains' first argument (handled there).
                return nil
            case .ident(let name):
                switch name {
                case "null": return "BLANK()"
                case "true": return "TRUE()"
                case "false": return "FALSE()"
                case "_": return underscore
                default: break
                }
                if name == "List.Contains" {
                    guard eat(.lp), eat(.lb) else { return nil }
                    var items: [String] = []
                    while !eat(.rb) {
                        guard let x = expression() else { return nil }
                        items.append(x)
                        _ = eat(.comma)
                    }
                    guard eat(.comma), let v = expression(), eat(.rp) else { return nil }
                    return "(\(v) IN {\(items.joined(separator: ", "))})"
                }
                guard let a = args() else { return nil }
                if let f = PowerQuery.functions[name] { return "\(f)(\(a.joined(separator: ", ")))" }
                switch (name, a.count) {
                case ("Text.From", 1), ("Number.ToText", 1), ("Text.From", 2): return "(\(a[0]) & \"\")"
                case ("Text.Middle", 2), ("Text.Range", 2): return "MID(\(a[0]), \(a[1]) + 1, 1000000)"
                case ("Text.Middle", 3), ("Text.Range", 3): return "MID(\(a[0]), \(a[1]) + 1, \(a[2]))"
                case ("Text.StartsWith", 2): return "(LEFT(\(a[0]), LEN(\(a[1]))) = \(a[1]))"
                case ("Text.EndsWith", 2): return "(RIGHT(\(a[0]), LEN(\(a[1]))) = \(a[1]))"
                case ("Number.Round", 1): return "ROUND(\(a[0]), 0)"
                case ("Number.Round", 2): return "ROUND(\(a[0]), \(a[1]))"
                case ("Number.RoundDown", 1), ("Number.RoundUp", 1):
                    return "\(name == "Number.RoundDown" ? "ROUNDDOWN" : "ROUNDUP")(\(a[0]), 0)"
                case ("Date.AddDays", 2): return "(\(a[0]) + \(a[1]))"
                case ("Date.StartOfMonth", 1): return "(EOMONTH(\(a[0]), -1) + 1)"
                case ("Date.EndOfMonth", 1): return "EOMONTH(\(a[0]), 0)"
                case ("Date.DayOfWeek", 1): return "(WEEKDAY(\(a[0]), 2) - 1)"
                case ("DateTime.Date", 1), ("Date.From", 1): return "DATE(YEAR(\(a[0])), MONTH(\(a[0])), DAY(\(a[0])))"
                case ("Duration.Days", 1): return a[0]
                case ("DateTime.LocalNow", 0), ("DateTime.FixedLocalNow", 0), ("Date.Today", 0): return "TODAY()"
                default: return nil
                }
            default:
                return nil
            }
        }
    }

    // MARK: Steps

    private static func columnType(_ t: MNode) -> ColumnType? {
        guard case .ident(let s) = t else { return nil }
        switch s {
        case "type number", "Int64.Type", "Int32.Type", "Currency.Type", "Percentage.Type", "Number.Type", "Decimal.Type", "Double.Type",
             "type nullable number":
            return .number
        case "type date", "type datetime", "type datetimezone", "Date.Type", "DateTime.Type", "type nullable date": return .date
        case "type text", "type logical", "Text.Type", "type any", "type nullable text": return .text
        default: return nil
        }
    }

    /// Aggregation of a Table.Group column (`each List.Sum([Col])`, `each Table.RowCount(_)`…).
    private static func groupAggregation(_ body: String) -> (Aggregation, String)? {
        let b = body.replacingOccurrences(of: " ", with: "")
        if b.hasPrefix("Table.RowCount(") { return (.count, "") }
        let pairs: [(String, Aggregation)] = [("List.Sum(", .sum), ("List.Average(", .average), ("List.Min(", .min), ("List.Max(", .max),
                                             ("List.Count(List.Distinct(", .distinctCount), ("List.Count(", .count),
                                             ("List.NonNullCount(", .count)]
        for (p, a) in pairs where b.hasPrefix(p) {
            guard let open = b.firstIndex(of: "["), let close = b[open...].firstIndex(of: "]") else { return nil }
            return (a, String(b[b.index(after: open)..<close]))
        }
        return nil
    }

    /// Functions that read data rather than transform a table (the source is loaded separately).
    private static let sourceFunctions: Set<String> = [
        "Csv.Document", "Excel.Workbook", "File.Contents", "Sql.Database", "Sql.Databases", "PostgreSQL.Database", "MySQL.Database",
        "Json.Document", "Web.Contents", "Table.FromRows", "Table.FromRecords", "Table.FromList", "Table.PromoteHeaders",
        "Table.Buffer", "Table.ReorderColumns", "Value.NativeQuery", "Odbc.Query", "Lines.FromBinary", "Binary.Decompress",
        "Table.StopFolding", "Table.TransformColumnNames",
    ]

    /// `{{"a", x}, {"b", y}}` → its items; `{"a", x}` (a single pair) → itself.
    private static func pairs(_ n: MNode) -> [MNode] {
        if case .list(let l) = n, let first = l.first, case .list = first { return l }
        return [n]
    }

    /// Translates the steps of a query. `queries` resolves steps that start from another query (`Source = Other`).
    static func translate(_ m: String, queries: [String: String] = [:], depth: Int = 0) -> Translation {
        var out = Translation()
        guard let steps = letSteps(m) else { return out }
        var pendingJoin: (key: [String], other: String, otherKey: [String], column: String, kind: TransformStep.JoinKind)?
        for (stepName, expr) in steps {
            let node = parse(expr)
            switch node {
            case .ident(let ref):
                // A step reading another query: its own steps come first (sources are resolved elsewhere).
                if !steps.contains(where: { $0.name == ref }), let q = queries[ref], depth < 5 {
                    let inner = translate(q, queries: queries, depth: depth + 1)
                    out.steps += inner.steps
                    out.unsupported += inner.unsupported
                }
                continue
            case .call(let fn, let a):
                if sourceFunctions.contains(fn) { continue }
                func step(_ kind: TransformStep.Kind, column: String = "", text: String = "", text2: String = "") -> TransformStep {
                    TransformStep(kind: kind, column: column, text: text, text2: text2)
                }
                switch fn {
                case "Table.TransformColumnTypes":
                    guard a.count > 1, case .list(let items) = a[1] else { out.unsupported.append(fn); continue }
                    let pairs = pairs(a[1])
                    for p in pairs {
                        guard case .list(let pr) = p, pr.count > 1, let col = pr[0].text, let type = columnType(pr[1]) else { continue }
                        var s = step(.changeType, column: col)
                        s.type = type
                        out.steps.append(s)
                    }
                case "Table.RenameColumns":
                    guard a.count > 1, case .list(let items) = a[1] else { out.unsupported.append(fn); continue }
                    let pairs = pairs(a[1])
                    for p in pairs { let s = p.strings; if s.count == 2, s[0] != s[1] { out.steps.append(step(.renameColumn, column: s[0], text: s[1])) } }
                case "Table.RemoveColumns":
                    guard a.count > 1 else { out.unsupported.append(fn); continue }
                    for c in a[1].strings { out.steps.append(step(.removeColumn, column: c)) }
                case "Table.SelectColumns":
                    guard a.count > 1 else { out.unsupported.append(fn); continue }
                    var s = step(.keepColumns)
                    s.columns = a[1].strings
                    out.steps.append(s)
                case "Table.SelectRows":
                    guard a.count > 1, case .each(let body) = a[1], let f = dax(body) else { out.unsupported.append(fn); continue }
                    out.steps.append(step(.filterFormula, text2: f))
                case "Table.AddColumn":
                    guard a.count > 2, let name = a[1].text, case .each(let body) = a[2], let f = dax(body) else { out.unsupported.append(fn); continue }
                    out.steps.append(step(.customColumn, text: name, text2: f))
                case "Table.DuplicateColumn":
                    guard a.count > 2, let c = a[1].text, let n = a[2].text else { out.unsupported.append(fn); continue }
                    out.steps.append(step(.customColumn, text: n, text2: "[\(c)]"))
                case "Table.TransformColumns":
                    guard a.count > 1, case .list(let items) = a[1] else { out.unsupported.append(fn); continue }
                    let specs = pairs(a[1])
                    for spec in specs {
                        guard case .list(let p) = spec, p.count > 1, let col = p[0].text else { continue }
                        switch p[1] {
                        case .ident("Text.Trim"), .ident("Text.Clean"): out.steps.append(step(.trim, column: col))
                        case .ident(let f) where functions[f] != nil:
                            out.steps.append(step(.customColumn, text: col, text2: "\(functions[f]!)([\(col)])"))
                        case .each(let body):
                            guard let f = dax(body, underscore: "[\(col)]") else { out.unsupported.append(fn); continue }
                            out.steps.append(step(.customColumn, text: col, text2: f))
                        default: out.unsupported.append(fn)
                        }
                        if p.count > 2, let type = columnType(p[2]) { var s = step(.changeType, column: col); s.type = type; out.steps.append(s) }
                    }
                case "Table.ReplaceValue":
                    guard a.count > 4 else { out.unsupported.append(fn); continue }
                    for c in a[4].strings { out.steps.append(step(.replaceValues, column: c, text: a[1].text ?? "", text2: a[2].text ?? "")) }
                case "Table.Distinct":
                    out.steps.append(step(.removeDuplicates))
                case "Table.FirstN":
                    guard a.count > 1, case .number(let n) = a[1] else { out.unsupported.append(fn); continue }
                    var s = step(.keepTopRows); s.count = Int(n); out.steps.append(s)
                case "Table.Skip", "Table.RemoveFirstN":
                    guard a.count > 1, case .number(let n) = a[1] else { out.unsupported.append(fn); continue }
                    var s = step(.skipRows); s.count = Int(n); out.steps.append(s)
                case "Table.Sort":
                    guard a.count > 1 else { out.unsupported.append(fn); continue }
                    var cols: [String] = [], desc: [String] = []
                    let items: [MNode] = { if case .list(let l) = a[1] { return l }; return [a[1]] }()
                    let pairs = pairs(a[1])
                    for p in pairs {
                        switch p {
                        case .string(let c): cols.append(c); desc.append("0")
                        case .list(let l):
                            if let c = l.first?.text { cols.append(c); desc.append(l.count > 1 && { if case .ident("Order.Descending") = l[1] { return true }; return false }() ? "1" : "0") }
                        default: break
                        }
                    }
                    var s = step(.sortRows, text: desc.joined(separator: ","))
                    s.columns = cols
                    out.steps.append(s)
                case "Table.FillDown":
                    guard a.count > 1 else { out.unsupported.append(fn); continue }
                    for c in a[1].strings { out.steps.append(step(.fillDown, column: c)) }
                case "Table.UnpivotOtherColumns", "Table.Unpivot":
                    guard a.count > 3 else { out.unsupported.append(fn); continue }
                    var s = step(.unpivotColumns, text: a[2].text ?? "", text2: a[3].text ?? "")
                    s.columns = a[1].strings
                    if fn == "Table.UnpivotOtherColumns" { s.text3 = "others" }
                    out.steps.append(s)
                case "Table.Group":
                    guard a.count > 2, case .list(let aggs) = a[2] else { out.unsupported.append(fn); continue }
                    var s = step(.groupBy)
                    s.columns = a[1].strings
                    let items = pairs(a[2])
                    for item in items {
                        guard case .list(let p) = item, p.count > 1, let n = p[0].text, case .each(let body) = p[1],
                              let (agg, col) = groupAggregation(body) else { out.unsupported.append(fn); continue }
                        s.aggregations.append(TransformStep.StepAggregation(name: n, aggregation: agg, column: col))
                    }
                    out.steps.append(s)
                case "Table.NestedJoin":
                    guard a.count > 4, case .ident(let other) = a[2], let col = a[4].text else { out.unsupported.append(fn); continue }
                    let kind: TransformStep.JoinKind = a.count > 5 && { if case .ident("JoinKind.Inner") = a[5] { return true }; return false }() ? .inner : .left
                    pendingJoin = (a[1].strings, other, a[3].strings, col, kind)
                    continue
                case "Table.ExpandTableColumn":
                    guard let j = pendingJoin, a.count > 2, a[1].text == j.column, let k = j.key.first, let ok = j.otherKey.first else {
                        out.unsupported.append(fn); continue
                    }
                    let cols = a[2].strings
                    let names = a.count > 3 ? a[3].strings : cols
                    var s = step(.mergeTable, column: k, text: j.other, text2: ok)
                    s.columns = cols
                    s.joinKind = j.kind
                    out.steps.append(s)
                    // Prisme names merged columns "Table.Column": renamed as in the query.
                    for (c, n) in zip(cols, names) { out.steps.append(step(.renameColumn, column: "\(j.other).\(c)", text: n)) }
                    pendingJoin = nil
                case "Table.Combine":
                    guard let first = a.first, case .list(let items) = first else { out.unsupported.append(fn); continue }
                    for case .ident(let t) in items.dropFirst() { out.steps.append(step(.appendTable, text: t)) }
                case "Table.AddIndexColumn":
                    guard a.count > 1, let name = a[1].text else { out.unsupported.append(fn); continue }
                    out.steps.append(step(.addIndex, text: name))
                    if a.count > 2, case .number(let start) = a[2], start != 1 {
                        out.steps.append(step(.customColumn, text: name, text2: "[\(name)] + \(Fmt.plain(start - 1))"))
                    }
                default:
                    out.unsupported.append(fn)
                }
                _ = stepName
            default:
                continue   // navigation (Source{[Item="x"]}[Data]), literals, other expressions
            }
        }
        if pendingJoin != nil { out.unsupported.append("Table.NestedJoin") }
        return out
    }
}
