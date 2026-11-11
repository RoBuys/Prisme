import Foundation

// A small DAX-like expression language for measures.
//
//   SUM(Ventes[Montant])                       aggregations: SUM AVERAGE MIN MAX COUNT DISTINCTCOUNT COUNTROWS
//   DIVIDE([CA], COUNTROWS(Ventes))            [Nom] = another measure (or a column of the measure's table)
//   CALCULATE([CA], Ventes[Canal] = "Magasin") filter arguments: T[C] = valeur, ALL(…), ALLSELECTED(…), REMOVEFILTERS(…)
//   IF([CA] > 1000, 1, 0)                      + - * /  = <> < <= > >=  && ||  AND OR NOT  ABS ROUND BLANK ISBLANK

struct MeasureError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

indirect enum Expr {
    case number(Double)
    case string(String)
    case bool(Bool)
    case blank
    /// `Table[Col]`, `'Table'[Col]` or bare `[Name]` (table nil).
    case ref(table: String?, name: String)
    case table(String)
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
}

// MARK: - Tokenizer & parser

private enum Token: Equatable {
    case number(Double), string(String), ident(String), bracket(String), quoted(String)
    case op(String), lparen, rparen, comma, end
}

private func tokenize(_ source: String) throws -> [Token] {
    var tokens: [Token] = []
    // Smart quotes typed by macOS text substitution count as plain quotes.
    let chars = Array(source.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        .replacingOccurrences(of: "«", with: "\"").replacingOccurrences(of: "»", with: "\""))
    var i = 0
    func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace { i += 1; continue }
        if c.isNumber || (c == "." && peek(1)?.isNumber == true) {
            var s = ""
            while let d = peek(), d.isNumber || d == "." { s.append(d); i += 1 }
            guard let v = Double(s) else { throw MeasureError(message: "Nombre invalide : \(s)") }
            tokens.append(.number(v))
            continue
        }
        if c == "\"" {
            var s = ""
            i += 1
            while true {
                guard let d = peek() else { throw MeasureError(message: "Guillemet fermant manquant.") }
                i += 1
                if d == "\"" {
                    if peek() == "\"" { s.append("\""); i += 1 } else { break }
                } else { s.append(d) }
            }
            tokens.append(.string(s))
            continue
        }
        if c == "[" || c == "'" {
            let close: Character = c == "[" ? "]" : "'"
            var s = ""
            i += 1
            while true {
                guard let d = peek() else { throw MeasureError(message: "« \(close) » manquant.") }
                i += 1
                if d == close { break }
                s.append(d)
            }
            let name = s.trimmingCharacters(in: .whitespaces)
            tokens.append(c == "[" ? .bracket(name) : .quoted(name))
            continue
        }
        if c.isLetter || c == "_" {
            var s = ""
            while let d = peek(), d.isLetter || d.isNumber || d == "_" || d == "." { s.append(d); i += 1 }
            tokens.append(.ident(s))
            continue
        }
        switch c {
        case "(": tokens.append(.lparen); i += 1
        case ")": tokens.append(.rparen); i += 1
        case ",", ";": tokens.append(.comma); i += 1
        case "+", "-", "*", "/", "!": tokens.append(.op(String(c))); i += 1
        case "=": tokens.append(.op("=")); i += peek(1) == "=" ? 2 : 1
        case "<":
            if peek(1) == "=" { tokens.append(.op("<=")); i += 2 }
            else if peek(1) == ">" { tokens.append(.op("<>")); i += 2 }
            else { tokens.append(.op("<")); i += 1 }
        case ">":
            if peek(1) == "=" { tokens.append(.op(">=")); i += 2 } else { tokens.append(.op(">")); i += 1 }
        case "&":
            guard peek(1) == "&" else { throw MeasureError(message: "Opérateur « & » non pris en charge (utilisez &&).") }
            tokens.append(.op("&&")); i += 2
        case "|":
            guard peek(1) == "|" else { throw MeasureError(message: "Opérateur « | » non pris en charge (utilisez ||).") }
            tokens.append(.op("||")); i += 2
        default:
            throw MeasureError(message: "Caractère inattendu : « \(c) »")
        }
    }
    tokens.append(.end)
    return tokens
}

private struct Parser {
    var tokens: [Token]
    var pos = 0

    var current: Token { tokens[pos] }
    mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }

    mutating func parse() throws -> Expr {
        guard current != .end else { throw MeasureError(message: "L'expression est vide.") }
        let e = try parseOr()
        guard current == .end else { throw MeasureError(message: "Élément inattendu après la fin de l'expression.") }
        return e
    }

    mutating func parseOr() throws -> Expr {
        var l = try parseAnd()
        while current == .op("||") { advance(); l = .binary("||", l, try parseAnd()) }
        return l
    }

    mutating func parseAnd() throws -> Expr {
        var l = try parseComparison()
        while current == .op("&&") { advance(); l = .binary("&&", l, try parseComparison()) }
        return l
    }

    mutating func parseComparison() throws -> Expr {
        var l = try parseAdditive()
        while case .op(let o) = current, ["=", "<>", "<", "<=", ">", ">="].contains(o) {
            advance()
            l = .binary(o, l, try parseAdditive())
        }
        return l
    }

    mutating func parseAdditive() throws -> Expr {
        var l = try parseMultiplicative()
        while case .op(let o) = current, o == "+" || o == "-" {
            advance()
            l = .binary(o, l, try parseMultiplicative())
        }
        return l
    }

    mutating func parseMultiplicative() throws -> Expr {
        var l = try parseUnary()
        while case .op(let o) = current, o == "*" || o == "/" {
            advance()
            l = .binary(o, l, try parseUnary())
        }
        return l
    }

    mutating func parseUnary() throws -> Expr {
        if case .op(let o) = current, o == "-" || o == "!" || o == "+" {
            advance()
            let e = try parseUnary()
            return o == "+" ? e : .unary(o, e)
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> Expr {
        switch current {
        case .number(let v): advance(); return .number(v)
        case .string(let s): advance(); return .string(s)
        case .bracket(let n): advance(); return .ref(table: nil, name: n)
        case .lparen:
            advance()
            let e = try parseOr()
            guard current == .rparen else { throw MeasureError(message: "Parenthèse fermante manquante.") }
            advance()
            return e
        case .quoted(let t):
            advance()
            if case .bracket(let n) = current { advance(); return .ref(table: t, name: n) }
            return .table(t)
        case .ident(let id):
            advance()
            if case .bracket(let n) = current { advance(); return .ref(table: id, name: n) }
            if current == .lparen {
                advance()
                var args: [Expr] = []
                if current != .rparen {
                    while true {
                        args.append(try parseOr())
                        if current == .comma { advance(); continue }
                        break
                    }
                }
                guard current == .rparen else { throw MeasureError(message: "Parenthèse fermante manquante après les arguments de \(id).") }
                advance()
                let name = id.uppercased()
                switch name {
                case "TRUE" where args.isEmpty: return .bool(true)
                case "FALSE" where args.isEmpty: return .bool(false)
                case "BLANK" where args.isEmpty: return .blank
                default: return .call(name, args)
                }
            }
            switch id.uppercased() {
            case "TRUE": return .bool(true)
            case "FALSE": return .bool(false)
            default: return .table(id)
            }
        case .end: throw MeasureError(message: "L'expression est incomplète.")
        default: throw MeasureError(message: "Élément inattendu dans l'expression.")
        }
    }
}

// MARK: - Compilation (parse + validation)

enum MeasureCompiler {
    private static var cache: [String: Result<Expr, MeasureError>] = [:]

    static func parse(_ source: String) -> Result<Expr, MeasureError> {
        if let r = cache[source] { return r }
        let r: Result<Expr, MeasureError>
        do {
            var p = Parser(tokens: try tokenize(source))
            r = .success(try p.parse())
        } catch let e as MeasureError {
            r = .failure(e)
        } catch {
            r = .failure(MeasureError(message: error.localizedDescription))
        }
        if cache.count > 500 { cache.removeAll() }
        cache[source] = r
        return r
    }

    static let functions: [String: ClosedRange<Int>] = [
        "SUM": 1...1, "AVERAGE": 1...1, "MIN": 1...2, "MAX": 1...2, "COUNT": 1...1, "COUNTA": 1...1,
        "DISTINCTCOUNT": 1...1, "COUNTROWS": 1...1, "DIVIDE": 2...3, "IF": 2...3, "ABS": 1...1,
        "ROUND": 1...2, "ISBLANK": 1...1, "AND": 2...2, "OR": 2...2, "NOT": 1...1, "CALCULATE": 1...20,
        "ALL": 0...1, "ALLSELECTED": 0...1, "REMOVEFILTERS": 0...1, "COALESCE": 2...10,
    ]
    static let aggregations: Set<String> = ["SUM", "AVERAGE", "COUNT", "COUNTA", "DISTINCTCOUNT"]
    static let filterModifiers: Set<String> = ["ALL", "ALLSELECTED", "REMOVEFILTERS"]

    /// What a reference resolves to.
    enum Resolved { case column(FieldRef), measure(Measure) }

    static func resolve(table: String?, name: String, home: String, _ m: DataModel) -> Resolved? {
        if let t = table {
            guard let tbl = m.table(t) else { return nil }
            if tbl.columnIndex(name) != nil { return .column(FieldRef(table: t, column: name)) }
            if let me = m.measures.first(where: { $0.table == t && $0.name.caseInsensitiveEquals(name) }) { return .measure(me) }
            return nil
        }
        if let me = m.measures.first(where: { $0.name.caseInsensitiveEquals(name) }) { return .measure(me) }
        if let tbl = m.table(home), tbl.columnIndex(name) != nil { return .column(FieldRef(table: home, column: name)) }
        return nil
    }

    /// Checks references, function names and cycles. Returns nil when the measure is valid.
    static func validate(_ source: String, home: String, name: String, _ m: DataModel) -> String? {
        switch parse(source) {
        case .failure(let e): return e.message
        case .success(let e):
            do {
                try check(e, home: home, m, visiting: [name.lowercased()], inCalculateFilter: false)
                return nil
            } catch let err as MeasureError {
                return err.message
            } catch {
                return error.localizedDescription
            }
        }
    }

    private static func check(_ e: Expr, home: String, _ m: DataModel, visiting: Set<String>, inCalculateFilter: Bool) throws {
        switch e {
        case .number, .string, .bool, .blank: return
        case .table(let t):
            guard m.table(t) != nil else { throw MeasureError(message: "Table introuvable : \(t)") }
        case .ref(let t, let n):
            guard let r = resolve(table: t, name: n, home: home, m) else {
                throw MeasureError(message: t.map { "Colonne ou mesure introuvable : \($0)[\(n)]" } ?? "Colonne ou mesure introuvable : [\(n)]")
            }
            if case .measure(let me) = r {
                guard !visiting.contains(me.name.lowercased()) else {
                    throw MeasureError(message: "Référence circulaire vers la mesure [\(me.name)].")
                }
                if case .success(let inner) = parse(me.expression) {
                    try check(inner, home: me.table, m, visiting: visiting.union([me.name.lowercased()]), inCalculateFilter: false)
                }
            }
        case .unary(_, let a):
            try check(a, home: home, m, visiting: visiting, inCalculateFilter: false)
        case .binary(_, let a, let b):
            try check(a, home: home, m, visiting: visiting, inCalculateFilter: false)
            try check(b, home: home, m, visiting: visiting, inCalculateFilter: false)
        case .call(let f, let args):
            guard let arity = functions[f] else { throw MeasureError(message: "Fonction inconnue : \(f)") }
            guard arity.contains(args.count) else {
                throw MeasureError(message: "\(f) attend \(arity.lowerBound == arity.upperBound ? "\(arity.lowerBound)" : "\(arity.lowerBound) à \(arity.upperBound)") argument(s).")
            }
            if aggregations.contains(f) || ((f == "MIN" || f == "MAX") && args.count == 1) {
                guard case .ref(let t, let n) = args[0] else {
                    throw MeasureError(message: "\(f) attend une colonne, par exemple \(f)(Table[Colonne]).")
                }
                switch resolve(table: t, name: n, home: home, m) {
                case .column: return
                case .measure: throw MeasureError(message: "\(f) attend une colonne, pas une mesure ([\(n)]).")
                case nil: throw MeasureError(message: "Colonne introuvable : \(t ?? "")[\(n)]")
                }
            }
            if f == "COUNTROWS" {
                guard case .table(let t) = args[0], m.table(t) != nil else {
                    throw MeasureError(message: "COUNTROWS attend une table, par exemple COUNTROWS(Ventes).")
                }
                return
            }
            if filterModifiers.contains(f) {
                guard inCalculateFilter else { throw MeasureError(message: "\(f) ne peut être utilisé que comme filtre de CALCULATE.") }
                if let a = args.first {
                    switch a {
                    case .table(let t): guard m.table(t) != nil else { throw MeasureError(message: "Table introuvable : \(t)") }
                    case .ref(let t, let n):
                        guard case .column = resolve(table: t, name: n, home: home, m) else {
                            throw MeasureError(message: "\(f) attend une table ou une colonne.")
                        }
                    default: throw MeasureError(message: "\(f) attend une table ou une colonne.")
                    }
                }
                return
            }
            if f == "CALCULATE" {
                try check(args[0], home: home, m, visiting: visiting, inCalculateFilter: false)
                for a in args.dropFirst() {
                    switch a {
                    case .call(let g, _) where filterModifiers.contains(g):
                        try check(a, home: home, m, visiting: visiting, inCalculateFilter: true)
                    case .binary("=", .ref(let t, let n), let v):
                        guard case .column = resolve(table: t, name: n, home: home, m) else {
                            throw MeasureError(message: "Le filtre de CALCULATE doit porter sur une colonne.")
                        }
                        try check(v, home: home, m, visiting: visiting, inCalculateFilter: false)
                    default:
                        throw MeasureError(message: "Filtre de CALCULATE non pris en charge. Utilisez Table[Colonne] = valeur, ALL(…), ALLSELECTED(…) ou REMOVEFILTERS(…).")
                    }
                }
                return
            }
            for a in args { try check(a, home: home, m, visiting: visiting, inCalculateFilter: false) }
        }
    }

    /// Columns and tables a measure depends on (through nested measures too); used to pick the query's base table.
    static func dependencies(_ me: Measure, _ m: DataModel, visiting: Set<String> = []) -> [FieldRef] {
        guard !visiting.contains(me.name.lowercased()), case .success(let e) = parse(me.expression) else { return [] }
        var out: [FieldRef] = []
        func walk(_ e: Expr, home: String) {
            switch e {
            case .table(let t): out.append(FieldRef(table: t, column: ""))
            case .ref(let t, let n):
                switch resolve(table: t, name: n, home: home, m) {
                case .column(let f): out.append(f)
                case .measure(let inner): out += dependencies(inner, m, visiting: visiting.union([me.name.lowercased()]))
                case nil: break
                }
            case .unary(_, let a): walk(a, home: home)
            case .binary(_, let a, let b): walk(a, home: home); walk(b, home: home)
            case .call(let f, let args):
                // Filter modifiers only remove filters: they don't widen the query.
                if filterModifiers.contains(f) { return }
                args.forEach { walk($0, home: home) }
            default: break
            }
        }
        walk(e, home: me.table)
        return out
    }
}

extension String {
    func caseInsensitiveEquals(_ o: String) -> Bool { compare(o, options: [.caseInsensitive]) == .orderedSame }
}

// MARK: - Evaluation

enum MValue {
    case blank, number(Double), text(String), bool(Bool)

    var number: Double? {
        switch self {
        case .blank: nil
        case .number(let d): d
        case .bool(let b): b ? 1 : 0
        case .text(let s): Double(s)
        }
    }

    var truthy: Bool {
        switch self {
        case .blank: false
        case .number(let d): d != 0
        case .bool(let b): b
        case .text(let s): !s.isEmpty
        }
    }

    var isBlank: Bool { if case .blank = self { return true }; return false }
}

/// Evaluates measures over sets of base rows, within a filter context.
final class MeasureEvaluator {
    let ctx: QueryContext
    let model: DataModel
    private var rowCache: [String: [Int]] = [:]

    init(ctx: QueryContext, model: DataModel) {
        self.ctx = ctx
        self.model = model
    }

    func evaluate(_ me: Measure, rows: [Int], filters: [FilterSpec]) -> Double? {
        guard case .success(let e) = MeasureCompiler.parse(me.expression) else { return nil }
        return (try? eval(e, home: me.table, rows: rows, filters: filters, depth: 0))?.number
    }

    private func rows(for filters: [FilterSpec]) -> [Int] {
        let key = filters.map { "\($0.field.columnKey)|\($0.field.dateLevel?.rawValue ?? "")|\($0.isGroup)|\($0.allowed.sorted().joined(separator: "\u{1E}"))" }
            .sorted().joined(separator: "\u{1D}")
        if let r = rowCache[key] { return r }
        let r = ctx.rowIndices(filters)
        rowCache[key] = r
        return r
    }

    private func eval(_ e: Expr, home: String, rows: [Int], filters: [FilterSpec], depth: Int) throws -> MValue {
        guard depth < 50 else { throw MeasureError(message: "Imbrication trop profonde.") }
        func sub(_ x: Expr) throws -> MValue { try eval(x, home: home, rows: rows, filters: filters, depth: depth + 1) }

        switch e {
        case .number(let d): return .number(d)
        case .string(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .blank: return .blank
        case .table: throw MeasureError(message: "Une table ne peut pas être utilisée comme valeur.")
        case .ref(let t, let n):
            switch MeasureCompiler.resolve(table: t, name: n, home: home, model) {
            case .measure(let me):
                guard case .success(let inner) = MeasureCompiler.parse(me.expression) else { return .blank }
                return try eval(inner, home: me.table, rows: rows, filters: filters, depth: depth + 1)
            case .column:
                throw MeasureError(message: "Une colonne doit être agrégée (SUM, AVERAGE…).")
            case nil:
                throw MeasureError(message: "Référence introuvable : [\(n)]")
            }
        case .unary(let o, let a):
            let v = try sub(a)
            if o == "!" { return .bool(!v.truthy) }
            guard let d = v.number else { return .blank }
            return .number(-d)
        case .binary(let o, let a, let b):
            if o == "&&" { return .bool(try sub(a).truthy && sub(b).truthy) }
            if o == "||" { return .bool(try sub(a).truthy || sub(b).truthy) }
            let x = try sub(a), y = try sub(b)
            switch o {
            case "+", "-", "*":
                if x.isBlank && y.isBlank { return .blank }
                let p = x.number ?? 0, q = y.number ?? 0
                return .number(o == "+" ? p + q : o == "-" ? p - q : p * q)
            case "/":
                guard let p = x.number, let q = y.number, q != 0 else { return .blank }
                return .number(p / q)
            default:
                return .bool(compare(x, y, o))
            }
        case .call(let f, let args):
            return try call(f, args, home: home, rows: rows, filters: filters, depth: depth)
        }
    }

    private func compare(_ x: MValue, _ y: MValue, _ o: String) -> Bool {
        let r: ComparisonResult
        if case .text(let a) = x, case .text(let b) = y {
            r = a.localizedStandardCompare(b)
        } else {
            let p = x.number ?? 0, q = y.number ?? 0
            r = p < q ? .orderedAscending : (p > q ? .orderedDescending : .orderedSame)
        }
        switch o {
        case "=": return r == .orderedSame
        case "<>": return r != .orderedSame
        case "<": return r == .orderedAscending
        case "<=": return r != .orderedDescending
        case ">": return r == .orderedDescending
        default: return r != .orderedAscending
        }
    }

    private func column(_ e: Expr, home: String) throws -> FieldRef {
        guard case .ref(let t, let n) = e, case .column(let f) = MeasureCompiler.resolve(table: t, name: n, home: home, model) else {
            throw MeasureError(message: "Colonne attendue.")
        }
        return f
    }

    private func call(_ f: String, _ args: [Expr], home: String, rows: [Int], filters: [FilterSpec], depth: Int) throws -> MValue {
        func sub(_ x: Expr) throws -> MValue { try eval(x, home: home, rows: rows, filters: filters, depth: depth + 1) }

        func aggregate(_ a: Aggregation) throws -> MValue {
            let fr = try column(args[0], home: home)
            guard let values = ctx.values(fr, rows) else {
                throw MeasureError(message: "Aucune relation ne relie \(fr.table) à la table du visuel.")
            }
            var acc = Acc(distinct: a == .distinctCount)
            values.forEach { acc.add($0) }
            return acc.result(a).map { .number($0) } ?? .blank
        }

        switch f {
        case "SUM": return try aggregate(.sum)
        case "AVERAGE": return try aggregate(.average)
        case "COUNT", "COUNTA": return try aggregate(.count)
        case "DISTINCTCOUNT": return try aggregate(.distinctCount)
        case "MIN", "MAX":
            if args.count == 1 { return try aggregate(f == "MIN" ? .min : .max) }
            let a = try sub(args[0]), b = try sub(args[1])
            guard let p = a.number else { return b }
            guard let q = b.number else { return a }
            return .number(f == "MIN" ? Swift.min(p, q) : Swift.max(p, q))
        case "COUNTROWS":
            guard case .table(let t) = args[0], let related = ctx.relatedRows(t, rows) else {
                throw MeasureError(message: "COUNTROWS : table hors de portée du visuel.")
            }
            return related.isEmpty ? .blank : .number(Double(related.count))
        case "DIVIDE":
            let a = try sub(args[0]), b = try sub(args[1])
            if let p = a.number, let q = b.number, q != 0 { return .number(p / q) }
            return args.count > 2 ? try sub(args[2]) : .blank
        case "IF":
            if try sub(args[0]).truthy { return try sub(args[1]) }
            return args.count > 2 ? try sub(args[2]) : .blank
        case "ABS":
            return try sub(args[0]).number.map { .number(Swift.abs($0)) } ?? .blank
        case "ROUND":
            guard let d = try sub(args[0]).number else { return .blank }
            let digits = args.count > 1 ? Int(try sub(args[1]).number ?? 0) : 0
            let p = pow(10.0, Double(digits))
            return .number((d * p).rounded() / p)
        case "ISBLANK": return .bool(try sub(args[0]).isBlank)
        case "AND": return .bool(try sub(args[0]).truthy && sub(args[1]).truthy)
        case "OR": return .bool(try sub(args[0]).truthy || sub(args[1]).truthy)
        case "NOT": return .bool(!(try sub(args[0]).truthy))
        case "COALESCE":
            for a in args { let v = try sub(a); if !v.isBlank { return v } }
            return .blank
        case "CALCULATE":
            var newFilters = filters
            // As in DAX, filter removers (ALL…) apply before the new filters, whatever their order.
            let modifiers = args.dropFirst().filter { if case .call = $0 { return true }; return false }
            let setters = args.dropFirst().filter { if case .call = $0 { return false }; return true }
            for a in modifiers + setters {
                newFilters = try applyFilter(a, to: newFilters, home: home, rows: rows, filters: filters, depth: depth)
            }
            return try eval(args[0], home: home, rows: self.rows(for: newFilters), filters: newFilters, depth: depth + 1)
        default:
            throw MeasureError(message: "Fonction non prise en charge ici : \(f)")
        }
    }

    private func applyFilter(_ a: Expr, to current: [FilterSpec], home: String, rows: [Int],
                             filters: [FilterSpec], depth: Int) throws -> [FilterSpec] {
        switch a {
        case .binary("=", let lhs, let rhs):
            let fr = try column(lhs, home: home)
            let v = try eval(rhs, home: home, rows: rows, filters: filters, depth: depth + 1)
            let label: String
            switch v {
            case .number(let d): label = GroupKey.of(.number(d), nil).label
            case .text(let s): label = s
            case .bool(let b): label = b ? "VRAI" : "FAUX"
            case .blank: label = GroupKey.blankLabel
            }
            return current.filter { $0.field.columnKey != fr.columnKey } + [FilterSpec(field: fr, allowed: [label])]
        case .call(let g, let args):
            let onlyGroup = g == "ALLSELECTED"
            let scope: (FilterSpec) -> Bool
            if let target = args.first {
                if case .table(let t) = target {
                    let tables = Set(model.reachable(from: t).map(\.table))
                    scope = { tables.contains($0.field.table) }
                } else {
                    let fr = try column(target, home: home)
                    scope = { $0.field.columnKey == fr.columnKey }
                }
            } else {
                scope = { _ in true }
            }
            return current.filter { !(scope($0) && (!onlyGroup || $0.isGroup)) }
        default:
            throw MeasureError(message: "Filtre de CALCULATE non pris en charge.")
        }
    }
}
