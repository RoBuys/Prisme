import SwiftUI

/// One applied step of a table's transformation recipe (Power Query-like). Steps are replayed, in order,
/// on the table's base data whenever a step changes or the source is refreshed.
struct TransformStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case renameColumn, removeColumn, changeType, filterRows, replaceValues, splitColumn, trim, fillDown
        case removeDuplicates, removeBlankRows, keepTopRows, appendTable, addIndex
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
                .disabled(needsColumn && step.column.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var needsColumn: Bool {
        ![.removeDuplicates, .removeBlankRows, .keepTopRows, .appendTable, .addIndex].contains(step.kind)
    }

    private var title: String {
        switch step.kind {
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
