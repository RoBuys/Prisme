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
    /// VAR name = expr … RETURN body
    case letIn([(String, Expr)], Expr)
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
        // Comments: -- … and // … to the end of the line, /* … */ blocks.
        if (c == "-" && peek(1) == "-") || (c == "/" && peek(1) == "/") {
            while let d = peek(), d != "\n" { i += 1 }
            continue
        }
        if c == "/" && peek(1) == "*" {
            i += 2
            while i < chars.count, !(chars[i] == "*" && peek(1) == "/") { i += 1 }
            i += 2
            continue
        }
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
        case "{": tokens.append(.op("{")); i += 1
        case "}": tokens.append(.op("}")); i += 1
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
        if case .ident(let id) = current, id.uppercased() == "VAR" { return try parseVar() }
        var l = try parseAnd()
        while current == .op("||") { advance(); l = .binary("||", l, try parseAnd()) }
        return l
    }

    mutating func parseVar() throws -> Expr {
        var defs: [(String, Expr)] = []
        while case .ident(let kw) = current, kw.uppercased() == "VAR" {
            advance()
            guard case .ident(let name) = current else { throw MeasureError(message: L("Nom de variable attendu après VAR.")) }
            advance()
            guard current == .op("=") else { throw MeasureError(message: L("« = » attendu après VAR %@.", name)) }
            advance()
            defs.append((name, try parseOr()))
        }
        guard case .ident(let kw) = current, kw.uppercased() == "RETURN" else {
            throw MeasureError(message: L("RETURN attendu après les variables."))
        }
        advance()
        return .letIn(defs, try parseOr())
    }

    mutating func parseAnd() throws -> Expr {
        var l = try parseComparison()
        while current == .op("&&") { advance(); l = .binary("&&", l, try parseComparison()) }
        return l
    }

    mutating func parseComparison() throws -> Expr {
        var l = try parseAdditive()
        while true {
            if case .op(let o) = current, ["=", "<>", "<", "<=", ">", ">="].contains(o) {
                advance()
                l = .binary(o, l, try parseAdditive())
            } else if case .ident(let kw) = current, kw.uppercased() == "IN" {
                // x IN { a, b, … }
                advance()
                guard current == .op("{") else { throw MeasureError(message: L("« { » attendu après IN.")) }
                advance()
                var items: [Expr] = []
                while current != .op("}") {
                    items.append(try parseAdditive())
                    if current == .comma { advance() } else if current != .op("}") {
                        throw MeasureError(message: L("« } » attendu."))
                    }
                }
                advance()
                l = .call("__IN", [l] + items)
            } else {
                return l
            }
        }
    }

    /// `&` binds less tightly than + and - (as in DAX: "a" & 1 + 2 is "a3").
    mutating func parseAdditive() throws -> Expr {
        var l = try parseSum()
        while case .op(let o) = current, o == "&" {
            advance()
            l = .binary(o, l, try parseSum())
        }
        return l
    }

    mutating func parseSum() throws -> Expr {
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
        // `NOT expr` (without parentheses) negates a comparison: NOT a = b means NOT (a = b).
        if case .ident(let id) = current, id.uppercased() == "NOT", pos + 1 < tokens.count, tokens[pos + 1] != .lparen {
            advance()
            return .unary("!", try parseComparison())
        }
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
    nonisolated(unsafe) private static var cache: [String: Result<Expr, MeasureError>] = [:]
    /// Calculated columns are evaluated on several threads.
    private static let cacheLock = NSLock()

    static func parse(_ source: String) -> Result<Expr, MeasureError> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
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
        "MID": 3...3, "CEILING": 1...2, "FLOOR": 1...2, "TRIM": 1...1, "SUBSTITUTE": 3...4, "SEARCH": 2...4, "FIND": 2...4,
        "DATESYTD": 1...1, "DATESMTD": 1...1, "DATESQTD": 1...1, "SAMEPERIODLASTYEAR": 1...1, "DATEADD": 3...3,
        "PREVIOUSMONTH": 1...1, "PREVIOUSYEAR": 1...1, "TOTALYTD": 2...2, "TOTALMTD": 2...2, "TOTALQTD": 2...2,
        "SWITCH": 3...1001, "SELECTEDVALUE": 1...2, "HASONEVALUE": 1...1, "ISFILTERED": 1...1, "VALUES": 1...1,
        "ALLEXCEPT": 2...10, "KEEPFILTERS": 1...1, "USERELATIONSHIP": 2...2, "LOOKUPVALUE": 3...21, "RANKX": 2...4,
        "TOPN": 3...4, "DATEDIFF": 3...3, "EOMONTH": 2...2, "DATE": 3...3, "TODAY": 0...0, "FORMAT": 2...2,
        "CONCATENATE": 2...2, "INT": 1...1, "MOD": 2...2, "POWER": 2...2, "SQRT": 1...1, "VALUE": 1...1,
        "COUNTAX": 2...2, "__IN": 1...1000, "MROUND": 2...2, "ROUNDUP": 1...2, "ROUNDDOWN": 1...2,
        "SUMMARIZE": 1...41, "SUMMARIZECOLUMNS": 1...41, "ADDCOLUMNS": 3...41, "SELECTCOLUMNS": 3...41,
        "CALCULATETABLE": 1...20, "DISTINCT": 1...1,
        "CONTAINSSTRING": 2...2, "UNICHAR": 1...1, "IFERROR": 2...2, "ISEMPTY": 1...1, "WEEKDAY": 1...2,
        "DISTINCTCOUNTNOBLANK": 1...1, "CALENDAR": 2...2, "CALENDARAUTO": 0...1, "GENERATESERIES": 2...3,
    ]
    /// Functions that return a table.
    static let tableFunctions: Set<String> = ["FILTER", "VALUES", "DISTINCT", "TOPN", "SUMMARIZE", "SUMMARIZECOLUMNS",
                                              "ADDCOLUMNS", "SELECTCOLUMNS", "CALCULATETABLE", "CALENDAR", "CALENDARAUTO",
                                              "GENERATESERIES"]
    /// Tables that aren't model tables: one generated column.
    static let generatedTables: [String: String] = ["CALENDAR": "Date", "CALENDARAUTO": "Date", "GENERATESERIES": "Value"]

    /// The single column a boolean CALCULATE filter is about (`OR(T[C] = 1, T[C] >= 3)`, `ISBLANK(T[C])`, `NOT …`),
    /// or nil when the filter has another form.
    static func booleanFilterColumn(_ a: Expr, home: String, _ m: DataModel) -> FieldRef? {
        switch a {
        case .call(let g, _) where filterModifiers.contains(g) || dateFilters.contains(g) || tableFunctions.contains(g)
                                 || ["KEEPFILTERS", "__IN", "USERELATIONSHIP", "ALLEXCEPT"].contains(g):
            return nil
        case .binary(let op, .ref, _) where ["=", "<>", "<", "<=", ">", ">="].contains(op):
            return nil
        case .call, .unary, .binary: break
        default: return nil
        }
        var cols = Set<String>(), first: FieldRef?, ok = true
        func walk(_ e: Expr) {
            switch e {
            case .ref(let t, let n):
                switch resolve(table: t, name: n, home: home, m) {
                case .column(let f): if cols.insert(f.columnKey).inserted { first = f }
                default: ok = false
                }
            case .unary(_, let x): walk(x)
            case .binary(_, let x, let y): walk(x); walk(y)
            case .call(let g, let args):
                if tableFunctions.contains(g) || aggregations.contains(g) || iterators.contains(g) || g == "CALCULATE" { ok = false }
                args.forEach(walk)
            case .letIn: ok = false
            default: break
            }
        }
        walk(a)
        return ok && cols.count == 1 ? first : nil
    }

    /// Whether an expression produces a table (used to tell table variables from scalar ones).
    static func isTableExpr(_ e: Expr, isTableVar: (String) -> Bool, _ m: DataModel) -> Bool {
        switch e {
        case .table(let t): return isTableVar(t.lowercased()) || m.table(t) != nil
        case .letIn(_, let body): return isTableExpr(body, isTableVar: { _ in true }, m)
        case .call(let f, let a):
            if tableFunctions.contains(f) { return true }
            if f == "ALL" && a.count == 1 { return true }
            if f == "KEEPFILTERS" && a.count == 1 { return isTableExpr(a[0], isTableVar: isTableVar, m) }
            return false
        default: return false
        }
    }

    /// Names of the columns a table expression adds (ADDCOLUMNS, SUMMARIZE…), as "[name]" keys.
    static func virtualColumns(_ e: Expr) -> Set<String> {
        if case .letIn(let defs, let body) = e {
            return defs.reduce(virtualColumns(body)) { $0.union(virtualColumns($1.1)) }
        }
        if case .call(let f, _) = e, let n = generatedTables[f] { return ["[" + n.lowercased() + "]"] }
        guard case .call(let f, let a) = e, !a.isEmpty else { return [] }
        var out: Set<String> = []
        switch f {
        case "ADDCOLUMNS", "SELECTCOLUMNS", "SUMMARIZE":
            out = virtualColumns(a[0])
            for x in a.dropFirst() { if case .string(let n) = x { out.insert("[" + n.lowercased() + "]") } }
        case "SUMMARIZECOLUMNS":
            for x in a { if case .string(let n) = x { out.insert("[" + n.lowercased() + "]") } }
        case "FILTER", "KEEPFILTERS", "CALCULATETABLE", "DISTINCT", "VALUES": out = virtualColumns(a[0])
        case "TOPN": if a.count > 1 { out = virtualColumns(a[1]) }
        default: break
        }
        return out
    }

    /// Checks a calculated table expression. Returns nil when it is valid.
    static func validateTable(_ source: String, _ m: DataModel) -> String? {
        switch parse(source) {
        case .failure(let e): return e.message
        case .success(let e):
            guard isTableExpr(e, isTableVar: { _ in false }, m) || { if case .letIn = e { return true }; return false }() else {
                return L("L'expression doit renvoyer une table (SUMMARIZE, ADDCOLUMNS, FILTER, VALUES…).")
            }
            do {
                try check(.call("COUNTROWS", [e]), home: m.tables.first?.name ?? "", m, visiting: [], inCalculateFilter: false)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
    static let aggregations: Set<String> = ["SUM", "AVERAGE", "COUNT", "COUNTA", "DISTINCTCOUNT", "DISTINCTCOUNTNOBLANK"]
    static let filterModifiers: Set<String> = ["ALL", "ALLSELECTED", "REMOVEFILTERS", "ALLEXCEPT"]
    static let iterators: Set<String> = ["SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX", "COUNTAX"]
    /// Time-intelligence filters, valid as CALCULATE arguments.
    static let dateFilters: Set<String> = ["DATESYTD", "DATESMTD", "DATESQTD", "SAMEPERIODLASTYEAR", "DATEADD",
                                           "PREVIOUSMONTH", "PREVIOUSYEAR"]
    static let dateUnits: Set<String> = ["YEAR", "QUARTER", "MONTH", "DAY"]
    static let diffUnits: Set<String> = ["YEAR", "QUARTER", "MONTH", "WEEK", "DAY", "HOUR", "MINUTE", "SECOND"]

    /// What a reference resolves to.
    enum Resolved { case column(FieldRef), measure(Measure) }

    /// Names are case-insensitive, as in DAX; the model's spelling is returned.
    static func resolve(table: String?, name: String, home: String, _ m: DataModel) -> Resolved? {
        if let t = table {
            guard let tbl = m.table(t) else { return nil }
            if let i = tbl.columnIndex(name) { return .column(FieldRef(table: tbl.name, column: tbl.columns[i].name)) }
            if let me = m.measures.first(where: { $0.table.caseInsensitiveEquals(tbl.name) && $0.name.caseInsensitiveEquals(name) }) { return .measure(me) }
            return nil
        }
        if let me = m.measures.first(where: { $0.name.caseInsensitiveEquals(name) }) { return .measure(me) }
        if let tbl = m.table(home), let i = tbl.columnIndex(name) { return .column(FieldRef(table: tbl.name, column: tbl.columns[i].name)) }
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

    private static func check(_ e: Expr, home: String, _ m: DataModel, visiting: Set<String>, inCalculateFilter: Bool,
                              vars: Set<String> = []) throws {
        func sub(_ x: Expr) throws { try check(x, home: home, m, visiting: visiting, inCalculateFilter: false, vars: vars) }
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
        func subWith(_ x: Expr, _ extra: Set<String>) throws {
            try check(x, home: home, m, visiting: visiting, inCalculateFilter: false, vars: vars.union(extra))
        }
        func pairs(_ a: [Expr], from start: Int, _ f: String, extra: Set<String>) throws {
            var i = start
            while i < a.count {
                guard case .string = a[i], i + 1 < a.count else {
                    throw MeasureError(message: L("%@ attend des paires \"nom\", expression.", f))
                }
                try subWith(a[i + 1], extra)
                i += 2
            }
        }
        /// Expressions that produce a table: Table, ALL(Table or column), VALUES / DISTINCT, FILTER, TOPN,
        /// SUMMARIZE, SUMMARIZECOLUMNS, ADDCOLUMNS, SELECTCOLUMNS, CALCULATETABLE, table variables.
        func tableArg(_ x: Expr, _ f: String) throws {
            switch x {
            case .table(let t):
                if vars.contains("#" + t.lowercased()) { return }
                guard m.table(t) != nil else { throw MeasureError(message: L("Table introuvable : %@", t)) }
            case .call("ALL", let a) where a.count == 1:
                if case .ref = a[0] { try columnArg(a[0], "ALL"); return }
                guard case .table(let t) = a[0], m.table(t) != nil else { throw MeasureError(message: L("%@ attend une table.", "ALL")) }
            case .call("VALUES", let a) where a.count == 1, .call("DISTINCT", let a) where a.count == 1:
                if case .ref = a[0] { try columnArg(a[0], "VALUES") } else { try tableArg(a[0], f) }
            case .call("KEEPFILTERS", let a) where a.count == 1:
                try tableArg(a[0], f)
            case .call("TOPN", let a) where a.count >= 3:
                try sub(a[0])
                try tableArg(a[1], "TOPN")
                try subWith(a[2], virtualColumns(a[1]))
            case .call("FILTER", let a) where a.count == 2:
                try tableArg(a[0], "FILTER")
                try subWith(a[1], virtualColumns(a[0]))
            case .call("CALCULATETABLE", let a) where !a.isEmpty:
                try tableArg(a[0], "CALCULATETABLE")
                for b in a.dropFirst() { try filterArg(b) }
            case .call(let g, let a) where generatedTables[g] != nil:
                for b in a { try sub(b) }
            case .letIn:
                // VAR … RETURN <table>: validated like a measure's variables, the body as a table.
                guard case .letIn(let defs, let body) = x else { return }
                try check(.letIn(defs, .call("COUNTROWS", [body])), home: home, m, visiting: visiting, inCalculateFilter: false, vars: vars)
            case .call(let g, let a) where (g == "ADDCOLUMNS" || g == "SELECTCOLUMNS") && a.count >= 3:
                try tableArg(a[0], g)
                try pairs(a, from: 1, g, extra: virtualColumns(a[0]))
            case .call("SUMMARIZE", let a) where !a.isEmpty:
                try tableArg(a[0], "SUMMARIZE")
                var i = 1
                while i < a.count, case .ref = a[i] { try columnArg(a[i], "SUMMARIZE"); i += 1 }
                try pairs(a, from: i, "SUMMARIZE", extra: virtualColumns(a[0]))
            case .call("SUMMARIZECOLUMNS", let a):
                var i = 0
                while i < a.count {
                    switch a[i] {
                    case .ref: try columnArg(a[i], "SUMMARIZECOLUMNS"); i += 1
                    case .string: try pairs(a, from: i, "SUMMARIZECOLUMNS", extra: []); i = a.count
                    default: try filterArg(a[i]); i += 1
                    }
                }
            default:
                throw MeasureError(message: L("%@ attend une table, par exemple %@(Ventes, …).", f, f))
            }
        }
        func filterArg(_ a: Expr) throws {
            switch a {
            case .call(let g, _) where filterModifiers.contains(g) || dateFilters.contains(g):
                try check(a, home: home, m, visiting: visiting, inCalculateFilter: true, vars: vars)
            case .call(let g, _) where tableFunctions.contains(g):
                try tableArg(a, "FILTER")
            case .table(let t) where vars.contains("#" + t.lowercased()):
                return
            case .call("KEEPFILTERS", let k) where k.count == 1:
                try filterArg(k[0])
            case .call("USERELATIONSHIP", let k) where k.count == 2:
                try columnArg(k[0], "USERELATIONSHIP")
                try columnArg(k[1], "USERELATIONSHIP")
            case .call("__IN", let k) where k.count >= 1:
                guard case .ref(let t, let n) = k[0], case .column = resolve(table: t, name: n, home: home, m) else {
                    throw MeasureError(message: L("Le filtre de CALCULATE doit porter sur une colonne."))
                }
                for x in k.dropFirst() { try sub(x) }
            case .binary(let op, .ref(let t, let n), let v) where ["=", "<>", "<", "<=", ">", ">="].contains(op):
                guard case .column = resolve(table: t, name: n, home: home, m) else {
                    throw MeasureError(message: L("Le filtre de CALCULATE doit porter sur une colonne."))
                }
                try sub(v)
            case _ where booleanFilterColumn(a, home: home, m) != nil:
                try check(a, home: home, m, visiting: visiting, inCalculateFilter: false, vars: vars)
            default:
                throw MeasureError(message: L("Filtre de CALCULATE non pris en charge. Utilisez Table[Colonne] = valeur, une comparaison, FILTER(…), ALL(…), ALLSELECTED(…), REMOVEFILTERS(…) ou une fonction de dates."))
            }
        }

        switch e {
        case .number, .string, .bool, .blank: return
        case .table(let t):
            if vars.contains(t.lowercased()) || vars.contains("#" + t.lowercased()) { return }
            guard m.table(t) != nil else { throw MeasureError(message: L("Table introuvable : %@", t)) }
        case .letIn(let defs, let body):
            var scope = vars
            for (name, value) in defs {
                if isTableExpr(value, isTableVar: { scope.contains("#" + $0) }, m) {
                    try check(.call("COUNTROWS", [value]), home: home, m, visiting: visiting, inCalculateFilter: false, vars: scope)
                    scope.insert("#" + name.lowercased())
                    scope.formUnion(virtualColumns(value))
                } else {
                    try check(value, home: home, m, visiting: visiting, inCalculateFilter: false, vars: scope)
                    scope.insert(name.lowercased())
                }
            }
            try check(body, home: home, m, visiting: visiting, inCalculateFilter: false, vars: scope)
        case .ref(let t, let n):
            if vars.contains("[" + n.lowercased() + "]") && (t == nil || resolve(table: t, name: n, home: home, m) == nil) { return }
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
            if f == "COUNTROWS" || f == "ISEMPTY" { try tableArg(args[0], f); return }
            if f == "VALUES" || f == "TOPN" || (tableFunctions.contains(f) && f != "FILTER") {
                throw MeasureError(message: L("%@ renvoie une table : utilisez-le dans COUNTROWS, SUMX, RANKX ou CALCULATE.", f))
            }
            if f == "SELECTEDVALUE" || f == "HASONEVALUE" || f == "ISFILTERED" {
                try columnArg(args[0], f)
                for a in args.dropFirst() { try sub(a) }
                return
            }
            if f == "RANKX" {
                try tableArg(args[0], f)
                try subWith(args[1], virtualColumns(args[0]))
                if args.count > 2 { try sub(args[2]) }
                if args.count > 3 {
                    guard case .table(let o) = args[3], ["ASC", "DESC"].contains(o.uppercased()) else {
                        throw MeasureError(message: L("RANKX : l'ordre doit être ASC ou DESC."))
                    }
                }
                return
            }
            if f == "LOOKUPVALUE" {
                try columnArg(args[0], f)
                guard args.count % 2 == 1 else { throw MeasureError(message: L("LOOKUPVALUE attend des paires colonne / valeur.")) }
                var i = 1
                while i < args.count { try columnArg(args[i], f); try sub(args[i + 1]); i += 2 }
                return
            }
            if f == "DATEDIFF" {
                try sub(args[0]); try sub(args[1])
                guard case .table(let u) = args[2], diffUnits.contains(u.uppercased()) else {
                    throw MeasureError(message: L("DATEDIFF attend une unité : YEAR, QUARTER, MONTH, WEEK, DAY, HOUR, MINUTE ou SECOND."))
                }
                return
            }
            if f == "KEEPFILTERS" || f == "USERELATIONSHIP" {
                guard inCalculateFilter else { throw MeasureError(message: L("%@ ne peut être utilisé que comme filtre de CALCULATE.", f)) }
                return
            }
            if iterators.contains(f) {
                try tableArg(args[0], f)
                try subWith(args[1], virtualColumns(args[0]))
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
                if f == "ALLEXCEPT" {
                    guard case .table(let t) = args[0], m.table(t) != nil else { throw MeasureError(message: L("%@ attend une table.", f)) }
                    for a in args.dropFirst() { try columnArg(a, f) }
                    return
                }
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
                for a in args.dropFirst() { try filterArg(a) }
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
            case .table(let t): if m.table(t) != nil { out.append(FieldRef(table: t, column: "")) }
            case .ref(let t, let n):
                switch resolve(table: t, name: n, home: home, m) {
                case .column(let f): out.append(f)
                case .measure(let inner): out += dependencies(inner, m, visiting: visiting.union([me.name.lowercased()]))
                case nil: break
                }
            case .unary(_, let a): walk(a, home: home)
            case .binary(_, let a, let b): walk(a, home: home); walk(b, home: home)
            case .letIn(let defs, let body): defs.forEach { walk($0.1, home: home) }; walk(body, home: home)
            case .call(let f, let args):
                if f == "USERELATIONSHIP" { return }
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
    /// Filter context the row was produced in, and the filters that stand for "this row" in a context transition.
    var filters: [FilterSpec] = []
    var transitions: [FilterSpec] = []
    /// Values of the columns added by ADDCOLUMNS / SUMMARIZE…, keyed by lowercased name.
    var values: [String: MValue] = [:]
}

/// Rows produced by a table expression, with what's needed to evaluate measures for each of them.
struct TableRows {
    var table: String
    var rows: [Int]
    var removesFilters = false
    /// Base rows and filters of the context the table was taken in.
    var baseRows: [Int]
    var filters: [FilterSpec]
    /// Grouped tables (VALUES, ALL(column), SUMMARIZE): representative row → base rows and transition filters.
    var groups: [Int: [Int]]?
    var transitions: [Int: [FilterSpec]]?
    /// Grouped tables: representative row → rows of `table` in the group.
    var sources: [Int: [Int]]?
    /// Added columns (ADDCOLUMNS, SUMMARIZE…): row → values by lowercased name; names in order.
    var extras: [Int: [String: MValue]]?
    var extraNames: [String] = []
    /// Columns of a grouped table; `selectOnly` keeps only the added columns (SELECTCOLUMNS).
    var groupBy: [FieldRef]?
    var selectOnly = false
}

/// Evaluates measures over sets of base rows, within a filter context.
final class MeasureEvaluator {
    let ctx: QueryContext
    let model: DataModel
    private var rowCache: [String: [Int]] = [:]
    private var tableContexts: [String: QueryContext] = [:]
    /// VAR scopes (innermost last), for scalar and table variables.
    private var scopes: [[String: MValue]] = []
    private var tableScopes: [[String: TableRows]] = []

    private func tableVar(_ name: String) -> TableRows? {
        for scope in tableScopes.reversed() { if let t = scope[name.lowercased()] { return t } }
        return nil
    }

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

    private lazy var allBaseRows = sharedAllRows ?? Array(ctx.base.rows.indices)
    /// All base rows, shared by the evaluators of a parallel calculated column.
    var sharedAllRows: [Int]?

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
    private var accessors: [Key: (Int) -> CellValue] = [:]

    private func cellValue(_ f: FieldRef, _ rc: RowContext) throws -> MValue {
        let key = Key(a: rc.table, b: f.table, c: f.column)
        if let get = accessors[key] { return MValue(get(rc.row)) }
        guard let qc = tableContext(rc.table), let get = qc.accessor(f) else {
            throw MeasureError(message: L("Aucune relation ne relie %@ à %@.", f.table, rc.table))
        }
        accessors[key] = get
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
        case .table(let name):
            for scope in scopes.reversed() { if let v = scope[name.lowercased()] { return v } }
            throw MeasureError(message: L("Une table ne peut pas être utilisée comme valeur."))
        case .letIn(let defs, let body):
            scopes.append([:])
            tableScopes.append([:])
            defer { scopes.removeLast(); tableScopes.removeLast() }
            for (name, value) in defs {
                if MeasureCompiler.isTableExpr(value, isTableVar: { self.tableVar($0) != nil }, model) {
                    tableScopes[tableScopes.count - 1][name.lowercased()] =
                        try tableRows(value, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
                } else {
                    scopes[scopes.count - 1][name.lowercased()] = try eval(value, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
                }
            }
            return try eval(body, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
        case .ref(let t, let n):
            if let r = row, !r.values.isEmpty, let v = r.values[n.lowercased()] { return v }
            switch resolve(t, n, home) {
            case .measure(let me):
                guard case .success(let inner) = MeasureCompiler.parse(me.expression) else { return .blank }
                if let rc = row {
                    // Context transition: the measure sees only the current row.
                    let t = rc.transitions.isEmpty ? [FilterSpec(field: FieldRef(table: rc.table, column: ""), allowed: [], rowSet: [rc.row])] : rc.transitions
                    let f = (rc.filters.isEmpty ? filters : rc.filters) + t
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
            case "+" where Self.isDate(x) || Self.isDate(y), "-" where Self.isDate(x) || Self.isDate(y):
                // Dates count in days: date - date is a number of days, date ± n moves by n days.
                if x.isBlank && y.isBlank { return .blank }
                let p = Self.days(x), q = Self.days(y)
                let r = o == "+" ? p + q : p - q
                if Self.isDate(x) && Self.isDate(y) && o == "-" { return .number(r) }
                return .date(Date(timeIntervalSince1970: r * 86_400))
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

    /// Year, month and day of a UTC timestamp (Fmt.calendar is UTC), without Calendar's cost on large tables.
    /// Days-to-civil algorithm by Howard Hinnant.
    static func civil(_ t: Double) -> (year: Int, month: Int, day: Int) {
        let z = Int((t / 86_400).rounded(.down)) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    private static func isDate(_ v: MValue) -> Bool { if case .date = v { return true }; return false }

    /// A value in days (dates since 1970, numbers as they are).
    private static func days(_ v: MValue) -> Double {
        if case .date(let d) = v { return d.timeIntervalSince1970 / 86_400 }
        return v.number ?? 0
    }

    /// References resolved once per evaluator (bare names otherwise scan every measure on each row).
    private struct Key: Hashable { let a: String?, b: String, c: String }
    private var resolved: [Key: MeasureCompiler.Resolved?] = [:]

    private func resolve(_ t: String?, _ n: String, _ home: String) -> MeasureCompiler.Resolved? {
        let key = Key(a: t, b: n, c: home)
        if let r = resolved[key] { return r }
        let r = MeasureCompiler.resolve(table: t, name: n, home: home, model)
        resolved[key] = r
        return r
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
        guard case .ref(let t, let n) = e, case .column(let f) = resolve(t, n, home) else {
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

    /// Removes the filters an ALL(table) would remove.
    private func withoutFilters(on table: String, _ filters: [FilterSpec]) -> [FilterSpec] {
        let tables = Set(model.reachable(from: table).map(\.table))
        return filters.filter { !tables.contains($0.field.table) }
    }

    func rowContext(_ t: TableRows, _ r: Int) -> RowContext {
        let base = t.groups?[r] ?? (t.table.isEmpty ? [] : t.table == ctx.base.name ? [r] : baseRowsByRow(t.table, t.baseRows)[r] ?? [])
        return RowContext(table: t.table, row: r, baseRows: base, filters: t.filters, transitions: t.transitions?[r] ?? [],
                          values: t.extras?[r] ?? [:])
    }

    /// CALENDAR, CALENDARAUTO and GENERATESERIES: a one-column table that isn't in the model (rows hold values only).
    private func generatedTable(_ f: String, _ a: [Expr], home: String, rows: [Int], filters: [FilterSpec], row: RowContext?,
                                depth: Int) throws -> TableRows {
        func sub(_ x: Expr) throws -> MValue { try eval(x, home: home, rows: rows, filters: filters, row: row, depth: depth + 1) }
        func date(_ v: MValue) -> Date? {
            if case .date(let d) = v { return d }
            return v.number.map { Date(timeIntervalSince1970: $0) }
        }
        let cal = Fmt.calendar
        var values: [MValue] = []
        switch f {
        case "GENERATESERIES":
            guard let lo = try sub(a[0]).number, let hi = try sub(a[1]).number else { break }
            let step = a.count > 2 ? (try sub(a[2]).number ?? 1) : 1
            guard step != 0, abs((hi - lo) / step) < 1_000_000 else { throw MeasureError(message: L("GENERATESERIES : pas invalide.")) }
            var x = lo
            while step > 0 ? x <= hi + 1e-9 : x >= hi - 1e-9 { values.append(.number(x)); x += step }
        default:
            var lo: Date?, hi: Date?
            if f == "CALENDAR" {
                lo = date(try sub(a[0])); hi = date(try sub(a[1]))
            } else {
                // Whole years spanning the dates of the model's data columns.
                let dates = model.tables.filter { $0.expression == nil }.flatMap { t in
                    t.columns.indices.filter { t.columns[$0].type == .date && t.columns[$0].expression == nil }
                        .flatMap { c in t.rows.compactMap { $0[c].date } }
                }
                lo = dates.min().flatMap { cal.date(from: DateComponents(year: cal.component(.year, from: $0), month: 1, day: 1)) }
                hi = dates.max().flatMap { cal.date(from: DateComponents(year: cal.component(.year, from: $0), month: 12, day: 31)) }
            }
            guard let start = lo.map({ cal.startOfDay(for: $0) }), let end = hi, end >= start else { break }
            guard end.timeIntervalSince(start) < 86_400 * 366 * 200 else { throw MeasureError(message: L("%@ : période trop longue.", f)) }
            var d = start
            while d <= end { values.append(.date(d)); d = cal.date(byAdding: .day, value: 1, to: d)! }
        }
        let name = MeasureCompiler.generatedTables[f] ?? "Value"
        return TableRows(table: "", rows: Array(values.indices), baseRows: [], filters: filters,
                         extras: Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, [name.lowercased(): $0.element]) }),
                         extraNames: [name], selectOnly: true)
    }

    /// A column reference with the table's own spelling of the column name.
    private func canonical(_ f: FieldRef) -> FieldRef {
        guard let t = model.table(f.table), let c = t.columns.first(where: { $0.name.caseInsensitiveEquals(f.column) }) else { return f }
        return FieldRef(table: f.table, column: c.name)
    }

    /// `"name", expression` pairs starting at `start`.
    private func namedPairs(_ a: [Expr], from start: Int) -> [(String, Expr)] {
        stride(from: start, to: a.count - 1, by: 2).compactMap { i in
            if case .string(let n) = a[i] { return (n, a[i + 1]) }
            return nil
        }
    }

    /// SUMMARIZE: one row per distinct combination of the group columns; added columns are evaluated in each
    /// group's filter context.
    private func summarize(_ src: TableRows, by columns: [FieldRef], pairs: [(String, Expr)], home: String, depth: Int) throws -> TableRows {
        let cols = columns.map(canonical)
        var reps: [String: Int] = [:]
        var order: [Int] = []
        var groups: [Int: [Int]] = [:], sources: [Int: [Int]] = [:]
        var transitions: [Int: [FilterSpec]] = [:]
        for r in src.rows {
            let rc = rowContext(src, r)
            let labels = try cols.map { GroupKey.of(try cellValue($0, rc).cell, nil).label }
            let key = labels.joined(separator: "\u{1F}")
            if let rep = reps[key] {
                groups[rep]!.append(contentsOf: rc.baseRows)
                sources[rep]!.append(r)
                continue
            }
            reps[key] = r
            order.append(r)
            groups[r] = rc.baseRows
            sources[r] = [r]
            transitions[r] = zip(cols, labels).map { FilterSpec(field: $0, allowed: [$1]) }
        }
        var extras: [Int: [String: MValue]] = [:]
        for r in order {
            var values: [String: MValue] = [:]
            for (n, x) in pairs {
                values[n.lowercased()] = try eval(x, home: home, rows: groups[r] ?? [], filters: src.filters + (transitions[r] ?? []),
                                                  row: nil, depth: depth + 1)
            }
            extras[r] = values
        }
        return TableRows(table: src.table, rows: order, baseRows: src.baseRows, filters: src.filters, groups: groups,
                         transitions: transitions, sources: sources, extras: extras, extraNames: pairs.map(\.0), groupBy: cols)
    }

    /// Filter context after CALCULATE-style filter arguments (filter removers apply first, as in DAX).
    private func contextFilters(_ filterArgs: [Expr], home: String, rows: [Int], filters: [FilterSpec], row: RowContext?,
                                depth: Int) throws -> [FilterSpec] {
        var newFilters = filters
        let isModifier: (Expr) -> Bool = { if case .call(let g, _) = $0 { return MeasureCompiler.filterModifiers.contains(g) }; return false }
        for a in filterArgs.filter(isModifier) + filterArgs.filter({ !isModifier($0) }) {
            newFilters = try applyFilter(a, to: newFilters, home: home, rows: rows, filters: filters, row: row, depth: depth)
        }
        return newFilters
    }

    /// Evaluates a calculated table over the whole model: column names and rows.
    func evaluateTable(_ e: Expr) throws -> (columns: [String], rows: [[MValue]]) {
        let all = rows(for: [])
        let t = try tableRows(e, home: ctx.base.name, rows: all, filters: [], row: nil, depth: 0)
        var cols: [(String, FieldRef?)] = []
        if let g = t.groupBy {
            cols = g.map { ($0.column, $0) }
        } else if !t.selectOnly, let table = model.table(t.table) {
            cols = table.columns.map { ($0.name, FieldRef(table: t.table, column: $0.name)) }
        }
        if t.selectOnly { cols = [] }
        cols += t.extraNames.map { ($0, nil) }
        var seen = Set<String>()
        cols = cols.filter { seen.insert($0.0.lowercased()).inserted }
        let out = try t.rows.map { r -> [MValue] in
            let rc = rowContext(t, r)
            return try cols.map { c in
                if let v = rc.values[c.0.lowercased()], c.1 == nil || t.groupBy == nil { return v }
                guard let f = c.1 else { return .blank }
                return try cellValue(f, rc)
            }
        }
        return (cols.map(\.0), out)
    }

    /// Rows produced by a table expression: Table (rows in the current filter context), ALL(Table or column),
    /// VALUES(column), FILTER(…), TOPN(…).
    private func tableRows(_ e: Expr, home: String, rows: [Int], filters: [FilterSpec], row: RowContext?,
                           depth: Int) throws -> TableRows {
        switch e {
        case .table(let t) where tableVar(t) != nil:
            return tableVar(t)!
        case .call(let g, let a) where MeasureCompiler.generatedTables[g] != nil:
            return try generatedTable(g, a, home: home, rows: rows, filters: filters, row: row, depth: depth)
        case .letIn(let defs, let body):
            scopes.append([:])
            tableScopes.append([:])
            defer { scopes.removeLast(); tableScopes.removeLast() }
            for (name, value) in defs {
                if MeasureCompiler.isTableExpr(value, isTableVar: { self.tableVar($0) != nil }, model) {
                    tableScopes[tableScopes.count - 1][name.lowercased()] =
                        try tableRows(value, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
                } else {
                    scopes[scopes.count - 1][name.lowercased()] = try eval(value, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
                }
            }
            return try tableRows(body, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
        case .table(let t):
            guard let table = model.table(t) else { throw MeasureError(message: L("Table introuvable : %@", t)) }
            return TableRows(table: table.name, rows: ctx.relatedRows(t, rows) ?? Array(table.rows.indices), baseRows: rows, filters: filters)
        case .call("ALL", let a) where a.count == 1:
            if case .ref = a[0] {
                let fr = try column(a[0], home: home)
                let f2 = filters.filter { $0.field.columnKey != fr.columnKey }
                return try distinctRows(fr, baseRows: self.rows(for: f2), filters: f2, removes: true)
            }
            guard case .table(let t) = a[0], let table = model.table(t) else { throw MeasureError(message: L("%@ attend une table.", "ALL")) }
            let f2 = withoutFilters(on: t, filters)
            return TableRows(table: t, rows: Array(table.rows.indices), removesFilters: true, baseRows: self.rows(for: f2), filters: f2)
        case .call("VALUES", let a) where a.count == 1, .call("DISTINCT", let a) where a.count == 1:
            guard case .ref = a[0] else { return try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1) }
            return try distinctRows(try column(a[0], home: home), baseRows: rows, filters: filters, removes: false)
        case .call("CALCULATETABLE", let a) where !a.isEmpty:
            let nf = try contextFilters(Array(a.dropFirst()), home: home, rows: rows, filters: filters, row: row, depth: depth)
            return try tableRows(a[0], home: home, rows: self.rows(for: nf), filters: nf, row: nil, depth: depth + 1)
        case .call(let g, let a) where (g == "ADDCOLUMNS" || g == "SELECTCOLUMNS") && a.count >= 3:
            var t = try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            let pairs = namedPairs(a, from: 1)
            var extras = t.extras ?? [:]
            for r in t.rows {
                let rc = rowContext(t, r)
                var values = g == "SELECTCOLUMNS" ? [:] : rc.values
                for (n, x) in pairs {
                    values[n.lowercased()] = try eval(x, home: home, rows: rows, filters: filters, row: rc, depth: depth + 1)
                }
                extras[r] = values
            }
            t.extras = extras
            if g == "SELECTCOLUMNS" {
                t.extraNames = pairs.map(\.0)
                t.selectOnly = true
            } else {
                t.extraNames += pairs.map(\.0)
            }
            return t
        case .call("SUMMARIZE", let a) where !a.isEmpty:
            let src = try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            var i = 1
            var cols: [FieldRef] = []
            while i < a.count, case .ref = a[i] { cols.append(try column(a[i], home: home)); i += 1 }
            return try summarize(src, by: cols, pairs: namedPairs(a, from: i), home: home, depth: depth)
        case .call("SUMMARIZECOLUMNS", let a):
            var cols: [FieldRef] = [], filterArgs: [Expr] = []
            var i = 0
            while i < a.count {
                if case .ref = a[i] { cols.append(try column(a[i], home: home)); i += 1; continue }
                if case .string = a[i] { break }
                filterArgs.append(a[i])
                i += 1
            }
            let pairs = namedPairs(a, from: i)
            let nf = try contextFilters(filterArgs, home: home, rows: rows, filters: filters, row: row, depth: depth)
            let base = self.rows(for: nf)
            var t = try summarize(TableRows(table: ctx.base.name, rows: base, baseRows: base, filters: nf),
                                  by: cols, pairs: pairs, home: home, depth: depth)
            // Like SUMMARIZECOLUMNS, drop the groups where every added column is blank.
            if !pairs.isEmpty {
                t.rows = t.rows.filter { r in pairs.contains { !(t.extras?[r]?[$0.0.lowercased()]?.isBlank ?? true) } }
            }
            return t
        case .call("KEEPFILTERS", let a) where a.count == 1:
            return try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
        case .call("FILTER", let a) where a.count == 2:
            var t = try tableRows(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            t.rows = try t.rows.filter { r in
                try eval(a[1], home: home, rows: rows, filters: filters, row: rowContext(t, r), depth: depth + 1).truthy
            }
            return t
        case .call("TOPN", let a) where a.count >= 3:
            let n = Int(try eval(a[0], home: home, rows: rows, filters: filters, row: row, depth: depth + 1).number ?? 0)
            var t = try tableRows(a[1], home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            let ascending: Bool = { if a.count > 3, case .table(let o) = a[3] { return o.uppercased() == "ASC" }; return false }()
            let scored = try t.rows.map { r in
                (r, try eval(a[2], home: home, rows: rows, filters: filters, row: rowContext(t, r), depth: depth + 1).number ?? -.infinity)
            }
            t.rows = scored.sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }.prefix(max(0, n)).map(\.0)
            return t
        default:
            throw MeasureError(message: L("Table attendue."))
        }
    }

    /// One representative row per distinct value of a column, among the rows related to `baseRows`.
    private func distinctRows(_ fr: FieldRef, baseRows: [Int], filters: [FilterSpec], removes: Bool) throws -> TableRows {
        guard let get = ctx.accessor(fr), let table = model.table(fr.table), let ci = table.columnIndex(fr.column) else {
            throw MeasureError(message: L("Aucune relation ne relie %@ à la table du visuel.", fr.table))
        }
        var reps: [String: Int] = [:]
        var order: [Int] = []
        var groups: [Int: [Int]] = [:]
        var transitions: [Int: [FilterSpec]] = [:]
        for b in baseRows {
            let label = GroupKey.of(get(b), nil).label
            if let r = reps[label] { groups[r]!.append(b); continue }
            guard let r = ctx.relatedRow(fr.table, b) else { continue }
            reps[label] = r
            order.append(r)
            groups[r] = [b]
            transitions[r] = [FilterSpec(field: FieldRef(table: fr.table, column: table.columns[ci].name), allowed: [label])]
        }
        return TableRows(table: fr.table, rows: order, removesFilters: removes, baseRows: baseRows, filters: filters,
                         groups: groups, transitions: transitions, groupBy: [FieldRef(table: fr.table, column: table.columns[ci].name)])
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
            let useRel = filterArgs.compactMap { a -> (FieldRef, FieldRef)? in
                guard case .call("USERELATIONSHIP", let k) = a, k.count == 2,
                      let x = try? column(k[0], home: home), let y = try? column(k[1], home: home) else { return nil }
                return (x, y)
            }
            if !useRel.isEmpty {
                // Evaluate with a model where these relationships are the active ones.
                var m2 = model
                for (x, y) in useRel {
                    guard let i = m2.relationships.firstIndex(where: {
                        ($0.fromTable == x.table && $0.fromColumn == x.column && $0.toTable == y.table && $0.toColumn == y.column) ||
                        ($0.fromTable == y.table && $0.fromColumn == y.column && $0.toTable == x.table && $0.toColumn == x.column)
                    }) else { throw MeasureError(message: L("USERELATIONSHIP : aucune relation entre %@ et %@.", x.column, y.column)) }
                    let pair = Set([m2.relationships[i].fromTable, m2.relationships[i].toTable])
                    for j in m2.relationships.indices where Set([m2.relationships[j].fromTable, m2.relationships[j].toTable]) == pair {
                        m2.relationships[j].isActive = false
                    }
                    m2.relationships[i].isActive = true
                }
                let child = MeasureEvaluator(ctx: QueryContext(base: ctx.base, model: m2), model: m2)
                child.scopes = scopes
                child.tableScopes = tableScopes
                let rest = filterArgs.filter { if case .call("USERELATIONSHIP", _) = $0 { return false }; return true }
                return try child.call("CALCULATE", [expr] + rest, home: home, rows: child.rows(for: filters), filters: filters,
                                      row: nil, depth: depth + 1)
            }
            let newFilters = try contextFilters(filterArgs, home: home, rows: rows, filters: filters, row: row, depth: depth)
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
        case "__IN":
            let x = try sub(args[0])
            for a in args.dropFirst() where compare(x, try sub(a), "=") { return .bool(true) }
            return .bool(false)
        case "SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX", "COUNTAX":
            let t = try tableRows(args[0], home: home, rows: rows, filters: filters, row: row, depth: depth)
            var acc = Acc(distinct: false)
            for r in t.rows {
                let v = try eval(args[1], home: home, rows: rows, filters: filters, row: rowContext(t, r), depth: depth + 1)
                if f == "COUNTX" || f == "COUNTAX" { if !v.isBlank { acc.add(.number(1)) } } else if let d = v.number { acc.add(.number(d)) }
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
        case "MROUND":
            guard let x = try sub(args[0]).number, let m = try sub(args[1]).number, m != 0 else { return .blank }
            return .number((x / m).rounded() * m)
        case "ROUNDUP", "ROUNDDOWN":
            guard let x = try sub(args[0]).number else { return .blank }
            let p = pow(10.0, Double(args.count > 1 ? Int(try sub(args[1]).number ?? 0) : 0))
            let v = x * p
            return .number((f == "ROUNDUP" ? (v < 0 ? v.rounded(.down) : v.rounded(.up)) : (v < 0 ? v.rounded(.up) : v.rounded(.down))) / p)
        case "ISBLANK": return .bool(try sub(args[0]).isBlank)
        case "AND": return .bool(try sub(args[0]).truthy && sub(args[1]).truthy)
        case "OR": return .bool(try sub(args[0]).truthy || sub(args[1]).truthy)
        case "NOT": return .bool(!(try sub(args[0]).truthy))
        case "COALESCE":
            for a in args { let v = try sub(a); if !v.isBlank { return v } }
            return .blank
        case "YEAR", "MONTH", "DAY":
            guard let t = try sub(args[0]).number else { return .blank }
            let c = Self.civil(t)
            return .number(Double(f == "YEAR" ? c.year : f == "MONTH" ? c.month : c.day))
        case "UPPER": return .text(try sub(args[0]).string.uppercased())
        case "LOWER": return .text(try sub(args[0]).string.lowercased())
        case "LEN": return .number(Double(try sub(args[0]).string.count))
        case "LEFT", "RIGHT":
            let s = try sub(args[0]).string
            let n = Swift.max(0, Int(try sub(args[1]).number ?? 0))
            return .text(String(f == "LEFT" ? s.prefix(n) : s.suffix(n)))
        case "MID":
            let s = try sub(args[0]).string
            let start = Swift.max(1, Int(try sub(args[1]).number ?? 1)), n = Swift.max(0, Int(try sub(args[2]).number ?? 0))
            return .text(String(s.dropFirst(start - 1).prefix(n)))
        case "CEILING", "FLOOR":
            guard let x = try sub(args[0]).number else { return .blank }
            let step = args.count > 1 ? (try sub(args[1]).number ?? 1) : 1
            guard step != 0 else { return .number(0) }
            return .number((f == "CEILING" ? (x / step).rounded(.up) : (x / step).rounded(.down)) * step)
        case "TRIM":
            return .text(try sub(args[0]).string.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        case "SUBSTITUTE":
            let s = try sub(args[0]).string, old = try sub(args[1]).string, new = try sub(args[2]).string
            guard !old.isEmpty else { return .text(s) }
            if args.count > 3, let k = try sub(args[3]).number {
                var parts = s.components(separatedBy: old)
                let i = Int(k)
                guard i >= 1, i < parts.count else { return .text(s) }
                parts[i - 1] += new + parts[i]
                parts.remove(at: i)
                return .text(parts.joined(separator: old))
            }
            return .text(s.replacingOccurrences(of: old, with: new))
        case "SEARCH", "FIND":
            let find = try sub(args[0]).string, within = try sub(args[1]).string
            let start = args.count > 2 ? Swift.max(1, Int(try sub(args[2]).number ?? 1)) : 1
            let hay = String(within.dropFirst(start - 1))
            let options: String.CompareOptions = f == "SEARCH" ? [.caseInsensitive] : []
            if let r = hay.range(of: find, options: options) {
                return .number(Double(hay.distance(from: hay.startIndex, to: r.lowerBound) + start))
            }
            return args.count > 3 ? try sub(args[3]) : .blank
        case "SWITCH":
            let x = try sub(args[0])
            var i = 1
            while i + 1 < args.count {
                if compare(x, try sub(args[i]), "=") { return try sub(args[i + 1]) }
                i += 2
            }
            return i < args.count ? try sub(args[i]) : .blank
        case "SELECTEDVALUE", "HASONEVALUE":
            let fr = try column(args[0], home: home)
            let values = (ctx.values(fr, rows) ?? []).filter { !$0.isEmpty }
            var labels = Set<String>()
            var first: CellValue?
            for v in values { if labels.insert(GroupKey.of(v, nil).label).inserted, first == nil { first = v }; if labels.count > 1 { break } }
            if f == "HASONEVALUE" { return .bool(labels.count == 1) }
            if labels.count == 1, let v = first { return MValue(v) }
            return args.count > 1 ? try sub(args[1]) : .blank
        case "ISFILTERED":
            let fr = try column(args[0], home: home)
            return .bool(filters.contains { $0.isActive && $0.field.columnKey == fr.columnKey })
        case "RANKX":
            let t = try tableRows(args[0], home: home, rows: rows, filters: filters, row: row, depth: depth)
            let values = try t.rows.map { r in try eval(args[1], home: home, rows: rows, filters: filters, row: rowContext(t, r), depth: depth + 1).number }
            let current: Double?
            if args.count > 2, !{ if case .blank = args[2] { return true }; return false }() {
                current = try sub(args[2]).number
            } else {
                current = try eval(args[1], home: home, rows: rows, filters: filters, row: row, depth: depth + 1).number
            }
            guard let cur = current else { return .blank }
            let ascending: Bool = { if args.count > 3, case .table(let o) = args[3] { return o.uppercased() == "ASC" }; return false }()
            let better = values.compactMap { $0 }.filter { ascending ? $0 < cur : $0 > cur }.count
            return .number(Double(better + 1))
        case "LOOKUPVALUE":
            let result = try column(args[0], home: home)
            guard let t = model.table(result.table), let ri = t.columnIndex(result.column) else { return .blank }
            var tests: [(Int, MValue)] = []
            var i = 1
            while i + 1 < args.count {
                let c = try column(args[i], home: home)
                guard c.table == result.table, let ci = t.columnIndex(c.column) else {
                    throw MeasureError(message: L("LOOKUPVALUE : les colonnes doivent appartenir à la même table."))
                }
                tests.append((ci, try sub(args[i + 1])))
                i += 2
            }
            for r in t.rows where tests.allSatisfy({ compare(MValue(r[$0.0]), $0.1, "=") }) { return MValue(r[ri]) }
            return .blank
        case "DATEDIFF":
            guard let a = try sub(args[0]).number, let b = try sub(args[1]).number, case .table(let u) = args[2] else { return .blank }
            let d1 = Date(timeIntervalSince1970: a), d2 = Date(timeIntervalSince1970: b)
            let comp: Calendar.Component = ["YEAR": .year, "QUARTER": .month, "MONTH": .month, "WEEK": .weekOfYear, "DAY": .day,
                                            "HOUR": .hour, "MINUTE": .minute, "SECOND": .second][u.uppercased()] ?? .day
            var n = Fmt.calendar.dateComponents([comp], from: d1, to: d2).value(for: comp) ?? 0
            if u.uppercased() == "QUARTER" { n /= 3 }
            return .number(Double(n))
        case "EOMONTH":
            guard let t = try sub(args[0]).number else { return .blank }
            let n = Int(try sub(args[1]).number ?? 0)
            let cal = Fmt.calendar
            let start = cal.date(from: cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: t)))!
            let next = cal.date(byAdding: .month, value: n + 1, to: start)!
            return .date(cal.date(byAdding: .day, value: -1, to: next)!)
        case "DATE":
            guard let y = try sub(args[0]).number, let mo = try sub(args[1]).number, let dd = try sub(args[2]).number,
                  let d = Fmt.calendar.date(from: DateComponents(year: Int(y), month: Int(mo), day: Int(dd))) else { return .blank }
            return .date(d)
        case "TODAY":
            return .date(Fmt.calendar.startOfDay(for: Date()))
        case "FORMAT":
            let v = try sub(args[0])
            let pattern = try sub(args[1]).string
            if case .date(let d) = v {
                let df = DateFormatter()
                df.timeZone = TimeZone(identifier: "UTC")
                df.locale = Locale(identifier: Loc.isEnglish ? "en_US" : "fr_FR")
                df.dateFormat = pattern
                return .text(df.string(from: d))
            }
            guard let n = v.number else { return .text(v.string) }
            let nf = NumberFormatter()
            nf.locale = Locale(identifier: Loc.isEnglish ? "en_US" : "fr_FR")
            nf.positiveFormat = pattern
            nf.negativeFormat = "-" + pattern
            return .text(nf.string(from: NSNumber(value: n)) ?? Fmt.plain(n))
        case "CONCATENATE":
            return .text(try sub(args[0]).string + sub(args[1]).string)
        case "INT":
            return try sub(args[0]).number.map { .number(($0).rounded(.down)) } ?? .blank
        case "MOD":
            guard let a = try sub(args[0]).number, let b = try sub(args[1]).number, b != 0 else { return .blank }
            return .number(a - b * (a / b).rounded(.down))
        case "POWER":
            guard let a = try sub(args[0]).number, let b = try sub(args[1]).number else { return .blank }
            return .number(pow(a, b))
        case "SQRT":
            guard let a = try sub(args[0]).number, a >= 0 else { return .blank }
            return .number(a.squareRoot())
        case "VALUE":
            let v = try sub(args[0])
            return (v.number ?? Importer.parseNumber(v.string)).map { .number($0) } ?? .blank
        case "CONTAINSSTRING":
            return .bool(try sub(args[0]).string.range(of: try sub(args[1]).string, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        case "UNICHAR":
            guard let n = try sub(args[0]).number, let u = UnicodeScalar(UInt32(max(0, n))) else { return .blank }
            return .text(String(Character(u)))
        case "IFERROR":
            do {
                let v = try sub(args[0])
                if let d = v.number, !d.isFinite { return try sub(args[1]) }
                return v
            } catch {
                return try sub(args[1])
            }
        case "ISEMPTY":
            return .bool(try tableRows(args[0], home: home, rows: rows, filters: filters, row: row, depth: depth).rows.isEmpty)
        case "WEEKDAY":
            let v = try sub(args[0])
            let d: Date
            if case .date(let x) = v { d = x } else if let n = v.number { d = Date(timeIntervalSince1970: n) } else { return .blank }
            let sundayFirst = Fmt.calendar.component(.weekday, from: d)   // 1 = Sunday
            let kind = args.count > 1 ? Int(try sub(args[1]).number ?? 1) : 1
            switch kind {
            case 2: return .number(Double((sundayFirst + 5) % 7 + 1))   // Monday = 1
            case 3: return .number(Double((sundayFirst + 5) % 7))       // Monday = 0
            default: return .number(Double(sundayFirst))
            }
        case "DISTINCTCOUNTNOBLANK": return try aggregate(.distinctCount)
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

    /// Group labels that match a value (booleans match the spellings importers produce).
    static func labels(for v: MValue) -> Set<String> {
        switch v {
        case .number(let d): [GroupKey.of(.number(d), nil).label]
        case .text(let s): [s]
        case .bool(let b): b ? ["VRAI", "TRUE", "True", "true", "1"] : ["FAUX", "FALSE", "False", "false", "0"]
        case .blank: [GroupKey.blankLabel]
        case .date(let d): [GroupKey.of(.date(d), nil).label]
        }
    }

    private func applyFilter(_ a: Expr, to current: [FilterSpec], home: String, rows: [Int],
                             filters: [FilterSpec], row: RowContext?, depth: Int) throws -> [FilterSpec] {
        if let fr = MeasureCompiler.booleanFilterColumn(a, home: home, model), let t = model.table(fr.table) {
            // Boolean expression on one column: keep the rows of its table where it is true.
            let keep = try Set(t.rows.indices.filter { r in
                try eval(a, home: home, rows: rows, filters: filters, row: RowContext(table: t.name, row: r, baseRows: []), depth: depth + 1).truthy
            })
            return current.filter { $0.field.columnKey != fr.columnKey } + [FilterSpec(field: fr, allowed: [], rowSet: keep)]
        }
        switch a {
        case .binary("=", let lhs, let rhs):
            let fr = try column(lhs, home: home)
            let v = try eval(rhs, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            return current.filter { $0.field.columnKey != fr.columnKey } + [FilterSpec(field: fr, allowed: Self.labels(for: v))]
        case .call("__IN", let k) where k.count >= 1:
            let fr = try column(k[0], home: home)
            var labels = Set<String>()
            for x in k.dropFirst() { labels.formUnion(Self.labels(for: try eval(x, home: home, rows: rows, filters: filters, row: row, depth: depth + 1))) }
            return current.filter { $0.field.columnKey != fr.columnKey } + [FilterSpec(field: fr, allowed: labels)]
        case .binary(let op, let lhs, let rhs) where ["<>", "<", "<=", ">", ">="].contains(op):
            // Comparison on a column: keep the rows of its table that satisfy it (replaces filters on that column).
            let fr = try column(lhs, home: home)
            let v = try eval(rhs, home: home, rows: rows, filters: filters, row: row, depth: depth + 1)
            guard let t = model.table(fr.table), let ci = t.columnIndex(fr.column) else { return current }
            let keep = Set(t.rows.indices.filter { compare(MValue(t.rows[$0][ci]), v, op) })
            return current.filter { $0.field.columnKey != fr.columnKey }
                + [FilterSpec(field: FieldRef(table: fr.table, column: fr.column), allowed: [], rowSet: keep)]
        case .call(let g, _) where MeasureCompiler.tableFunctions.contains(g),
             .table(let g) where tableVar(g) != nil:
            let t = try tableRows(a, home: home, rows: rows, filters: filters, row: row, depth: depth)
            let base = t.removesFilters ? current.filter { $0.field.table != t.table } : current
            if let sources = t.sources {
                return base + [FilterSpec(field: FieldRef(table: t.table, column: ""), allowed: [],
                                          rowSet: Set(t.rows.flatMap { sources[$0] ?? [] }))]
            }
            if let groups = t.groups {
                // Distinct-value tables filter on the values themselves.
                let labels = Set(t.rows.compactMap { t.transitions?[$0]?.first?.allowed.first })
                if let f = t.rows.first.flatMap({ t.transitions?[$0]?.first?.field }) {
                    _ = groups
                    return base.filter { $0.field.columnKey != f.columnKey } + [FilterSpec(field: f, allowed: labels.isEmpty ? [GroupKey.blankLabel + "\u{0}"] : labels)]
                }
                return base + [FilterSpec(field: FieldRef(table: t.table, column: ""), allowed: [], rowSet: [])]
            }
            return base + [FilterSpec(field: FieldRef(table: t.table, column: ""), allowed: [], rowSet: Set(t.rows))]
        case .call("KEEPFILTERS", let k) where k.count == 1:
            return current + (try applyFilter(k[0], to: [], home: home, rows: rows, filters: filters, row: row, depth: depth))
        case .call("ALLEXCEPT", let k):
            guard case .table(let t) = k.first else { return current }
            let tables = Set(model.reachable(from: t).map(\.table))
            let keep = Set(try k.dropFirst().map { try column($0, home: home).columnKey })
            return current.filter { !tables.contains($0.field.table) || keep.contains($0.field.columnKey) }
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
