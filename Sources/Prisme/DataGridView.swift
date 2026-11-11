import SwiftUI

/// "Données" view: browse the rows of a table, change column types and add transformation steps.
struct DataGridView: View {
    @Environment(AppState.self) private var state
    private let maxRows = 1000
    private let colWidth: CGFloat = 150

    var body: some View {
        if let t = Engine.table(named: state.dataTableName, in: state.tables) ?? state.tables.first {
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker(L("Table"), selection: Binding(get: { t.name }, set: { state.dataTableName = $0 })) {
                        ForEach(state.tables) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Text(L("%@ lignes · %@ colonnes", t.rows.count.formatted(), t.columns.count))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let src = t.source {
                        Text(src.displayName)
                            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    transformMenu(t)
                    if t.rows.count > maxRows {
                        Text(L("Affichage des %@ premières lignes", maxRows)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(0..<min(t.rows.count, maxRows), id: \.self) { r in
                                HStack(spacing: 0) {
                                    Text("\(r + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                                        .frame(width: 50, alignment: .trailing).padding(.trailing, 8)
                                    ForEach(t.columns.indices, id: \.self) { c in
                                        Text(Fmt.cell(t.rows[r][c]))
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .frame(width: colWidth - 12, alignment: t.columns[c].type == .number ? .trailing : .leading)
                                            .padding(.horizontal, 6)
                                    }
                                }
                                .frame(height: 24)
                                .background(r % 2 == 1 ? Color.primary.opacity(0.03) : .clear)
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: 58)
                                ForEach(t.columns) { col in header(t, col) }
                            }
                            .frame(height: 30)
                            .background(.bar)
                            .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
            }
            Divider()
            StepsPane(table: t).frame(width: 240)
            }
            .sheet(item: Binding(get: { state.stepDraft }, set: { state.stepDraft = $0 })) { d in
                if let table = Engine.table(named: d.table, in: state.tables) {
                    StepEditor(step: d.step, table: table).environment(state)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "tablecells").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text(L("Aucune table")).font(.title3.weight(.semibold))
                Button(L("Obtenir des données…")) { state.importWithPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func step(_ kind: TransformStep.Kind, _ t: DataTable, column: String = "", text: String = "") {
        state.stepDraft = StepDraft(step: TransformStep(kind: kind, column: column.isEmpty ? (t.columns.first { $0.expression == nil }?.name ?? "") : column,
                                                        text: text), table: t.name)
    }

    private func transformMenu(_ t: DataTable) -> some View {
        Menu {
            Button(L("Filtrer les lignes…")) { step(.filterRows, t) }
            Button(L("Remplacer les valeurs…")) { step(.replaceValues, t) }
            Button(L("Fractionner une colonne…")) { step(.splitColumn, t, text: ",") }
            Divider()
            Button(L("Supprimer les doublons")) { state.addStep(TransformStep(kind: .removeDuplicates), to: t.name) }
            Button(L("Supprimer les lignes vides")) { state.addStep(TransformStep(kind: .removeBlankRows), to: t.name) }
            Button(L("Conserver les premières lignes…")) { step(.keepTopRows, t) }
            Button(L("Ajouter les lignes d'une autre table…")) {
                state.stepDraft = StepDraft(step: TransformStep(kind: .appendTable, text: state.tables.first { $0.name != t.name }?.name ?? ""), table: t.name)
            }
            .disabled(state.tables.count < 2)
            Button(L("Ajouter une colonne d'index…")) { step(.addIndex, t, text: "Index") }
            Divider()
            Button(L("Fusionner des requêtes…")) {
                let other = state.tables.first { $0.name != t.name }
                var s = TransformStep(kind: .mergeTable, column: t.columns.first?.name ?? "", text: other?.name ?? "")
                s.text2 = other?.columns.first { c in t.columns.contains { $0.name == c.name } }?.name ?? other?.columns.first?.name ?? ""
                if let shared = other?.columns.first(where: { c in t.columns.contains { $0.name == c.name } }) { s.column = shared.name }
                state.stepDraft = StepDraft(step: s, table: t.name)
            }
            .disabled(state.tables.count < 2)
            Button(L("Regrouper par…")) {
                var s = TransformStep(kind: .groupBy)
                s.aggregations = [TransformStep.StepAggregation(name: "", aggregation: .count, column: "")]
                state.stepDraft = StepDraft(step: s, table: t.name)
            }
            Button(L("Pivoter une colonne…")) { step(.pivotColumn, t) }
            Button(L("Dépivoter des colonnes…")) { state.stepDraft = StepDraft(step: TransformStep(kind: .unpivotColumns), table: t.name) }
            Button(L("Colonne conditionnelle…")) { step(.conditionalColumn, t, text: L("Personnalisée")) }
            Divider()
            Button(L("Nouvelle colonne calculée…")) { state.newColumn(in: t.name) }
        } label: {
            Label(L("Transformer"), systemImage: "wand.and.rays")
        }
        .fixedSize()
    }

    private func header(_ t: DataTable, _ col: DataColumn) -> some View {
        Menu {
            Section(L("Type de données")) {
                ForEach(ColumnType.allCases, id: \.self) { type in
                    Button {
                        state.convertColumn(table: t.name, column: col.name, to: type)
                    } label: {
                        if col.type == type { Label(type.label, systemImage: "checkmark") } else { Text(type.label) }
                    }
                }
            }
            if col.expression == nil {
                Section(L("Transformer")) {
                    Button(L("Renommer…")) { step(.renameColumn, t, column: col.name, text: col.name) }
                    Button(L("Filtrer…")) { step(.filterRows, t, column: col.name) }
                    Button(L("Remplacer les valeurs…")) { step(.replaceValues, t, column: col.name) }
                    Button(L("Fractionner…")) { step(.splitColumn, t, column: col.name, text: ",") }
                    Button(L("Supprimer les espaces")) { state.addStep(TransformStep(kind: .trim, column: col.name), to: t.name) }
                    Button(L("Remplir vers le bas")) { state.addStep(TransformStep(kind: .fillDown, column: col.name), to: t.name) }
                    Button(L("Supprimer la colonne"), role: .destructive) {
                        state.addStep(TransformStep(kind: .removeColumn, column: col.name), to: t.name)
                    }
                }
            } else {
                Button(L("Modifier la colonne calculée…")) { state.editColumn(table: t.name, column: col) }
                Button(L("Supprimer la colonne"), role: .destructive) { state.deleteColumn(table: t.name, column: col.name) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: col.type.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(col.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: colWidth - 12, alignment: .leading)
        .padding(.horizontal, 6)
        .help(L("Cliquez pour changer le type ou transformer la colonne"))
    }
}
