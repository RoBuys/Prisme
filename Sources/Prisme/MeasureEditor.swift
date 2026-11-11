import SwiftUI

/// Sheet to create or edit a measure, with live validation and a preview of the result.
struct MeasureEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var draft: MeasureDraft
    @State private var error: String?
    @State private var showQuick = false
    @State private var quickMeasure = ""
    @State private var quickDate = ""
    @State private var quickCategory = ""

    private static var snippets: [(String, String, String)] { [
        ("SUM", L("SUM(Table[Colonne])"), L("Somme d'une colonne")),
        ("AVERAGE", L("AVERAGE(Table[Colonne])"), L("Moyenne")),
        ("MIN / MAX", L("MAX(Table[Colonne])"), L("Minimum, maximum (ou de deux valeurs)")),
        ("COUNT", L("COUNT(Table[Colonne])"), L("Nombre de valeurs non vides")),
        ("DISTINCTCOUNT", L("DISTINCTCOUNT(Table[Colonne])"), L("Nombre de valeurs distinctes")),
        ("COUNTROWS", "COUNTROWS(Table)", L("Nombre de lignes")),
        ("DIVIDE", "DIVIDE(a, b)", L("Division sûre (vide si b = 0)")),
        ("CALCULATE", L("CALCULATE([Mesure], Table[Colonne] = \"valeur\")"), L("Change le contexte de filtre")),
        ("ALL", "ALL(Table)", L("Dans CALCULATE : ignore les filtres")),
        ("ALLSELECTED", "ALLSELECTED(Table)", L("Dans CALCULATE : ignore la catégorie, garde les segments")),
        ("IF", L("IF(condition, alors, sinon)"), L("Condition")),
        ("ROUND", "ROUND(x, 2)", L("Arrondi")),
        ("SUMX", L("SUMX(Table, Table[Colonne] * RELATED(Autre[Colonne]))"), L("Somme d'une expression ligne par ligne")),
        ("FILTER", L("FILTER(Table, Table[Colonne] > 100)"), L("Lignes qui respectent une condition")),
        ("RELATED", L("RELATED(Table[Colonne])"), L("Valeur de la table liée (contexte de ligne)")),
        ("TOTALYTD", L("TOTALYTD([Mesure], Table[Date])"), L("Cumul depuis le début de l'année")),
        ("SAMEPERIODLASTYEAR", L("CALCULATE([Mesure], SAMEPERIODLASTYEAR(Table[Date]))"), L("Même période l'an dernier")),
        ("DATEADD", L("CALCULATE([Mesure], DATEADD(Table[Date], -1, MONTH))"), L("Décale la période")),
        ("YEAR / MONTH", L("YEAR(Table[Date])"), L("Année d'une date (colonnes calculées)")),
        ("&", "\"a\" & \"b\"", L("Concatène du texte")),
        ("VAR", L("VAR x = [Mesure]\nRETURN x * 2"), L("Variables")),
        ("SWITCH", L("SWITCH(TRUE(), [Mesure] > 100, \"Haut\", \"Bas\")"), L("Choix entre plusieurs valeurs")),
        ("RANKX", L("RANKX(ALL(Table[Colonne]), [Mesure])"), L("Rang dans une liste")),
        ("TOPN", L("SUMX(TOPN(5, VALUES(Table[Colonne]), [Mesure]), [Mesure])"), L("Les N premiers")),
        ("SELECTEDVALUE", L("SELECTEDVALUE(Table[Colonne], \"plusieurs\")"), L("Valeur unique sélectionnée")),
        ("ALLEXCEPT", L("CALCULATE([Mesure], ALLEXCEPT(Table, Table[Colonne]))"), L("Ignore les filtres sauf certains")),
        ("USERELATIONSHIP", L("CALCULATE([Mesure], USERELATIONSHIP(A[Col], B[Col]))"), L("Utilise une relation inactive")),
        ("LOOKUPVALUE", L("LOOKUPVALUE(Table[Résultat], Table[Clé], \"valeur\")"), L("Recherche une valeur")),
        ("DATEDIFF", L("DATEDIFF(DATE(2024, 1, 1), TODAY(), MONTH)"), L("Écart entre deux dates")),
        ("FORMAT", L("FORMAT([Mesure], \"#,##0.00\")"), L("Met en forme un nombre ou une date")),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isColumn ? (draft.originalName == nil ? L("Nouvelle colonne calculée") : L("Modifier la colonne calculée"))
                 : (draft.id == nil ? L("Nouvelle mesure") : L("Modifier la mesure"))).font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                TextField(L("Nom"), text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker(L("Table"), selection: $draft.table) {
                    ForEach(state.tables) { Text($0.name).tag($0.name) }
                }
                .frame(width: 200)
                .disabled(draft.isColumn && draft.originalName != nil)
                if !draft.isColumn {
                    Picker(L("Format"), selection: $draft.format) {
                        ForEach(MeasureFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 210)
                }
            }
            if !draft.isColumn {
                DisclosureGroup(L("Mesures rapides"), isExpanded: $showQuick) { quickMeasures }
                    .font(.system(size: 12))
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
                            Text(draft.isColumn ? L("Premières valeurs : ") : L("Valeur sur toutes les données : ")).foregroundStyle(.secondary)
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
                    Text(L("Insérer")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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
            Text(L("Syntaxe : Table[Colonne] ou 'Table avec espaces'[Colonne], [Mesure] pour une autre mesure. Les arguments se séparent par « , » ou « ; » et les décimales s'écrivent avec un point."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack {
                if let id = draft.id, let m = state.measures.first(where: { $0.id == id }) {
                    Button(L("Supprimer"), role: .destructive) { state.deleteMeasure(m); dismiss() }
                }
                if draft.isColumn, let old = draft.originalName {
                    Button(L("Supprimer"), role: .destructive) { state.deleteColumn(table: draft.table, column: old); dismiss() }
                }
                Spacer()
                Button(L("Annuler"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Enregistrer")) {
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
        Menu(L("Champ ou mesure…")) {
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

    // MARK: Quick measures

    private var dateColumns: [String] {
        state.tables.flatMap { t in t.columns.filter { $0.type == .date }.map { reference(t.name, $0.name) } }
    }

    private var categoryColumns: [String] {
        state.tables.flatMap { t in t.columns.filter { $0.type == .text }.map { reference(t.name, $0.name) } }
    }

    private var quickMeasures: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L("Mesure de base"), selection: $quickMeasure) {
                    ForEach(state.measures.filter { $0.id != draft.id }) { Text($0.name).tag($0.name) }
                }
                Picker(L("Date"), selection: $quickDate) {
                    ForEach(dateColumns, id: \.self) { Text($0).tag($0) }
                }
                Picker(L("Catégorie"), selection: $quickCategory) {
                    ForEach(categoryColumns, id: \.self) { Text($0).tag($0) }
                }
            }
            .controlSize(.small)
            let m = quickMeasure
            HStack(spacing: 6) {
                quick(L("Cumul annuel"), L("%@ cumul annuel", m), "TOTALYTD([\(m)], \(quickDate))", needsDate: true)
                quick(L("Année précédente"), L("%@ N-1", m), "CALCULATE([\(m)], SAMEPERIODLASTYEAR(\(quickDate)))", needsDate: true)
                quick(L("Variation N-1 (%)"), L("%@ variation N-1", m),
                      "VAR actuel = [\(m)]\nVAR precedent = CALCULATE([\(m)], SAMEPERIODLASTYEAR(\(quickDate)))\nRETURN DIVIDE(actuel - precedent, precedent)",
                      needsDate: true, format: .percent)
                quick(L("Cumul"), L("%@ cumulé", m), "CALCULATE([\(m)], \(quickDate) <= MAX(\(quickDate)))", needsDate: true)
            }
            HStack(spacing: 6) {
                quick(L("% du total"), L("%@ % du total", m),
                      "DIVIDE([\(m)], CALCULATE([\(m)], ALLSELECTED(\(baseTable(m)))))", format: .percent)
                quick(L("Rang"), L("Rang de %@", m), "RANKX(ALL(\(quickCategory)), [\(m)])", needsCategory: true, format: .integer)
                quick(L("Moyenne par catégorie"), L("Moyenne de %@ par catégorie", m), "AVERAGEX(VALUES(\(quickCategory)), [\(m)])",
                      needsCategory: true)
            }
        }
        .padding(.top, 4)
        .onAppear {
            if quickMeasure.isEmpty { quickMeasure = state.measures.first { $0.id != draft.id }?.name ?? "" }
            if quickDate.isEmpty { quickDate = dateColumns.first ?? "" }
            if quickCategory.isEmpty { quickCategory = categoryColumns.first ?? "" }
        }
    }

    private func baseTable(_ measure: String) -> String {
        let t = state.measures.first { $0.name == measure }?.table ?? draft.table
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? t : "'\(t)'"
    }

    private func quick(_ title: String, _ name: String, _ expression: String, needsDate: Bool = false,
                       needsCategory: Bool = false, format: MeasureFormat? = nil) -> some View {
        Button(title) {
            draft.name = name
            draft.expression = expression
            if let format { draft.format = format }
            else if let base = state.measures.first(where: { $0.name == quickMeasure }) { draft.format = base.format }
            error = nil
        }
        .controlSize(.small)
        .disabled(quickMeasure.isEmpty || (needsDate && quickDate.isEmpty) || (needsCategory && quickCategory.isEmpty))
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
