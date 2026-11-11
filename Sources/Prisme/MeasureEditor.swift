import SwiftUI

/// Sheet to create or edit a measure, with live validation and a preview of the result.
struct MeasureEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var draft: MeasureDraft
    @State private var error: String?

    private static let snippets: [(String, String, String)] = [
        ("SUM", "SUM(Table[Colonne])", "Somme d'une colonne"),
        ("AVERAGE", "AVERAGE(Table[Colonne])", "Moyenne"),
        ("MIN / MAX", "MAX(Table[Colonne])", "Minimum, maximum (ou de deux valeurs)"),
        ("COUNT", "COUNT(Table[Colonne])", "Nombre de valeurs non vides"),
        ("DISTINCTCOUNT", "DISTINCTCOUNT(Table[Colonne])", "Nombre de valeurs distinctes"),
        ("COUNTROWS", "COUNTROWS(Table)", "Nombre de lignes"),
        ("DIVIDE", "DIVIDE(a, b)", "Division sûre (vide si b = 0)"),
        ("CALCULATE", "CALCULATE([Mesure], Table[Colonne] = \"valeur\")", "Change le contexte de filtre"),
        ("ALL", "ALL(Table)", "Dans CALCULATE : ignore les filtres"),
        ("ALLSELECTED", "ALLSELECTED(Table)", "Dans CALCULATE : ignore la catégorie, garde les segments"),
        ("IF", "IF(condition, alors, sinon)", "Condition"),
        ("ROUND", "ROUND(x, 2)", "Arrondi"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == nil ? "Nouvelle mesure" : "Modifier la mesure").font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                TextField("Nom", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker("Table", selection: $draft.table) {
                    ForEach(state.tables) { Text($0.name).tag($0.name) }
                }
                .frame(width: 200)
                Picker("Format", selection: $draft.format) {
                    ForEach(MeasureFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 210)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft.expression)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    let preview = state.previewMeasure(draft)
                    HStack(spacing: 6) {
                        if preview.hasPrefix("⚠︎") {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(preview.dropFirst(2)).foregroundStyle(.secondary)
                        } else if !draft.expression.isEmpty {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Valeur sur toutes les données : ").foregroundStyle(.secondary)
                            Text(preview).fontWeight(.semibold)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(3)
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Insérer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldsMenu
                            ForEach(Self.snippets, id: \.0) { name, code, help in
                                Button { insert(code) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 230, height: 220)
            }
            Text("Syntaxe : Table[Colonne] ou 'Table avec espaces'[Colonne], [Mesure] pour une autre mesure. Les arguments se séparent par « , » ou « ; » et les décimales s'écrivent avec un point.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack {
                if let id = draft.id, let m = state.measures.first(where: { $0.id == id }) {
                    Button("Supprimer", role: .destructive) { state.deleteMeasure(m); dismiss() }
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if let e = state.saveMeasure(draft) { error = e } else { dismiss() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private var fieldsMenu: some View {
        Menu("Champ ou mesure…") {
            ForEach(state.tables) { t in
                Menu(t.name) {
                    ForEach(t.columns) { c in
                        Button(c.name) { insert(reference(t.name, c.name)) }
                    }
                    let ms = state.measures.filter { $0.table == t.name && $0.id != draft.id }
                    if !ms.isEmpty {
                        Divider()
                        ForEach(ms) { m in Button("ƒ " + m.name) { insert("[\(m.name)]") } }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func reference(_ table: String, _ column: String) -> String {
        let simple = table.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return (simple ? table : "'\(table)'") + "[\(column)]"
    }

    private func insert(_ code: String) {
        if !draft.expression.isEmpty && !draft.expression.hasSuffix(" ") && !draft.expression.hasSuffix("(") {
            draft.expression += " "
        }
        draft.expression += code
        error = nil
    }
}
