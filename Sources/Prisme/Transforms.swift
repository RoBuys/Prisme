import SwiftUI

/// One applied step of a table's transformation recipe (Power Query-like). Steps are replayed, in order,
/// on the table's base data whenever a step changes or the source is refreshed.
struct TransformStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case renameColumn, removeColumn, changeType, filterRows, replaceValues, splitColumn, trim, fillDown
        case removeDuplicates, removeBlankRows, keepTopRows, appendTable, addIndex
        case mergeTable, groupBy, pivotColumn, unpivotColumns, conditionalColumn
    }

    enum JoinKind: String, Codable, CaseIterable {
        case left, inner
        var label: String { self == .left ? L("Externe gauche (toutes les lignes)") : L("Interne (lignes correspondantes)") }
    }

    /// One aggregated output column of a "group by" step (empty column = count rows).
    struct StepAggregation: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var aggregation: Aggregation
        var column: String
    }

    enum Op: String, Codable, CaseIterable {
        case equals, notEquals, contains, notContains, startsWith, greater, greaterOrEqual, less, lessOrEqual, isBlank, notBlank

        var label: String {
            switch self {
            case .equals: L("est égal à")
            case .notEquals: L("est différent de")
            case .contains: L("contient")
            case .notContains: L("ne contient pas")
            case .startsWith: L("commence par")
            case .greater: L("est supérieur à")
            case .greaterOrEqual: L("est supérieur ou égal à")
            case .less: L("est inférieur à")
            case .lessOrEqual: L("est inférieur ou égal à")
            case .isBlank: L("est vide")
            case .notBlank: L("n'est pas vide")
            }
        }

        var needsValue: Bool { self != .isBlank && self != .notBlank }
    }

    var id = UUID()
    var kind: Kind
    var column = ""
    /// New name, value to compare / find, delimiter, or table to append, depending on `kind`.
    var text = ""
    var text2 = ""
    var op: Op = .equals
    var type: ColumnType = .text
    var count = 10
    /// Several columns: group-by keys, columns to unpivot, or columns brought by a merge.
    var columns: [String] = []
    var aggregations: [StepAggregation] = []
    var aggregation: Aggregation = .sum
    var joinKind: JoinKind = .left
    /// Conditional column: value when the condition holds (text3) or not (text4); "[Column]" uses a column's value.
    var text3 = ""
    var text4 = ""

    init(kind: Kind, column: String = "", text: String = "", text2: String = "", op: Op = .equals,
         type: ColumnType = .text, count: Int = 10) {
        self.kind = kind
        self.column = column
        self.text = text
        self.text2 = text2
        self.op = op
        self.type = type
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, column, text, text2, op, type, count, columns, aggregations, aggregation, joinKind, text3, text4
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        column = try c.decodeIfPresent(String.self, forKey: .column) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        text2 = try c.decodeIfPresent(String.self, forKey: .text2) ?? ""
        op = try c.decodeIfPresent(Op.self, forKey: .op) ?? .equals
        type = try c.decodeIfPresent(ColumnType.self, forKey: .type) ?? .text
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 10
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        aggregations = try c.decodeIfPresent([StepAggregation].self, forKey: .aggregations) ?? []
        aggregation = try c.decodeIfPresent(Aggregation.self, forKey: .aggregation) ?? .sum
        joinKind = try c.decodeIfPresent(JoinKind.self, forKey: .joinKind) ?? .left
        text3 = try c.decodeIfPresent(String.self, forKey: .text3) ?? ""
        text4 = try c.decodeIfPresent(String.self, forKey: .text4) ?? ""
    }

    var label: String {
        switch kind {
        case .renameColumn: L("Renommer « %@ » en « %@ »", column, text)
        case .removeColumn: L("Supprimer la colonne « %@ »", column)
        case .changeType: L("Type de « %@ » : %@", column, type.label)
        case .filterRows: op.needsValue ? L("Filtrer : %@ %@ « %@ »", column, op.label, text) : L("Filtrer : %@ %@", column, op.label)
        case .replaceValues: L("Remplacer « %@ » par « %@ » dans %@", text, text2, column)
        case .splitColumn: L("Fractionner « %@ » par « %@ »", column, text)
        case .trim: L("Supprimer les espaces de « %@ »", column)
        case .fillDown: L("Remplir vers le bas « %@ »", column)
        case .removeDuplicates: L("Supprimer les doublons")
        case .removeBlankRows: L("Supprimer les lignes vides")
        case .keepTopRows: L("Conserver les %@ premières lignes", count)
        case .appendTable: L("Ajouter les lignes de « %@ »", text)
        case .addIndex: L("Ajouter une colonne d'index « %@ »", text)
        case .mergeTable: L("Fusionner avec « %@ » (%@ = %@)", text, column, text2)
        case .groupBy: L("Regrouper par %@", columns.joined(separator: ", "))
        case .pivotColumn: L("Pivoter « %@ » (valeurs : %@)", column, text)
        case .unpivotColumns: L("Dépivoter %@", columns.joined(separator: ", "))
        case .conditionalColumn: L("Colonne conditionnelle « %@ »", text)
        }
    }

    var symbol: String {
        switch kind {
        case .renameColumn: "pencil"
        case .removeColumn: "minus.square"
        case .changeType: "textformat.123"
        case .filterRows: "line.3.horizontal.decrease"
        case .replaceValues: "arrow.left.arrow.right"
        case .splitColumn: "rectangle.split.2x1"
        case .trim: "scissors"
        case .fillDown: "arrow.down.to.line"
        case .removeDuplicates: "square.on.square"
        case .removeBlankRows: "rectangle.slash"
        case .keepTopRows: "list.number"
        case .appendTable: "plus.rectangle.on.rectangle"
        case .addIndex: "number"
        case .mergeTable: "arrow.triangle.merge"
        case .groupBy: "square.stack.3d.up"
        case .pivotColumn: "arrow.turn.right.up"
        case .unpivotColumns: "arrow.turn.down.right"
        case .conditionalColumn: "questionmark.diamond"
        }
    }
}

enum Transform {
    /// Applies the steps to base data. Returns the result and, per step, an error message (nil when it applied).
    static func apply(_ steps: [TransformStep], columns: [DataColumn], rows: [[CellValue]],
                      tables: [DataTable]) -> (columns: [DataColumn], rows: [[CellValue]], errors: [UUID: String]) {
        var cols = columns, data = rows
        var errors: [UUID: String] = [:]
        for s in steps {
            do { try apply(s, &cols, &data, tables) } catch { errors[s.id] = error.localizedDescription }
        }
        return (cols, data, errors)
    }

    private static func index(_ name: String, _ cols: [DataColumn]) throws -> Int {
        guard let i = cols.firstIndex(where: { $0.name == name }) else {
            throw MeasureError(message: L("Colonne introuvable : %@", name))
        }
        return i
    }

    private static func unique(_ name: String, _ cols: [DataColumn]) -> String {
        var n = name, k = 2
        while cols.contains(where: { $0.name == n }) { n = "\(name) (\(k))"; k += 1 }
        return n
    }

    private static func apply(_ s: TransformStep, _ cols: inout [DataColumn], _ rows: inout [[CellValue]], _ tables: [DataTable]) throws {
        switch s.kind {
        case .renameColumn:
            let i = try index(s.column, cols)
            let n = s.text.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { throw MeasureError(message: L("Donnez un nom à la colonne.")) }
            cols[i].name = cols.contains(where: { $0.name == n }) && n != s.column ? unique(n, cols) : n
        case .removeColumn:
            let i = try index(s.column, cols)
            cols.remove(at: i)
            for r in rows.indices { rows[r].remove(at: i) }
        case .changeType:
            let i = try index(s.column, cols)
            let converted = Importer.coerce(Importer.cellsToRaw(rows.map { $0[i] }), to: s.type)
            for r in rows.indices { rows[r][i] = converted[r] }
            cols[i].type = s.type
        case .filterRows:
            let i = try index(s.column, cols)
            let number = Importer.parseNumber(s.text)
            let date = Importer.dateFormatter(for: [s.text]).flatMap { $0.date(from: s.text.trimmingCharacters(in: .whitespaces)) }
            let needle = s.text.lowercased()
            rows = rows.filter { row in
                let v = row[i]
                let text = Fmt.cell(v).lowercased()
                func ordered() -> ComparisonResult? {
                    if let x = v.number, let n = number { return x < n ? .orderedAscending : (x > n ? .orderedDescending : .orderedSame) }
                    if let d = v.date, let t = date { return d < t ? .orderedAscending : (d > t ? .orderedDescending : .orderedSame) }
                    if v.isEmpty { return nil }
                    return text.localizedStandardCompare(needle)
                }
                switch s.op {
                case .isBlank: return v.isEmpty
                case .notBlank: return !v.isEmpty
                case .contains: return text.contains(needle)
                case .notContains: return !text.contains(needle)
                case .startsWith: return text.hasPrefix(needle)
                case .equals: return ordered() == .orderedSame
                case .notEquals: return ordered() != .orderedSame
                case .greater: return ordered() == .orderedDescending
                case .greaterOrEqual: return ordered().map { $0 != .orderedAscending } ?? false
                case .less: return ordered() == .orderedAscending
                case .lessOrEqual: return ordered().map { $0 != .orderedDescending } ?? false
                }
            }
        case .replaceValues:
            let i = try index(s.column, cols)
            let type = cols[i].type
            for r in rows.indices {
                let v = rows[r][i]
                if type == .text, case .text(let t) = v {
                    let n = s.text.isEmpty ? t : t.replacingOccurrences(of: s.text, with: s.text2)
                    rows[r][i] = n.isEmpty ? .empty : .text(n)
                } else if Fmt.cell(v) == s.text || (v.isEmpty && s.text.isEmpty) {
                    rows[r][i] = Importer.coerce([s.text2.isEmpty ? .empty : .text(s.text2)], to: type)[0]
                }
            }
        case .splitColumn:
            let i = try index(s.column, cols)
            guard !s.text.isEmpty else { throw MeasureError(message: L("Indiquez un séparateur.")) }
            let parts = rows.map { Fmt.cell($0[i]).components(separatedBy: s.text) }
            let n = min(20, parts.map(\.count).max() ?? 1)
            var newCols: [DataColumn] = []
            var newValues: [[CellValue]] = []
            for k in 0..<n {
                let raw: [RawCell] = parts.map { k < $0.count && !$0[k].trimmingCharacters(in: .whitespaces).isEmpty ? .text($0[k]) : .empty }
                let (type, values) = Importer.inferColumn(raw)
                newCols.append(DataColumn(name: "\(s.column).\(k + 1)", type: type))
                newValues.append(values)
            }
            cols.replaceSubrange(i...i, with: newCols)
            for r in rows.indices { rows[r].replaceSubrange(i...i, with: newValues.map { $0[r] }) }
        case .trim:
            let i = try index(s.column, cols)
            for r in rows.indices {
                if case .text(let t) = rows[r][i] {
                    let n = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    rows[r][i] = n.isEmpty ? .empty : .text(n)
                }
            }
        case .fillDown:
            let i = try index(s.column, cols)
            var last: CellValue = .empty
            for r in rows.indices {
                if rows[r][i].isEmpty { rows[r][i] = last } else { last = rows[r][i] }
            }
        case .removeDuplicates:
            var seen = Set<[CellValue]>()
            rows = rows.filter { seen.insert($0).inserted }
        case .removeBlankRows:
            rows = rows.filter { !$0.allSatisfy(\.isEmpty) }
        case .keepTopRows:
            rows = Array(rows.prefix(max(0, s.count)))
        case .appendTable:
            guard let other = tables.first(where: { $0.name == s.text }) else {
                throw MeasureError(message: L("Table introuvable : %@", s.text))
            }
            let mapping = cols.map { c in other.columnIndex(c.name) }
            for orow in other.rows {
                rows.append(cols.indices.map { k in
                    guard let oi = mapping[k] else { return .empty }
                    let v = orow[oi]
                    return Importer.coerce(Importer.cellsToRaw([v]), to: cols[k].type)[0]
                })
            }
        case .addIndex:
            let name = unique(s.text.isEmpty ? "Index" : s.text, cols)
            cols.append(DataColumn(name: name, type: .number))
            for r in rows.indices { rows[r].append(.number(Double(r + 1))) }
        case .mergeTable:
            guard let other = tables.first(where: { $0.name == s.text }) else { throw MeasureError(message: L("Table introuvable : %@", s.text)) }
            let k = try index(s.column, cols)
            guard let ok = other.columnIndex(s.text2) else { throw MeasureError(message: L("Colonne introuvable : %@", s.text2)) }
            let bring = (s.columns.isEmpty ? other.columns.map(\.name).filter { $0 != s.text2 } : s.columns)
                .compactMap { n in other.columnIndex(n).map { (n, $0) } }
            var lookup: [String: [Int]] = [:]
            for (i, r) in other.rows.enumerated() { lookup[r[ok].joinKey, default: []].append(i) }
            var out: [[CellValue]] = []
            for row in rows {
                let matches = lookup[row[k].joinKey] ?? []
                if matches.isEmpty {
                    if s.joinKind == .left { out.append(row + bring.map { _ in .empty }) }
                } else {
                    for m in matches { out.append(row + bring.map { other.rows[m][$0.1] }) }
                }
            }
            for (n, i) in bring {
                cols.append(DataColumn(name: unique("\(other.name).\(n)", cols), type: other.columns[i].type))
            }
            rows = out
        case .groupBy:
            let keys = try s.columns.map { try index($0, cols) }
            var aggs: [(TransformStep.StepAggregation, Int?)] = []
            for a in s.aggregations { aggs.append((a, a.column.isEmpty ? nil : try index(a.column, cols))) }
            var order: [[CellValue]] = []
            var groups: [[CellValue]: [Acc]] = [:]
            for r in rows {
                let key = keys.map { r[$0] }
                if groups[key] == nil {
                    order.append(key)
                    groups[key] = aggs.map { Acc(distinct: $0.0.aggregation == .distinctCount) }
                }
                for (j, (_, ci)) in aggs.enumerated() { groups[key]![j].add(ci.map { r[$0] } ?? .number(1)) }
            }
            var newCols = keys.map { cols[$0] }
            for (a, ci) in aggs {
                let auto = ci.map { L("%@ de %@", a.aggregation.label, cols[$0].name) } ?? L("Nombre de lignes")
                newCols.append(DataColumn(name: a.name.isEmpty ? auto : a.name, type: .number))
            }
            var grouped: [[CellValue]] = []
            for key in order {
                var row = key
                for (j, (a, ci)) in aggs.enumerated() {
                    let r = groups[key]![j].result(ci == nil ? .count : a.aggregation)
                    row.append(r.map { CellValue.number($0) } ?? .empty)
                }
                grouped.append(row)
            }
            rows = grouped
            cols = []
            for c in newCols { cols.append(DataColumn(name: unique(c.name, cols), type: c.type)) }
        case .pivotColumn:
            let p = try index(s.column, cols)
            let v = try index(s.text, cols)
            let keyIdx = cols.indices.filter { $0 != p && $0 != v }
            var pivots: [String] = []
            var order: [[CellValue]] = []
            var cells: [[CellValue]: [String: Acc]] = [:]
            for r in rows {
                let label = GroupKey.of(r[p], nil).label
                if !pivots.contains(label) { pivots.append(label) }
                let key = keyIdx.map { r[$0] }
                if cells[key] == nil { order.append(key); cells[key] = [:] }
                cells[key]![label, default: Acc(distinct: s.aggregation == .distinctCount)].add(r[v])
            }
            let keyCols = keyIdx.map { cols[$0] }
            cols = keyCols
            for label in pivots { cols.append(DataColumn(name: unique(label, cols), type: .number)) }
            rows = order.map { key in
                key + pivots.map { l in cells[key]![l]?.result(s.aggregation).map { CellValue.number($0) } ?? .empty }
            }
        case .unpivotColumns:
            let un = Set(try s.columns.map { try index($0, cols) })
            guard !un.isEmpty else { throw MeasureError(message: L("Choisissez au moins une colonne.")) }
            let keep = cols.indices.filter { !un.contains($0) }
            var out: [[CellValue]] = []
            var values: [CellValue] = []
            for r in rows {
                for c in cols.indices where un.contains(c) && !r[c].isEmpty {
                    out.append(keep.map { r[$0] } + [.text(cols[c].name)])
                    values.append(r[c])
                }
            }
            let (type, typed) = Importer.inferColumn(Importer.cellsToRaw(values))
            let attr = s.text.isEmpty ? L("Attribut") : s.text, val = s.text2.isEmpty ? L("Valeur") : s.text2
            let keepCols = keep.map { cols[$0] }
            cols = keepCols
            cols.append(DataColumn(name: unique(attr, cols), type: .text))
            cols.append(DataColumn(name: unique(val, cols), type: type))
            rows = zip(out, typed).map { $0 + [$1] }
        case .conditionalColumn:
            let i = try index(s.column, cols)
            let test = TransformStep(kind: .filterRows, column: s.column, text: s.text2, op: s.op)
            var probe = cols, kept: [[CellValue]] = rows.enumerated().map { [.number(Double($0.offset))] + $0.element }
            probe.insert(DataColumn(name: "\u{1}row", type: .number), at: 0)
            try apply(test, &probe, &kept, tables)
            let matching = Set(kept.compactMap { $0.first?.number.map(Int.init) })
            func output(_ spec: String, _ row: [CellValue]) -> RawCell {
                let t = spec.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("["), t.hasSuffix("]"), let ci = cols.firstIndex(where: { $0.name == String(t.dropFirst().dropLast()) }) {
                    return Importer.cellsToRaw([row[ci]])[0]
                }
                return t.isEmpty ? .empty : .text(t)
            }
            let raw = rows.enumerated().map { output(matching.contains($0.offset) ? s.text3 : s.text4, $0.element) }
            let (type, values) = Importer.inferColumn(raw)
            _ = i
            cols.append(DataColumn(name: unique(s.text.isEmpty ? L("Personnalisée") : s.text, cols), type: type))
            for r in rows.indices { rows[r].append(values[r]) }
        }
    }
}

// MARK: - State

extension AppState {
    /// Adds a step to a table's recipe and re-applies it.
    func addStep(_ step: TransformStep, to table: String) {
        guard let ti = tables.firstIndex(where: { $0.name == table }) else { return }
        if tables[ti].base.isEmpty {
            // Snapshot the data before the first step (calculated columns are recomputed afterwards).
            let keep = tables[ti].columns.indices.filter { tables[ti].columns[$0].expression == nil }
            var base = tables[ti]
            base.columns = keep.map { tables[ti].columns[$0] }
            base.rows = tables[ti].rows.map { row in keep.map { row[$0] } }
            base.steps = []
            base.base = []
            tables[ti].base = [base]
        }
        tables[ti].steps.append(step)
        reapplySteps(ti)
        if step.kind == .renameColumn { renameColumnReferences(table: table, from: step.column, to: step.text) }
        didChange()
    }

    func removeStep(_ id: UUID, from table: String) {
        guard let ti = tables.firstIndex(where: { $0.name == table }),
              let si = tables[ti].steps.firstIndex(where: { $0.id == id }) else { return }
        let step = tables[ti].steps.remove(at: si)
        reapplySteps(ti)
        if step.kind == .renameColumn { renameColumnReferences(table: table, from: step.text, to: step.column) }
        crossFilter = nil
        didChange()
    }

    /// Rebuilds a table from its base data and steps, then recomputes calculated columns.
    func reapplySteps(_ ti: Int) {
        guard let base = tables[ti].base.first else { return }
        let calculated = tables[ti].columns.filter { $0.expression != nil }
        let others = tables.filter { $0.name != tables[ti].name }
        let result = Transform.apply(tables[ti].steps, columns: base.columns, rows: base.rows, tables: others)
        let kept = calculated.filter { c in !result.columns.contains { $0.name == c.name } }
        tables[ti].columns = result.columns + kept
        tables[ti].rows = result.rows.map { $0 + Array(repeating: CellValue.empty, count: kept.count) }
        stepErrors[tables[ti].name] = result.errors
        recomputeCalculatedColumns()
    }
}

// MARK: - Views

/// "Applied steps" pane of the Data view.
struct StepsPane: View {
    let table: DataTable
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: L("Étapes appliquées"))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").frame(width: 16)
                        Text(table.source?.displayName ?? L("Source"))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    ForEach(table.steps) { s in
                        let err = state.stepErrors[table.name]?[s.id]
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: err == nil ? s.symbol : "exclamationmark.triangle.fill")
                                .foregroundStyle(err == nil ? Theme.accent : .orange).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.label).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                if let err { Text(err).font(.system(size: 10)).foregroundStyle(.orange) }
                            }
                            Spacer(minLength: 2)
                            Button { state.removeStep(s.id, from: table.name) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Supprimer l'étape"))
                        }
                        .padding(.vertical, 3)
                    }
                    if table.steps.isEmpty {
                        Text(L("Utilisez le menu Transformer ou l'en-tête d'une colonne pour ajouter des étapes. Elles sont rejouées à chaque actualisation."))
                            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.background)
    }
}

/// Small sheet to set up a step that needs parameters.
struct StepEditor: View {
    @State var step: TransformStep
    let table: DataTable
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Form {
                if needsColumn {
                    Picker(L("Colonne"), selection: $step.column) {
                        ForEach(table.columns.filter { $0.expression == nil }) { Text($0.name).tag($0.name) }
                    }
                }
                switch step.kind {
                case .renameColumn:
                    TextField(L("Nouveau nom"), text: $step.text)
                case .filterRows:
                    Picker(L("Condition"), selection: $step.op) {
                        ForEach(TransformStep.Op.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if step.op.needsValue { TextField(L("Valeur"), text: $step.text) }
                case .replaceValues:
                    TextField(L("Rechercher"), text: $step.text)
                    TextField(L("Remplacer par"), text: $step.text2)
                case .splitColumn:
                    TextField(L("Séparateur"), text: $step.text)
                case .keepTopRows:
                    Stepper(value: $step.count, in: 1...1_000_000) { Text(L("Nombre de lignes : %@", step.count)) }
                case .appendTable:
                    Picker(L("Table"), selection: $step.text) {
                        ForEach(state.tables.filter { $0.name != table.name }) { Text($0.name).tag($0.name) }
                    }
                case .addIndex:
                    TextField(L("Nom de la colonne"), text: $step.text)
                case .mergeTable:
                    Picker(L("Table à fusionner"), selection: $step.text) {
                        ForEach(state.tables.filter { $0.name != table.name }) { Text($0.name).tag($0.name) }
                    }
                    if let other = state.tables.first(where: { $0.name == step.text }) {
                        Picker(L("Colonne correspondante"), selection: $step.text2) {
                            ForEach(other.columns) { Text($0.name).tag($0.name) }
                        }
                        Picker(L("Type de jointure"), selection: $step.joinKind) {
                            ForEach(TransformStep.JoinKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        columnChecklist(L("Colonnes à ajouter (aucune = toutes)"), other.columns.map(\.name).filter { $0 != step.text2 })
                    }
                case .groupBy:
                    columnChecklist(L("Regrouper par"), sourceColumns)
                    ForEach($step.aggregations) { $a in
                        HStack {
                            Picker("", selection: $a.aggregation) {
                                ForEach(Aggregation.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                            Picker("", selection: $a.column) {
                                Text(L("(lignes)")).tag("")
                                ForEach(sourceColumns, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            TextField(L("Nom"), text: $a.name).frame(width: 110)
                            Button { step.aggregations.removeAll { $0.id == a.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    Button(L("Ajouter une agrégation")) {
                        step.aggregations.append(TransformStep.StepAggregation(name: "", aggregation: .sum,
                            column: table.columns.first { $0.type == .number && $0.expression == nil }?.name ?? ""))
                    }
                case .pivotColumn:
                    Picker(L("Colonne des valeurs"), selection: $step.text) {
                        ForEach(sourceColumns, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(L("Agrégation"), selection: $step.aggregation) {
                        ForEach(Aggregation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                case .unpivotColumns:
                    columnChecklist(L("Colonnes à dépivoter"), sourceColumns)
                    TextField(L("Nom de la colonne d'attribut"), text: $step.text, prompt: Text(L("Attribut")))
                    TextField(L("Nom de la colonne de valeur"), text: $step.text2, prompt: Text(L("Valeur")))
                case .conditionalColumn:
                    TextField(L("Nom de la colonne"), text: $step.text)
                    Picker(L("Condition"), selection: $step.op) {
                        ForEach(TransformStep.Op.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if step.op.needsValue { TextField(L("Valeur"), text: $step.text2) }
                    TextField(L("Alors"), text: $step.text3, prompt: Text(L("texte ou [Colonne]")))
                    TextField(L("Sinon"), text: $step.text4, prompt: Text(L("texte ou [Colonne]")))
                default:
                    EmptyView()
                }
            }
            HStack {
                Spacer()
                Button(L("Annuler"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Ajouter l'étape")) {
                    state.addStep(step, to: table.name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((needsColumn && step.column.isEmpty) || !isComplete)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var needsColumn: Bool {
        ![.removeDuplicates, .removeBlankRows, .keepTopRows, .appendTable, .addIndex, .groupBy, .unpivotColumns].contains(step.kind)
    }

    private var sourceColumns: [String] { table.columns.filter { $0.expression == nil }.map(\.name) }

    private func columnChecklist(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { n in
                        Toggle(n, isOn: Binding(get: { step.columns.contains(n) }, set: { on in
                            if on { step.columns.append(n) } else { step.columns.removeAll { $0 == n } }
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private var isComplete: Bool {
        switch step.kind {
        case .mergeTable: !step.text.isEmpty && !step.text2.isEmpty
        case .groupBy: !step.columns.isEmpty || !step.aggregations.isEmpty
        case .pivotColumn: !step.text.isEmpty && step.text != step.column
        case .unpivotColumns: !step.columns.isEmpty
        default: true
        }
    }

    private var title: String {
        switch step.kind {
        case .mergeTable: L("Fusionner des requêtes")
        case .groupBy: L("Regrouper par")
        case .pivotColumn: L("Pivoter une colonne")
        case .unpivotColumns: L("Dépivoter des colonnes")
        case .conditionalColumn: L("Colonne conditionnelle")
        case .renameColumn: L("Renommer la colonne")
        case .filterRows: L("Filtrer les lignes")
        case .replaceValues: L("Remplacer les valeurs")
        case .splitColumn: L("Fractionner la colonne")
        case .keepTopRows: L("Conserver les premières lignes")
        case .appendTable: L("Ajouter des lignes")
        case .addIndex: L("Ajouter une colonne d'index")
        default: L("Transformer")
        }
    }
}
