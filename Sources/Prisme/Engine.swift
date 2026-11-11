import Foundation

// MARK: - Formatting

enum Fmt {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static var monthNames: [String] {
        Loc.isEnglish
            ? ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            : ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
    }

    static func day(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%02d/%02d/%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    /// Number without grouping, as typed in a cell.
    static func plain(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func number(_ d: Double) -> String {
        if d == d.rounded() { return d.formatted(.number.precision(.fractionLength(0))) }
        return d.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func compact(_ d: Double) -> String {
        if abs(d) < 1000 { return number(d) }
        return d.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func measure(_ d: Double, _ f: MeasureFormat, compact: Bool) -> String {
        switch f {
        case .auto: return compact ? self.compact(d) : number(d)
        case .integer: return compact ? self.compact(d.rounded()) : d.formatted(.number.precision(.fractionLength(0)))
        case .decimal: return compact && abs(d) >= 1000 ? self.compact(d) : d.formatted(.number.precision(.fractionLength(2)))
        case .percent: return d.formatted(.percent.precision(.fractionLength(0...1)))
        case .currency: return (compact && abs(d) >= 10_000 ? self.compact(d) : d.formatted(.number.precision(.fractionLength(2)))) + " €"
        }
    }

    static func cell(_ v: CellValue) -> String {
        switch v {
        case .empty: ""
        case .text(let s): s
        case .number(let d): number(d)
        case .date(let d): day(d)
        }
    }
}

// MARK: - Grouping keys

/// A category label plus how it sorts. Equality is by label only.
struct GroupKey: Hashable, Comparable {
    let label: String
    let sort: Double?

    static func == (a: GroupKey, b: GroupKey) -> Bool { a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(label) }

    static func < (a: GroupKey, b: GroupKey) -> Bool {
        switch (a.sort, b.sort) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    static var blankLabel: String { L("(Vide)") }

    static func of(_ v: CellValue, _ level: DateLevel?) -> GroupKey {
        switch v {
        case .empty: return GroupKey(label: blankLabel, sort: nil)
        case .text(let s): return GroupKey(label: s, sort: nil)
        case .number(let d): return GroupKey(label: Fmt.number(d), sort: d)
        case .date(let d):
            let c = Fmt.calendar.dateComponents([.year, .month, .day], from: d)
            let y = c.year ?? 0, m = c.month ?? 1
            switch level {
            case .year: return GroupKey(label: String(y), sort: Double(y))
            case .quarter:
                let q = (m - 1) / 3 + 1
                return GroupKey(label: L("T%@ %@", q, y), sort: Double(y * 10 + q))
            case .month: return GroupKey(label: "\(Fmt.monthNames[m - 1]) \(y)", sort: Double(y * 100 + m))
            case .day, nil: return GroupKey(label: Fmt.day(d), sort: d.timeIntervalSince1970)
            }
        }
    }
}

// MARK: - Query engine

struct FilterSpec {
    var field: FieldRef
    var allowed: Set<String>
    /// True for the implicit filters of a chart category / table row (removed by ALLSELECTED).
    var isGroup = false
    /// Keep values (numbers, or dates as timestamps) within this range — used by time intelligence.
    var range: ClosedRange<Double>? = nil
    /// Keep only these rows of `field.table` — used by FILTER, comparisons and context transition.
    var rowSet: Set<Int>? = nil

    init(field: FieldRef, allowed: Set<String>, isGroup: Bool = false, range: ClosedRange<Double>? = nil, rowSet: Set<Int>? = nil) {
        self.field = field
        self.allowed = allowed
        self.isGroup = isGroup
        self.range = range
        self.rowSet = rowSet
    }

    var isActive: Bool { !allowed.isEmpty || range != nil || rowSet != nil }
}

struct ChartPoint: Identifiable {
    let id: Int
    let category: String
    let series: String
    let value: Double
}

struct ChartData {
    var format: MeasureFormat = .auto
    var valueTitle = ""
    var categoryTitle = ""
    var points: [ChartPoint] = []
    var categories: [String] = []
    var series: [String] = []
    var message: String?
    var truncated = false
}

struct TableData {
    var headers: [String] = []
    var numeric: [Bool] = []
    var rows: [[String]] = []
    /// Same cells as `rows`, with unformatted numbers (for CSV export).
    var raw: [[String]] = []
    var rowKeys: [String] = []
    var totals: [String]?
    var message: String?
    var totalRowCount = 0
    /// Value field behind each column (nil for grouping columns), for conditional formatting.
    var valueIDs: [UUID?] = []
}

struct Acc {
    var sum = 0.0, count = 0, numCount = 0
    var min = Double.infinity, max = -Double.infinity
    var distinct: Set<String>?

    init(distinct: Bool) { self.distinct = distinct ? [] : nil }

    mutating func add(_ v: CellValue) {
        if v.isEmpty { return }
        count += 1
        if let d = v.number {
            sum += d; numCount += 1
            if d < min { min = d }
            if d > max { max = d }
        }
        if distinct != nil { distinct!.insert(GroupKey.of(v, nil).label) }
    }

    func result(_ a: Aggregation) -> Double? {
        switch a {
        case .sum: numCount > 0 ? sum : nil
        case .average: numCount > 0 ? sum / Double(numCount) : nil
        case .min: numCount > 0 ? min : nil
        case .max: numCount > 0 ? max : nil
        case .count: Double(count)
        case .distinctCount: Double(distinct?.count ?? 0)
        }
    }
}

// MARK: - Data model (tables + relationships)

extension CellValue {
    /// Normalized key used to match rows across a relationship (case-insensitive).
    var joinKey: String {
        switch self {
        case .empty: ""
        case .text(let s): s.trimmingCharacters(in: .whitespaces).lowercased()
        case .number(let d): Fmt.plain(d)
        case .date(let d): Fmt.day(d)
        }
    }
}

struct DataModel {
    var tables: [DataTable]
    var relationships: [Relationship]
    var measures: [Measure] = []

    func measure(for f: FieldRef) -> Measure? {
        measures.first { $0.table == f.table && $0.name == f.column }
    }

    func table(_ name: String?) -> DataTable? {
        guard let name else { return nil }
        return tables.first { $0.name == name }
    }

    func column(_ f: FieldRef) -> DataColumn? {
        guard let t = table(f.table), let i = t.columnIndex(f.column) else { return nil }
        return t.columns[i]
    }

    /// Active many→one relationships leaving a table.
    func outgoing(_ t: String) -> [Relationship] {
        relationships.filter { $0.isActive && $0.fromTable == t && $0.toTable != t }
    }

    /// Tables reachable from `start` by following many→one relationships, in breadth-first order.
    func reachable(from start: String) -> [(table: String, via: Relationship?)] {
        var seen: Set<String> = [start]
        var order: [(String, Relationship?)] = [(start, nil)]
        var i = 0
        while i < order.count {
            for r in outgoing(order[i].0) where !seen.contains(r.toTable) {
                seen.insert(r.toTable)
                order.append((r.toTable, r))
            }
            i += 1
        }
        return order
    }

    /// Whether two tables are connected by any chain of relationships (ignoring direction).
    func connected(_ a: String, _ b: String) -> Bool {
        var seen: Set<String> = [a]
        var queue = [a]
        while let t = queue.popLast() {
            if t == b { return true }
            for r in relationships where r.isActive && r.involves(t) {
                let other = r.fromTable == t ? r.toTable : r.fromTable
                if seen.insert(other).inserted { queue.append(other) }
            }
        }
        return false
    }

    /// True when every non-empty value of the column is unique (it can be the "one" side).
    func isUnique(table: String, column: String) -> Bool {
        guard let t = self.table(table), let i = t.columnIndex(column) else { return false }
        var seen = Set<String>()
        for r in t.rows {
            let k = r[i].joinKey
            if k.isEmpty { continue }
            if !seen.insert(k).inserted { return false }
        }
        return !seen.isEmpty
    }
}

/// Rows of a base ("fact") table, with fields of related tables resolved through relationships.
struct QueryContext {
    let base: DataTable
    private let model: DataModel
    /// For each related table: base row index → row index in that table (nil when unmatched).
    private var maps: [String: [Int?]] = [:]

    init(base: DataTable, model: DataModel) {
        self.base = base
        self.model = model
        let n = base.rows.count
        for (name, via) in model.reachable(from: base.name) {
            guard let r = via, let from = model.table(r.fromTable), let to = model.table(name),
                  let fc = from.columnIndex(r.fromColumn), let tc = to.columnIndex(r.toColumn) else { continue }
            var lookup: [String: Int] = [:]
            for (i, row) in to.rows.enumerated() {
                let k = row[tc].joinKey
                if !k.isEmpty && lookup[k] == nil { lookup[k] = i }
            }
            let parent: [Int?]? = r.fromTable == base.name ? nil : maps[r.fromTable]
            if r.fromTable != base.name && parent == nil { continue }
            let fromRows = from.rows
            var map = [Int?](repeating: nil, count: n)
            for b in 0..<n {
                let fr: Int? = parent == nil ? b : parent![b]
                guard let fr else { continue }
                map[b] = lookup[fromRows[fr][fc].joinKey]
            }
            maps[name] = map
        }
    }

    func reaches(_ table: String) -> Bool { table == base.name || maps[table] != nil }

    /// Distinct rows of `table` related to the given base rows (the base rows themselves for the base table).
    func relatedRows(_ table: String, _ rows: [Int]) -> [Int]? {
        if table == base.name { return rows }
        guard let map = maps[table] else { return nil }
        var seen = Set<Int>()
        var out: [Int] = []
        for r in rows { if let t = map[r], seen.insert(t).inserted { out.append(t) } }
        return out
    }

    /// Values of a column over the given base rows (each related row counted once).
    func values(_ f: FieldRef, _ rows: [Int]) -> [CellValue]? {
        guard let t = model.table(f.table), let i = t.columnIndex(f.column), let related = relatedRows(f.table, rows) else { return nil }
        let tr = t.rows
        return related.map { tr[$0][i] }
    }

    /// Returns a function giving the field's value for a base row, or nil if the field is out of reach.
    func accessor(_ f: FieldRef) -> ((Int) -> CellValue)? {
        if f.table == base.name {
            guard let i = base.columnIndex(f.column) else { return nil }
            let rows = base.rows
            return { rows[$0][i] }
        }
        guard let map = maps[f.table], let t = model.table(f.table), let i = t.columnIndex(f.column) else { return nil }
        let rows = t.rows
        return { r in map[r].map { rows[$0][i] } ?? .empty }
    }

    /// Row of `table` related to a base row.
    func relatedRow(_ table: String, _ b: Int) -> Int? {
        if table == base.name { return b }
        return maps[table]?[b]
    }

    /// Indices of base rows that pass every applicable filter. Filters on unreachable tables are ignored.
    func rowIndices(_ filters: [FilterSpec]) -> [Int] {
        var tests: [(Int) -> Bool] = []
        for f in filters where f.isActive && reaches(f.field.table) {
            if let set = f.rowSet {
                let t = f.field.table
                tests.append { b in relatedRow(t, b).map(set.contains) ?? false }
            } else if let range = f.range {
                guard let get = accessor(f.field) else { continue }
                tests.append { b in
                    let v = get(b)
                    guard let x = v.number ?? v.date?.timeIntervalSince1970 else { return false }
                    return range.contains(x)
                }
            } else {
                guard let get = accessor(f.field) else { continue }
                let level = f.field.dateLevel, allowed = f.allowed
                tests.append { b in allowed.contains(GroupKey.of(get(b), level).label) }
            }
        }
        let all = Array(base.rows.indices)
        if tests.isEmpty { return all }
        return all.filter { b in tests.allSatisfy { $0(b) } }
    }
}

enum Engine {
    static func table(named name: String?, in tables: [DataTable]) -> DataTable? {
        guard let name else { return nil }
        return tables.first { $0.name == name }
    }

    /// Picks the table to iterate over: one from which every used table can be reached
    /// (preferably one of the used tables, i.e. the fact table of a star schema).
    static func context(for fields: [FieldRef], _ m: DataModel) -> QueryContext? {
        var used: [String] = []
        for f in fields where !used.contains(f.table) && m.table(f.table) != nil { used.append(f.table) }
        guard let first = used.first else { return nil }
        let need = Set(used)
        func reach(_ t: String) -> Set<String> { Set(m.reachable(from: t).map(\.table)) }
        if let b = used.first(where: { reach($0).isSuperset(of: need) }) {
            return QueryContext(base: m.table(b)!, model: m)
        }
        let outside = m.tables.map(\.name).filter { !need.contains($0) && reach($0).isSuperset(of: need) }
        if let b = outside.min(by: { reach($0).count < reach($1).count }) {
            return QueryContext(base: m.table(b)!, model: m)
        }
        // No table reaches all fields: use the first table; unreachable fields are ignored.
        return QueryContext(base: m.table(first)!, model: m)
    }

    /// Fields that drive the query: measures are replaced by the columns and tables they use.
    static func queryFields(_ v: Visual, _ m: DataModel) -> [FieldRef] {
        var out = v.axis + [v.legend].compactMap { $0 }
        for vf in v.values {
            if vf.measure {
                if let me = m.measure(for: vf.field) { out += MeasureCompiler.dependencies(me, m) }
            } else {
                out.append(vf.field)
            }
        }
        return out
    }

    /// Fields of a visual that cannot be combined with the others (no relationship path).
    static func unreachableFields(_ v: Visual, _ m: DataModel) -> Set<String> {
        guard let ctx = context(for: queryFields(v, m), m) else { return [] }
        var out = Set((v.axis + [v.legend].compactMap { $0 }).filter { !ctx.reaches($0.table) }.map(\.columnKey))
        for vf in v.values {
            let deps = vf.measure ? (m.measure(for: vf.field).map { MeasureCompiler.dependencies($0, m) } ?? []) : [vf.field]
            if deps.contains(where: { !ctx.reaches($0.table) }) { out.insert(vf.field.columnKey) }
        }
        return out
    }

    // MARK: Values (implicit aggregations and measures)

    /// Computes a value field for a set of base rows; `filters` is the full filter context (for CALCULATE).
    typealias ValueFn = (_ rows: [Int], _ filters: [FilterSpec]) -> Double?

    static func valueFunction(_ vf: ValueField, _ ctx: QueryContext, _ evaluator: MeasureEvaluator) -> ValueFn? {
        if vf.measure {
            guard let me = evaluator.model.measure(for: vf.field) else { return nil }
            return { rows, filters in evaluator.evaluate(me, rows: rows, filters: filters) }
        }
        guard ctx.reaches(vf.field.table), ctx.accessor(vf.field) != nil else { return nil }
        let agg = vf.aggregation
        return { rows, _ in
            var acc = Acc(distinct: agg == .distinctCount)
            ctx.values(vf.field, rows)?.forEach { acc.add($0) }
            return acc.result(agg)
        }
    }

    static func format(_ d: Double?, _ vf: ValueField, _ m: DataModel, compact: Bool = false,
                       override: MeasureFormat = .auto) -> String {
        guard let d else { return "" }
        let fmt = override != .auto ? override : (vf.measure ? (m.measure(for: vf.field)?.format ?? .auto) : .auto)
        return Fmt.measure(d, fmt, compact: compact)
    }

    /// Number format of a chart's values: the visual's setting, else the first measure's format.
    static func valueFormat(_ v: Visual, _ m: DataModel) -> MeasureFormat {
        if v.fmt.valueFormat != .auto { return v.fmt.valueFormat }
        if let vf = v.values.first, vf.measure { return m.measure(for: vf.field)?.format ?? .auto }
        return .auto
    }

    // MARK: Charts

    static func chartData(_ v: Visual, _ m: DataModel, _ filters: [FilterSpec]) -> ChartData {
        guard let ctx = context(for: queryFields(v, m), m) else {
            return ChartData(message: L("Glissez des champs depuis le volet Données"))
        }
        let evaluator = MeasureEvaluator(ctx: ctx, model: m)
        let axisLabel = v.type.isPie ? L("Légende") : L("Axe")
        let filters = filters + v.drillFilters
        guard let ax = v.axisField, let axisValue = ctx.accessor(ax) else {
            return ChartData(message: L("Ajoutez un champ dans « %@ »", axisLabel))
        }
        var vals = v.values.compactMap { vf in valueFunction(vf, ctx, evaluator).map { (vf, $0) } }
        guard !vals.isEmpty else { return ChartData(message: L("Ajoutez un champ dans « Valeurs »")) }

        var legendField: FieldRef?
        var legendValue: ((Int) -> CellValue)?
        if v.type.isCartesian, let l = v.legend, let a = ctx.accessor(l) {
            legendField = l
            legendValue = a
            vals = [vals[0]]
        }
        if v.type.isPie { vals = [vals[0]] }

        struct Key: Hashable { let cat: GroupKey; let ser: GroupKey? }
        var groups: [Key: [Int]] = [:]
        for r in ctx.rowIndices(filters) {
            let k = Key(cat: GroupKey.of(axisValue(r), ax.dateLevel), ser: legendValue.map { GroupKey.of($0(r), legendField?.dateLevel) })
            groups[k, default: []].append(r)
        }
        guard !groups.isEmpty else { return ChartData(message: L("Aucune donnée pour ces filtres")) }

        var results: [Key: [Double?]] = [:]
        for (k, rows) in groups {
            var ctxFilters = filters + [FilterSpec(field: ax, allowed: [k.cat.label], isGroup: true)]
            if let l = legendField, let s = k.ser { ctxFilters.append(FilterSpec(field: l, allowed: [s.label], isGroup: true)) }
            results[k] = vals.map { $0.1(rows, ctxFilters) }
        }

        var totals: [GroupKey: Double] = [:]
        for (k, r) in results { totals[k.cat, default: 0] += r[0] ?? 0 }
        var cats = Array(totals.keys)
        let isTrend = v.type == .line || v.type == .area
        var mode = v.fmt.sort
        if mode == .auto { mode = m.column(ax)?.type == .text && !isTrend ? .valueDesc : .categoryAsc }
        switch mode {
        case .valueDesc: cats.sort { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
        case .valueAsc: cats.sort { (totals[$0] ?? 0) < (totals[$1] ?? 0) }
        case .categoryDesc: cats.sort(by: >)
        default: cats.sort()
        }
        var data = ChartData()
        data.format = valueFormat(v, m)
        data.valueTitle = vals.map(\.0.displayName).joined(separator: ", ")
        data.categoryTitle = ax.displayName
        if v.fmt.topN > 0 && cats.count > v.fmt.topN { cats = Array(cats.prefix(v.fmt.topN)) }
        let limit = v.type.isPie ? 30 : (isTrend || v.type == .scatter || v.type == .map ? 2000 : 100)
        if cats.count > limit { cats = Array(cats.prefix(limit)); data.truncated = true }

        let seriesKeys: [GroupKey] = legendValue != nil
            ? Array(Set(groups.keys.compactMap(\.ser))).sorted()
            : vals.map { GroupKey(label: $0.0.displayName, sort: nil) }
        var id = 0
        for c in cats {
            if legendValue != nil {
                for s in seriesKeys {
                    guard let r = results[Key(cat: c, ser: s)], let value = r[0] else { continue }
                    data.points.append(ChartPoint(id: id, category: c.label, series: s.label, value: value)); id += 1
                }
            } else if let r = results[Key(cat: c, ser: nil)] {
                for (j, (vf, _)) in vals.enumerated() {
                    guard let value = r[j] else { continue }
                    if v.type.isPie && value <= 0 { continue }
                    data.points.append(ChartPoint(id: id, category: c.label, series: vf.displayName, value: value)); id += 1
                }
            }
        }
        data.categories = cats.map(\.label).filter { c in data.points.contains { $0.category == c } }
        data.series = seriesKeys.map(\.label)
        if data.points.isEmpty { data.message = L("Aucune donnée pour ces filtres") }
        return data
    }

    // MARK: Card

    static func cardValue(_ v: Visual, _ m: DataModel, _ filters: [FilterSpec]) -> (value: String, label: String)? {
        guard let vf = v.values.first else { return nil }
        let fields = vf.measure ? (m.measure(for: vf.field).map { MeasureCompiler.dependencies($0, m) } ?? []) : [vf.field]
        guard let ctx = context(for: fields.isEmpty ? [vf.field] : fields, m) else { return nil }
        guard let fn = valueFunction(vf, ctx, MeasureEvaluator(ctx: ctx, model: m)) else { return nil }
        let value = fn(ctx.rowIndices(filters), filters)
        return (value.map { format($0, vf, m, compact: true, override: v.fmt.valueFormat) } ?? L("(Vide)"), vf.displayName)
    }

    // MARK: Table

    static func tableData(_ v: Visual, _ m: DataModel, _ filters: [FilterSpec], limit: Int = 1000) -> TableData {
        guard let ctx = context(for: queryFields(v, m), m) else {
            return TableData(message: L("Glissez des champs depuis le volet Données"))
        }
        let evaluator = MeasureEvaluator(ctx: ctx, model: m)
        let axes = v.axis.compactMap { f in ctx.accessor(f).map { (f, $0) } }
        let vals = v.values.compactMap { vf in valueFunction(vf, ctx, evaluator).map { (vf, $0) } }
        guard !axes.isEmpty || !vals.isEmpty else { return TableData(message: L("Ajoutez des champs au tableau")) }

        let all = ctx.rowIndices(filters)
        var groups: [[GroupKey]: [Int]] = [:]
        for r in all { groups[axes.map { GroupKey.of($0.1(r), $0.0.dateLevel) }, default: []].append(r) }

        var data = TableData()
        data.headers = axes.map { $0.0.displayName } + vals.map { $0.0.displayName }
        data.numeric = axes.map { _ in false } + vals.map { _ in true }
        data.valueIDs = axes.map { _ in nil } + vals.map { $0.0.id }
        let keys = groups.keys.sorted { a, b in
            for (x, y) in zip(a, b) where x != y { return x < y }
            return false
        }
        data.totalRowCount = keys.count
        var computed: [(key: [GroupKey], values: [Double?])] = keys.map { k in
            let ctxFilters = filters + zip(axes, k).map { FilterSpec(field: $0.0.0, allowed: [$0.1.label], isGroup: true) }
            let rows = groups[k]!
            return (k, vals.map { $0.1(rows, ctxFilters) })
        }
        if let col = v.fmt.tableSortColumn, col < axes.count + vals.count {
            computed.sort { a, b in
                if col < axes.count { return a.key[col] < b.key[col] }
                return (a.values[col - axes.count] ?? -.infinity) < (b.values[col - axes.count] ?? -.infinity)
            }
            if v.fmt.tableSortDescending { computed.reverse() }
        }
        if v.fmt.topN > 0 { computed = Array(computed.prefix(v.fmt.topN)) }
        let override = v.fmt.valueFormat
        for c in computed.prefix(limit) {
            data.rows.append(c.key.map(\.label) + zip(vals, c.values).map { format($0.1, $0.0.0, m, override: override) })
            data.raw.append(c.key.map(\.label) + c.values.map { $0.map(Fmt.plain) ?? "" })
            data.rowKeys.append(c.key.first?.label ?? "")
        }
        if !axes.isEmpty && !vals.isEmpty {
            data.totals = [L("Total")] + Array(repeating: "", count: axes.count - 1)
                + vals.map { format($0.1(all, filters), $0.0, m, override: override) }
        }
        if keys.isEmpty { data.message = L("Aucune donnée pour ces filtres") }
        return data
    }

    // MARK: Scalars (gauge, KPI)

    /// One value per value field, over all rows passing the filters.
    static func scalars(_ v: Visual, _ m: DataModel, _ filters: [FilterSpec]) -> [Double?] {
        var fields: [FieldRef] = []
        for vf in v.values {
            fields += vf.measure ? (m.measure(for: vf.field).map { MeasureCompiler.dependencies($0, m) } ?? []) : [vf.field]
        }
        guard let ctx = context(for: fields.isEmpty ? v.values.map(\.field) : fields, m) else { return v.values.map { _ in nil } }
        let ev = MeasureEvaluator(ctx: ctx, model: m)
        let rows = ctx.rowIndices(filters)
        return v.values.map { vf in valueFunction(vf, ctx, ev)?(rows, filters) }
    }

    // MARK: Matrix

    /// Rows × columns (legend field) cross-tab of the first value, with row and column totals.
    /// Without a column field, a matrix behaves like a table.
    static func matrixData(_ v: Visual, _ m: DataModel, _ filters: [FilterSpec], limit: Int = 500) -> TableData {
        guard let colField = v.legend else { return tableData(v, m, filters, limit: limit) }
        guard let ctx = context(for: queryFields(v, m), m) else {
            return TableData(message: L("Glissez des champs depuis le volet Données"))
        }
        let ev = MeasureEvaluator(ctx: ctx, model: m)
        let axes = v.axis.compactMap { f in ctx.accessor(f).map { (f, $0) } }
        guard let colValue = ctx.accessor(colField), let vf = v.values.first, let fn = valueFunction(vf, ctx, ev) else {
            return TableData(message: L("Ajoutez des champs dans « Lignes », « Colonnes » et « Valeurs »"))
        }
        let all = ctx.rowIndices(filters)
        var cells: [[GroupKey]: [GroupKey: [Int]]] = [:]
        var rowGroups: [[GroupKey]: [Int]] = [:]
        var colGroups: [GroupKey: [Int]] = [:]
        for r in all {
            let rk = axes.map { GroupKey.of($0.1(r), $0.0.dateLevel) }
            let ck = GroupKey.of(colValue(r), colField.dateLevel)
            cells[rk, default: [:]][ck, default: []].append(r)
            rowGroups[rk, default: []].append(r)
            colGroups[ck, default: []].append(r)
        }
        guard !all.isEmpty else { return TableData(message: L("Aucune donnée pour ces filtres")) }
        let cols = Array(colGroups.keys.sorted().prefix(60))
        let rowKeys = rowGroups.keys.sorted { a, b in
            for (x, y) in zip(a, b) where x != y { return x < y }
            return false
        }
        let override = v.fmt.valueFormat
        func rowFilters(_ rk: [GroupKey]) -> [FilterSpec] {
            zip(axes, rk).map { FilterSpec(field: $0.0.0, allowed: [$0.1.label], isGroup: true) }
        }
        func colFilter(_ ck: GroupKey) -> FilterSpec { FilterSpec(field: colField, allowed: [ck.label], isGroup: true) }
        func value(_ rows: [Int], _ extra: [FilterSpec]) -> Double? { fn(rows, filters + extra) }

        var data = TableData()
        data.headers = axes.map { $0.0.displayName } + cols.map(\.label) + [L("Total")]
        data.numeric = axes.map { _ in false } + cols.map { _ in true } + [true]
        data.valueIDs = axes.map { _ in nil } + cols.map { _ in vf.id } + [nil]
        data.totalRowCount = rowKeys.count
        for rk in rowKeys.prefix(limit) {
            let rf = rowFilters(rk)
            let vals = cols.map { ck in cells[rk]?[ck].flatMap { value($0, rf + [colFilter(ck)]) } } + [value(rowGroups[rk]!, rf)]
            data.rows.append(rk.map(\.label) + vals.map { format($0, vf, m, override: override) })
            data.raw.append(rk.map(\.label) + vals.map { $0.map(Fmt.plain) ?? "" })
            data.rowKeys.append(rk.first?.label ?? "")
        }
        if !axes.isEmpty {
            data.totals = [L("Total")] + Array(repeating: "", count: axes.count - 1)
                + cols.map { format(value(colGroups[$0]!, [colFilter($0)]), vf, m, override: override) }
                + [format(value(all, []), vf, m, override: override)]
        }
        return data
    }

    // MARK: Distinct values (slicers & filters)

    static func distinctValues(_ f: FieldRef, _ tables: [DataTable]) -> [String] {
        guard let t = table(named: f.table, in: tables), let i = t.columnIndex(f.column) else { return [] }
        var set = Set<GroupKey>()
        for r in t.rows { set.insert(GroupKey.of(r[i], f.dateLevel)) }
        return set.sorted().map(\.label)
    }
}
