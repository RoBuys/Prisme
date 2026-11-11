import SwiftUI

/// "Données" view: browse the rows of a table and change column types.
struct DataGridView: View {
    @Environment(AppState.self) private var state
    private let maxRows = 1000
    private let colWidth: CGFloat = 150

    var body: some View {
        if let t = Engine.table(named: state.dataTableName, in: state.tables) ?? state.tables.first {
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
                        Text(URL(fileURLWithPath: src.path).lastPathComponent + (src.sheet.map { " › \($0)" } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
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
        } else {
            VStack(spacing: 12) {
                Image(systemName: "tablecells").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text(L("Aucune table")).font(.title3.weight(.semibold))
                Button(L("Obtenir des données…")) { state.importWithPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .help(L("Cliquez pour changer le type de données"))
    }
}
