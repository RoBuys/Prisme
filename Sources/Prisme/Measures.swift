import Foundation

// A small DAX-like expression language for measures.
//
//   SUM(Ventes[Montant])                       aggregations: SUM AVERAGE MIN MAX COUNT DISTINCTCOUNT COUNTROWS
//   DIVIDE([CA], COUNTROWS(Ventes))            [Name] = another measure (or a column of the measure's table)
//   CALCULATE([CA], Ventes[Canal] = "Magasin") filter arguments: T[C] = value, ALL(…), ALLSELECTED(…), REMOVEFILTERS(…)
//   IF([CA] > 1000, 1, 0)                      + - * / &  = <> < <= > >=  && ||  AND OR NOT  ABS ROUND BLANK ISBLANK
//   SUMX(Ventes, Ventes[Qté] * RELATED(Produits[Prix]))   iterators: SUMX AVERAGEX MINX MAXX COUNTX, FILTER(table, cond)
//   TOTALYTD([CA], Ventes[Date]), CALCULATE([CA], SAMEPERIODLASTYEAR(Ventes[Date]))   time intelligence
//   Row context (iterators, calculated columns): bare Table[Column] values, RELATED, YEAR/MONTH/DAY, UPPER/LOWER/LEN/LEFT/RIGHT

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
            guard let v = Double(s) else { throw MeasureError(message: L("Nombre invalide : %@", s)) }
            tokens.append(.number(v))
            continue
        }
        if c == "\"" {
            var s = ""
            i += 1
            while true {
                guard let d = peek() else { throw MeasureError(message: L("Guillemet fermant manquant.")) }
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
                guard let d = peek() else { throw MeasureError(message: L("« %@ » manquant.", close)) }
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
            if peek(1) == "&" { tokens.append(.op("&&")); i += 2 } else { tokens.append(.op("&")); i += 1 }
        case "|":
            guard peek(1) == "|" else { throw MeasureError(message: L("Opérateur « | » non pris en charge (utilisez ||).")) }
            tokens.append(.op("||")); i += 2
        default:
            throw MeasureError(message: L("Caractère inattendu : « %@ »", c))
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
        guard current != .end else { throw MeasureError(message: L("L'expression est vide.")) }
        let e = try parseOr()
        guard current == .end else { throw MeasureError(message: L("Élément inattendu après la fin de l'expression.")) }
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
        while case .op(let o) = current, o == "+" || o == "-" || o == "&" {
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
            guard current == .rparen else { throw MeasureError(message: L("Parenthèse fermante manquante.")) }
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
                guard current == .rparen else { throw MeasureError(message: L("Parenthèse fermante manquante après les arguments de %@.", id)) }
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
        case .end: throw MeasureError(message: L("L'expression est incomplète."))
        default: throw MeasureError(message: L("Élément inattendu dans l'expression."))
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
        "SUMX": 2...2, "AVERAGEX": 2...2, "MINX": 2...2, "MAXX": 2...2, "COUNTX": 2...2, "FILTER": 2...2,
        "RELATED": 1...1, "YEAR": 1...1, "MONTH": 1...1, "DAY": 1...1, "UPPER": 1...1, "LOWER": 1...1,
        "LEN": 1...1, "LEFT": 2...2, "RIGHT": 2...2,
        "DATESYTD": 1...1, "DATESMTD": 1...1, "DATESQTD": 1...1, "SAMEPERIODLASTYEAR": 1...1, "DATEADD": 3...3,
        "PREVIOUSMONTH": 1...1, "PREVIOUSYEAR": 1...1, "TOTALYTD": 2...2, "TOTALMTD": 2...2, "TOTALQTD": 2...2,
    ]
    static let aggregations: Set<String> = ["SUM", "AVERAGE", "COUNT", "COUNTA", "DISTINCTCOUNT"]
    static let filterModifiers: Set<String> = ["ALL", "ALLSELECTED", "REMOVEFILTERS"]
    static let iterators: Set<String> = ["SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX"]
    /// Time-intelligence filters, valid as CALCULATE arguments.
    static let dateFilters: Set<String> = ["DATESYTD", "DATESMTD", "DATESQTD", "SAMEPERIODLASTYEAR", "DATEADD",
                                           "PREVIOUSMONTH", "PREVIOUSYEAR"]
    static let dateUnits: Set<String> = ["YEAR", "QUARTER", "MONTH", "DAY"]

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
        func sub(_ x: Expr) throws { try check(x, home: home, m, visiting: visiting, inCalculateFilter: false) }
        func columnArg(_ x: Expr, _ f: String) throws {
            guard case .ref(let t, let n) = x else {
                throw MeasureError(message: L("%@ attend une colonne, par exemple %@(Table[Colonne]).", f, f))
            }
            switch resolve(table: t, name: n, home: home, m) {
            case .column: return
            case .measure: throw MeasureError(message: L("%@ attend une colonne, pas une mesure ([%@]).", f, n))
            case nil: throw MeasureError(message: L("Colonne introuvable : %@[%@]", t ?? "", n))
            }
        }
        /// Expressions that produce a table: Table, ALL(Table), FILTER(table, condition).
        func tableArg(_ x: Expr, _ f: String) throws {
            switch x {
            case .table(let t):
                guard m.table(t) != nil else { throw MeasureError(message: L("Table introuvable : %@", t)) }
            case .call("ALL", let a) where a.count == 1:
                guard case .table(let t) = a[0], m.table(t) != nil else { throw MeasureError(message: L("%@ attend une table.", "ALL")) }
            case .call("FILTER", let a) where a.count == 2:
                try tableArg(a[0], "FILTER")
                try sub(a[1])
            default:
                throw MeasureError(message: L("%@ attend une table, par exemple %@(Ventes, …).", f, f))
            }
        }

        switch e {
        case .number, .string, .bool, .blank: return
        case .table(let t):
            guard m.table(t) != nil else { throw MeasureError(message: L("Table introuvable : %@", t)) }
        case .ref(let t, let n):
            guard let r = resolve(table: t, name: n, home: home, m) else {
                throw MeasureError(message: t.map { L("Colonne ou mesure introuvable : %@[%@]", $0, n) } ?? L("Colonne ou mesure introuvable : [%@]", n))
            }
            if case .measure(let me) = r {
                guard !visiting.contains(me.name.lowercased()) else {
                    throw MeasureError(message: L("Référence circulaire vers la mesure [%@].", me.name))
                }
                if case .success(let inner) = parse(me.expression) {
                    try check(inner, home: me.table, m, visiting: visiting.union([me.name.lowercased()]), inCalculateFilter: false)
                }
            }
        case .unary(_, let a):
            try sub(a)
        case .binary(_, let a, let b):
            try sub(a)
            try sub(b)
        case .call(let f, let args):
            guard let arity = functions[f] else { throw MeasureError(message: L("Fonction inconnue : %@", f)) }
            guard arity.contains(args.count) else {
                throw MeasureError(message: L("%@ attend %@ argument(s).", f, arity.lowerBound == arity.upperBound ? "\(arity.lowerBound)" : L("%@ à %@", arity.lowerBound, arity.upperBound)))
            }
            if aggregations.contains(f) || ((f == "MIN" || f == "MAX") && args.count == 1) || f == "RELATED" {
                try columnArg(args[0], f)
                return
            }
            if f == "COUNTROWS" { try tableArg(args[0], f); return }
            if iterators.contains(f) {
                try tableArg(args[0], f)
                try sub(args[1])
                return
            }
            if f == "FILTER" {
                throw MeasureError(message: L("FILTER renvoie une table : utilisez-le dans CALCULATE, COUNTROWS ou SUMX."))
            }
            if dateFilters.contains(f) {
                guard inCalculateFilter else { throw MeasureError(message: L("%@ ne peut être utilisé que comme filtre de CALCULATE.", f)) }
                try columnArg(args[0], f)
                if f == "DATEADD" {
                    try sub(args[1])
                    guard case .table(let u) = args[2], dateUnits.contains(u.uppercased()) else {
                        throw MeasureError(message: L("DATEADD attend une unité : YEAR, QUARTER, MONTH ou DAY."))
                    }
                }
                return
            }
            if f == "TOTALYTD" || f == "TOTALMTD" || f == "TOTALQTD" {
                try sub(args[0])
                try columnArg(args[1], f)
                return
            }
            if filterModifiers.contains(f) {
                guard inCalculateFilter else { throw MeasureError(message: L("%@ ne peut être utilisé que comme filtre de CALCULATE.", f)) }
                if let a = args.first {
                    switch a {
                    case .table(let t): guard m.table(t) != nil else { throw MeasureError(message: L("Table introuvable : %@", t)) }
                    case .ref(let t, let n):
                        guard case .column = resolve(table: t, name: n, home: home, m) else {
                            throw MeasureError(message: L("%@ attend une table ou une colonne.", f))
                        }
                    default: throw MeasureError(message: L("%@ attend une table ou une colonne.", f))
                    }
                }
                return
            }
            if f == "CALCULATE" {
                try sub(args[0])
                for a in args.dropFirst() {
                    switch a {
                    case .call(let g, _) where filterModifiers.contains(g) || dateFilters.contains(g):
                        try check(a, home: home, m, visiting: visiting, inCalculateFilter: true)
                    case .call("FILTER", _):
                        try tableArg(a, "FILTER")
                    case .binary(let op, .ref(let t, let n), let v) where ["=", "<>", "<", "<=", ">", ">="].contains(op):
                        guard case .column = resolve(table: t, name: n, home: home, m) else {
                            throw MeasureError(message: L("Le filtre de CALCULATE doit porter sur une colonne."))
                        }
                        try sub(v)
                    default:
                        throw MeasureError(message: L("Filtre de CALCULATE non pris en charge. Utilisez Table[Colonne] = valeur, une comparaison, FILTER(…), ALL(…), ALLSELECTED(…), REMOVEFILTERS(…) ou une fonction de dates."))
                    }
                }
                return
            }
            for a in args { try sub(a) }
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
    case blank, number(Double), text(String), bool(Bool), date(Date)

    init(_ c: CellValue) {
        switch c {
        case .empty: self = .blank
        case .number(let d): self = .number(d)
        case .text(let s): self = .text(s)
        case .date(let d): self = .date(d)
        }
    }

    var number: Double? {
        switch self {
        case .blank: nil
        case .number(let d): d
        case .bool(let b): b ? 1 : 0
        case .text(let s): Double(s)
        case .date(let d): d.timeIntervalSince1970
        }
    }

    var string: String {
        switch self {
        case .blank: ""
        case .number(let d): Fmt.plain(d)
        case .text(let s): s
        case .bool(let b): b ? "TRUE" : "FALSE"
        case .date(let d): Fmt.day(d)
        }
    }

    var truthy: Bool {
        switch self {
        case .blank: false
        case .number(let d): d != 0
        case .bool(let b): b
        case .text(let s): !s.isEmpty
        case .date: true
        }
    }

    var isBlank: Bool { if case .blank = self { return true }; return false }

    /// The cell stored by a calculated column.
    var cell: CellValue {
        switch self {
        case .blank: .empty
        case .number(let d): d.isFinite ? .number(d) : .empty
        case .text(let s): s.isEmpty ? .empty : .text(s)
        case .bool(let b): .text(b ? "TRUE" : "FALSE")
        case .date(let d): .date(d)
        }
    }
}

/// The current row while iterating a table (SUMX, FILTER, calculated columns).
struct RowContext {
    let table: String
    let row: Int
    /// Rows of the query's base table that belong to this row (used for context transition).
    let baseRows: [Int]
}

/// Evaluates measures over sets of base rows, within a filter context.
final class MeasureEvaluator {
    let ctx: QueryContext
    let model: DataModel
    private var rowCache: [String: [Int]] = [:]
    private var tableContexts: [String: QueryContext] = [:]

    init(ctx: QueryContext, model: DataModel) {
        self.ctx = ctx
        self.model = model
    }

    func evaluate(_ me: Measure, rows: [Int], filters: [FilterSpec]) -> Double? {
        guard case .success(let e) = MeasureCompiler.parse(me.expression) else { return nil }
        return (try? eval(e, home: me.table, rows: rows, filters: filters, row: nil, depth: 0))?.number
    }

    /// Any value (text included) of a measure, for previews.
    func evaluateValue(_ me: Measure, rows: [Int], filters: [FilterSpec]) throws -> MValue {
        guard case .success(let e) = MeasureCompiler.parse(me.expression) else { return .blank }
        return try eval(e, home: me.table, rows: rows, filters: filters, row: nil, depth: 0)
    }

    private lazy var allBaseRows = Array(ctx.base.rows.indices)

    /// Calculated column value for one row of the base table. As in DAX, aggregations see the whole table;
    /// measures see the current row (context transition).
    func evaluateRow(_ e: Expr, row: Int) throws -> MValue {
        try eval(e, home: ctx.base.name, rows: allBaseRows, filters: [],
                 row: RowContext(table: ctx.base.name, row: row, baseRows: [row]), depth: 0)
    }

    private func rows(for filters: [FilterSpec]) -> [Int] {
        let key = filters.map { f -> String in
            var k = "\(f.field.columnKey)|\(f.field.dateLevel?.rawValue ?? "")|\(f.isGroup)|\(f.allowed.sorted().joined(separator: "\u{1E}"))"
            if let r = f.range { k += "|r\(r.lowerBound)-\(r.upperBound)" }
            if let s = f.rowSet { k += "|s\(s.count)-\(s.hashValue)" }
            return k
        }.sorted().joined(separator: "\u{1D}")
        if let r = rowCache[key] { return r }
        let r = ctx.rowIndices(filters)
        rowCache[key] = r
        return r
    }

    private func tableContext(_ t: String) -> QueryContext? {
        if t == ctx.base.name { return ctx }
        if let c = tableContexts[t] { return c }
        guard let table = model.table(t) else { return nil }
        let c = QueryContext(base: table, model: model)
        tableContexts[t] = c
        return c
    }

    /// Value of a column for the current row (following relationships from the row's table, like RELATED).
    private func cellValue(_ f: FieldRef, _ rc: RowContext) throws -> MValue {
        guard let qc = tableContext(rc.table), let get = qc.accessor(f) else {
            throw MeasureError(message: L("Aucune relation ne relie %@ à %@.", f.table, rc.table))
        }
        return MValue(get(rc.row))
    }

    private func eval(_ e: Expr, home: String, rows: [Int], filters: [FilterSpec], row: RowContext?, depth: Int) throws -> MValue {
        guard depth < 60 else { throw MeasureError(message: L("Imbrication trop profonde.")) }
        func sub(_ x: Expr) throws -> MValue { try eval(x, home: home, rows: rows, filters: filters, row: row, depth: depth + 1) }

        switch e {
        case .number(let d): return .number(d)
        case .string(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .blank: return .blank
        case .table: throw MeasureError(message: L("Une table ne peut pas être utilisée comme valeur."))
        case .ref(let t, let n):
            switch MeasureCompiler.resolve(table: t, name: n, home: home, model) {
            case .measure(let me):
                guard case .success(let inner) = MeasureCompiler.parse(me.expression) else { return .blank }
                if let rc = row {
                    // Context transition: the measure sees only the current row.
                    let f = filters + [FilterSpec(field: FieldRef(table: rc.table, column: ""), allowed: [], rowSet: [rc.row])]
                    return try eval(inner, home: me.table, rows: rc.baseRows, filters: f, row: nil, depth: depth + 1)
                }
                return try eval(inner, home: me.table, rows: rows, filters: filters, row: nil, depth: depth + 1)
            case .column(let f):
                guard let rc = row else { throw MeasureError(message: L("Une colonne doit être agrégée (SUM, AVERAGE…).")) }
                return try cellValue(f, rc)
            case nil:
                throw MeasureError(message: L("Référence introuvable : [%@]", n))
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
            case "&": return .text(x.string + y.string)
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
            return try call(f, args, home: home, rows: rows, filters: filters, row: row, depth: depth)
        }
    }

    private func compare(_ x: MValue, _ y: MValue, _ o: String) -> Bool {
        let r: ComparisonResult
        if case .text(let a) = x, case .text(let b) = y {
            r = a.localizedStandardCompare(b)
        } else if case .text(let a) = x, y.number == nil {
            r = a.localizedStandardCompare(y.string)
        } else if case .text(let b) = y, x.number == nil {
            r = x.string.localizedStandardCompare(b)
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
            throw MeasureError(message: L("Colonne attendue."))
        }
        return f
    }

    /// Base rows grouped by the row of `table` they relate to.
    private func baseRowsByRow(_ table: String, _ rows: [Int]) -> [Int: [Int]] {
        if table == ctx.base.name { return Dictionary(uniqueKeysWithValues: rows.map { ($0, [$0]) }) }
        var out: [Int: [Int]] = [:]
        for b in rows { if let t = ctx.relatedRow(table, b) { out[t, default: []].append(b) } }
        return out
    }

    /// Rows produced by a table expression: Table (rows in the current filter context), ALL(Table), FILTER(…).
    private func tableRows(_ e: Expr, home: String, rows: [Int], filters: [FilterSpec], row: RowContext?,
                           depth: Int) throws -> (table: String, rows: [Int], removesFilters: Bool) {
        switch e {
        case .table(let t):
            guard let table = model.table(t) else { throw MeasureError(message: L("Table introuvable : %@", t)) }
            return (t, ctx.relatedRows(t, rows) ?? Array(table.rows.indices), false)
        case .call("ALL", let a) where a.count == 1:
            guard case .table(let t) = a[0], let table = model.table(t) else { throw MeasureError(message: L("%@ attend une table.", "ALL")) }
            return (t, Array(table.rows.indices), true)
        case .call("FILTER", let a) where a.count == 2:
            let (t, rs, removes) = try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            let map = baseRowsByRow(t, rows)
            let keep = try rs.filter { r in
                try eval(a[1], home: home, rows: rows, filters: filters,
                         row: RowContext(table: t, row: r, baseRows: map[r] ?? []), depth: depth + 1).truthy
            }
            return (t, keep, removes)
        default:
            throw MeasureError(message: L("Table attendue."))
        }
    }

    private func call(_ f: String, _ args: [Expr], home: String, rows: [Int], filters: [FilterSpec], row: RowContext?,
                      depth: Int) throws -> MValue {
        func sub(_ x: Expr) throws -> MValue { try eval(x, home: home, rows: rows, filters: filters, row: row, depth: depth + 1) }

        func aggregate(_ a: Aggregation) throws -> MValue {
            let fr = try column(args[0], home: home)
            guard let values = ctx.values(fr, rows) else {
                throw MeasureError(message: L("Aucune relation ne relie %@ à la table du visuel.", fr.table))
            }
            var acc = Acc(distinct: a == .distinctCount)
            values.forEach { acc.add($0) }
            return acc.result(a).map { .number($0) } ?? .blank
        }

        func calculate(_ expr: Expr, _ filterArgs: [Expr]) throws -> MValue {
            var newFilters = filters
            // As in DAX, filter removers (ALL…) apply before the new filters, whatever their order.
            let isModifier: (Expr) -> Bool = { if case .call(let g, _) = $0 { return MeasureCompiler.filterModifiers.contains(g) }; return false }
            for a in filterArgs.filter(isModifier) + filterArgs.filter({ !isModifier($0) }) {
                newFilters = try applyFilter(a, to: newFilters, home: home, rows: rows, filters: filters, row: row, depth: depth)
            }
            return try eval(expr, home: home, rows: self.rows(for: newFilters), filters: newFilters, row: nil, depth: depth + 1)
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
            let t = try tableRows(args[0], home: home, rows: rows, filters: filters, row: row, depth: depth)
            return t.rows.isEmpty ? .blank : .number(Double(t.rows.count))
        case "SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX":
            let t = try tableRows(args[0], home: home, rows: rows, filters: filters, row: row, depth: depth)
            let map = baseRowsByRow(t.table, rows)
            var acc = Acc(distinct: false)
            for r in t.rows {
                let v = try eval(args[1], home: home, rows: rows, filters: filters,
                                 row: RowContext(table: t.table, row: r, baseRows: map[r] ?? []), depth: depth + 1)
                if f == "COUNTX" { if !v.isBlank { acc.add(.number(1)) } } else if let d = v.number { acc.add(.number(d)) }
            }
            switch f {
            case "SUMX": return acc.result(.sum).map { .number($0) } ?? .blank
            case "AVERAGEX": return acc.result(.average).map { .number($0) } ?? .blank
            case "MINX": return acc.result(.min).map { .number($0) } ?? .blank
            case "MAXX": return acc.result(.max).map { .number($0) } ?? .blank
            default: return acc.count > 0 ? .number(Double(acc.count)) : .blank
            }
        case "RELATED":
            guard let rc = row else { throw MeasureError(message: L("RELATED nécessite un contexte de ligne (SUMX, FILTER, colonne calculée).")) }
            return try cellValue(try column(args[0], home: home), rc)
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
        case "YEAR", "MONTH", "DAY":
            guard let t = try sub(args[0]).number else { return .blank }
            let c = Fmt.calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
            return .number(Double((f == "YEAR" ? c.year : f == "MONTH" ? c.month : c.day) ?? 0))
        case "UPPER": return .text(try sub(args[0]).string.uppercased())
        case "LOWER": return .text(try sub(args[0]).string.lowercased())
        case "LEN": return .number(Double(try sub(args[0]).string.count))
        case "LEFT", "RIGHT":
            let s = try sub(args[0]).string
            let n = Swift.max(0, Int(try sub(args[1]).number ?? 0))
            return .text(String(f == "LEFT" ? s.prefix(n) : s.suffix(n)))
        case "CALCULATE":
            return try calculate(args[0], Array(args.dropFirst()))
        case "TOTALYTD", "TOTALMTD", "TOTALQTD":
            let period = f == "TOTALYTD" ? "DATESYTD" : f == "TOTALMTD" ? "DATESMTD" : "DATESQTD"
            return try calculate(args[0], [.call(period, [args[1]])])
        default:
            throw MeasureError(message: L("Fonction non prise en charge ici : %@", f))
        }
    }

    // MARK: CALCULATE filters

    private func applyFilter(_ a: Expr, to current: [FilterSpec], home: String, rows: [Int],
                             filters: [FilterSpec], row: RowContext?, depth: Int) throws -> [FilterSpec] {
        switch a {
        case .binary("=", let lhs, let rhs):
            let fr = try column(lhs, home: home)
            let v = try eval(rhs, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            let label: String
            switch v {
            case .number(let d): label = GroupKey.of(.number(d), nil).label
            case .text(let s): label = s
            case .bool(let b): label = b ? "VRAI" : "FAUX"
            case .blank: label = GroupKey.blankLabel
            case .date(let d): label = GroupKey.of(.date(d), nil).label
            }
            return current.filter { $0.field.columnKey != fr.columnKey } + [FilterSpec(field: fr, allowed: [label])]
        case .binary(let op, let lhs, let rhs) where ["<>", "<", "<=", ">", ">="].contains(op):
            // Comparison on a column: keep the rows of its table that satisfy it (replaces filters on that column).
            let fr = try column(lhs, home: home)
            let v = try eval(rhs, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            guard let t = model.table(fr.table), let ci = t.columnIndex(fr.column) else { return current }
            let keep = Set(t.rows.indices.filter { compare(MValue(t.rows[$0][ci]), v, op) })
            return current.filter { $0.field.columnKey != fr.columnKey }
                + [FilterSpec(field: FieldRef(table: fr.table, column: fr.column), allowed: [], rowSet: keep)]
        case .call("FILTER", _):
            let t = try tableRows(a, home: home, rows: rows, filters: filters, row: row, depth: depth)
            let base = t.removesFilters ? current.filter { $0.field.table != t.table } : current
            return base + [FilterSpec(field: FieldRef(table: t.table, column: ""), allowed: [], rowSet: Set(t.rows))]
        case .call(let g, let args) where MeasureCompiler.dateFilters.contains(g):
            let fr = try column(args[0], home: home)
            let dates = (ctx.values(fr, rows) ?? []).compactMap(\.date)
            let others = current.filter { $0.field.columnKey != fr.columnKey }
            guard let lo = dates.min(), let hi = dates.max() else {
                return others + [FilterSpec(field: FieldRef(table: fr.table, column: ""), allowed: [], rowSet: [])]
            }
            let cal = Fmt.calendar
            func start(_ comps: Set<Calendar.Component>, _ d: Date) -> Date { cal.date(from: cal.dateComponents(comps, from: d)) ?? d }
            func quarterStart(_ d: Date) -> Date {
                let c = cal.dateComponents([.year, .month], from: d)
                return cal.date(from: DateComponents(year: c.year, month: ((c.month ?? 1) - 1) / 3 * 3 + 1, day: 1)) ?? d
            }
            func add(_ c: Calendar.Component, _ n: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: n, to: d) ?? d }
            func isMonthEnd(_ d: Date) -> Bool { cal.component(.month, from: add(.day, 1, d)) != cal.component(.month, from: d) }
            /// Shifts the end of a period; a month's last day stays the last day (28 Feb 2025 → 29 Feb 2024).
            func shiftEnd(_ c: Calendar.Component, _ n: Int, _ d: Date) -> Date {
                let s = add(c, n, d)
                guard c != .day, isMonthEnd(d) else { return s }
                let next = add(.month, 1, start([.year, .month], s))
                return add(.day, -1, next)
            }
            let endOfDay: TimeInterval = 86_399
            var from = lo, to = hi.addingTimeInterval(endOfDay)
            switch g {
            case "DATESYTD": from = start([.year], hi)
            case "DATESMTD": from = start([.year, .month], hi)
            case "DATESQTD": from = quarterStart(hi)
            case "SAMEPERIODLASTYEAR":
                from = add(.year, -1, lo); to = shiftEnd(.year, -1, hi).addingTimeInterval(endOfDay)
            case "DATEADD":
                let n = Int(try eval(args[1], home: home, rows: rows, filters: filters, row: row, depth: depth + 1).number ?? 0)
                guard case .table(let u) = args[2] else { return current }
                switch u.uppercased() {
                case "YEAR": from = add(.year, n, lo); to = shiftEnd(.year, n, hi)
                case "QUARTER": from = add(.month, 3 * n, lo); to = shiftEnd(.month, 3 * n, hi)
                case "MONTH": from = add(.month, n, lo); to = shiftEnd(.month, n, hi)
                default: from = add(.day, n, lo); to = add(.day, n, hi)
                }
                to = to.addingTimeInterval(endOfDay)
            case "PREVIOUSMONTH":
                let m = start([.year, .month], lo)
                from = add(.month, -1, m); to = m.addingTimeInterval(-1)
            case "PREVIOUSYEAR":
                let y = start([.year], lo)
                from = add(.year, -1, y); to = y.addingTimeInterval(-1)
            default: break
            }
            return others + [FilterSpec(field: FieldRef(table: fr.table, column: fr.column), allowed: [],
                                        range: from.timeIntervalSince1970...to.timeIntervalSince1970)]
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
            throw MeasureError(message: L("Filtre de CALCULATE non pris en charge."))
        }
    }
}
