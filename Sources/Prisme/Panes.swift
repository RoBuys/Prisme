import SwiftUI

struct PaneHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

/// Dashed drop zone that accepts fields dragged from the Data pane.
struct FieldDropZone: View {
    let placeholder: String
    let onDrop: (FieldRef) -> Void
    @State private var targeted = false

    var body: some View {
        Text(placeholder)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Theme.accent.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(targeted ? Theme.accent : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
            .dropDestination(for: String.self) { items, _ in
                let fields = items.compactMap(FieldRef.init(payload:))
                fields.forEach(onDrop)
                return !fields.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

// MARK: - Visualizations pane

struct VisualizationsPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: L("Visualisations"))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    typeGrid
                    Divider()
                    if let v = state.selectedVisual {
                        wells(v)
                        Divider()
                        formatSection(v)
                    } else {
                        Text(L("Sélectionnez un visuel sur la page pour modifier ses champs, ou cliquez sur un type ci-dessus pour en créer un."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.background)
    }

    private var typeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
            ForEach(VisualType.allCases) { t in
                let active = state.selectedVisual?.type == t
                Button { state.visualTypeTapped(t) } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 16))
                        .frame(width: 40, height: 36)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.accent : .clear))
                        .foregroundStyle(active ? Theme.accent : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.selectedVisual == nil ? L("Ajouter : %@", t.label) : L("Convertir en : %@", t.label))
            }
        }
    }

    @ViewBuilder
    private func wells(_ v: Visual) -> some View {
        switch v.type {
        case .column, .bar, .line, .area:
            axisWell(L("Axe"), v, multi: false)
            legendWell(v)
            valuesWell(L("Valeurs"), v, multi: true)
        case .pie, .donut:
            axisWell(L("Légende"), v, multi: false)
            valuesWell(L("Valeurs"), v, multi: false)
        case .card:
            valuesWell(L("Champs"), v, multi: false)
        case .table:
            axisWell(L("Regrouper par"), v, multi: true)
            valuesWell(L("Valeurs"), v, multi: true)
        case .slicer:
            axisWell(L("Champ"), v, multi: false)
        }
    }

    private func wellSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func axisWell(_ title: String, _ v: Visual, multi: Bool) -> some View {
        let items = multi ? v.axis : Array(v.axis.prefix(1))
        return wellSection(title) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, f in
                FieldChip(name: f.displayName, warning: warning(f, v)) {
                    dateLevelMenu(f) { level in state.mutateVisual(v.id) { $0.axis[i].dateLevel = level } }
                } onRemove: {
                    state.mutateVisual(v.id) { $0.axis.remove(at: i) }
                    if state.crossFilter?.visualID == v.id { state.crossFilter = nil }
                }
            }
            if multi || items.isEmpty {
                FieldDropZone(placeholder: L("Ajouter des champs ici")) { state.addField($0, to: .axis, visualID: v.id) }
            } else {
                FieldDropZone(placeholder: L("Remplacer le champ")) { state.addField($0, to: .axis, visualID: v.id) }
            }
        }
    }

    private func legendWell(_ v: Visual) -> some View {
        wellSection(L("Légende")) {
            if let l = v.legend {
                FieldChip(name: l.displayName, warning: warning(l, v)) {
                    dateLevelMenu(l) { level in state.mutateVisual(v.id) { $0.legend?.dateLevel = level } }
                } onRemove: {
                    state.mutateVisual(v.id) { $0.legend = nil }
                }
            }
            FieldDropZone(placeholder: v.legend == nil ? L("Ajouter un champ ici") : L("Remplacer le champ")) {
                state.addField($0, to: .legend, visualID: v.id)
            }
        }
    }

    private func valuesWell(_ title: String, _ v: Visual, multi: Bool) -> some View {
        let items = multi ? v.values : Array(v.values.prefix(1))
        return wellSection(title) {
            ForEach(items) { vf in
                FieldChip(name: vf.displayName, warning: warning(vf.field, v), isMeasure: vf.measure) {
                    let isNumber = state.column(for: vf.field)?.type == .number
                    if vf.measure, let m = state.measure(for: vf.field) {
                        Button(L("Modifier la mesure…")) { state.editMeasure(m) }
                    }
                    ForEach(vf.measure ? [] : Aggregation.allCases.filter { isNumber || !$0.isNumericOnly }, id: \.self) { a in
                        Button {
                            state.mutateVisual(v.id) { vis in
                                if let i = vis.values.firstIndex(where: { $0.id == vf.id }) { vis.values[i].aggregation = a }
                            }
                        } label: {
                            if vf.aggregation == a { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                        }
                    }
                } onRemove: {
                    state.mutateVisual(v.id) { $0.values.removeAll { $0.id == vf.id } }
                }
            }
            if multi || items.isEmpty {
                FieldDropZone(placeholder: L("Ajouter des champs ici")) { state.addField($0, to: .values, visualID: v.id) }
            } else {
                FieldDropZone(placeholder: L("Remplacer le champ")) { state.addField($0, to: .values, visualID: v.id) }
            }
        }
    }

    @ViewBuilder
    private func dateLevelMenu(_ f: FieldRef, set: @escaping (DateLevel?) -> Void) -> some View {
        if state.column(for: f)?.type == .date {
            ForEach(DateLevel.allCases, id: \.self) { l in
                Button { set(l) } label: {
                    if f.dateLevel == l { Label(l.label, systemImage: "checkmark") } else { Text(l.label) }
                }
            }
        } else {
            Text(L("Aucune option")).foregroundStyle(.secondary)
        }
    }

    private func warning(_ f: FieldRef, _ v: Visual) -> String? {
        if let m = state.measure(for: f) {
            if let err = MeasureCompiler.validate(m.expression, home: m.table, name: m.name, state.model) { return err }
        } else if state.column(for: f) == nil { return L("Champ introuvable") }
        if Engine.unreachableFields(v, state.model).contains(f.columnKey) {
            return L("Aucune relation ne relie ce champ aux autres champs du visuel : il est ignoré. Créez une relation dans la vue Modèle.")
        }
        return nil
    }

    private func formatSection(_ v: Visual) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Mise en forme")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Toggle(L("Afficher le titre"), isOn: Binding(
                get: { v.showTitle },
                set: { val in state.mutateVisual(v.id) { $0.showTitle = val } }))
                .toggleStyle(.switch)
                .controlSize(.small)
            TextField(v.autoTitle, text: Binding(
                get: { v.title },
                set: { val in state.mutateVisual(v.id) { $0.title = val } }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Text(L("Taille : %@ × %@  ·  Position : %@, %@", Int(v.frame.width), Int(v.frame.height), Int(v.frame.minX), Int(v.frame.minY)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct FieldChip<MenuContent: View>: View {
    let name: String
    var warning: String?
    var isMeasure = false
    @ViewBuilder let menu: () -> MenuContent
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if warning != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
            } else if isMeasure {
                Image(systemName: "function").foregroundStyle(Theme.accent).font(.system(size: 10))
            }
            Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Menu { menu() } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.10)))
        .help(warning ?? name)
    }
}

// MARK: - Data (fields) pane

struct FieldsPane: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: L("Données"))
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField(L("Rechercher"), text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if state.tables.isEmpty {
                VStack(spacing: 10) {
                    Text(L("Aucune donnée chargée")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("Obtenir des données…")) { state.importWithPanel() }
                    Button(L("Données d'exemple")) { state.loadSample() }.buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.tables) { t in
                        tableSection(t)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
        .alert(L("Renommer la table"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Nom"), text: $draft)
            Button(L("Renommer")) { if let old = renaming { state.renameTable(old, to: draft) }; renaming = nil }
            Button(L("Annuler"), role: .cancel) { renaming = nil }
        }
    }

    private func tableSection(_ t: DataTable) -> some View {
        let cols = search.isEmpty ? t.columns : t.columns.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return DisclosureGroup(isExpanded: Binding(
            get: { !collapsed.contains(t.name) || !search.isEmpty },
            set: { open in if open { collapsed.remove(t.name) } else { collapsed.insert(t.name) } })) {
            ForEach(cols) { c in fieldRow(t, c) }
            ForEach(state.measures.filter { $0.table == t.name && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { m in
                measureRow(m)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tablecells").foregroundStyle(Theme.accent)
                Text(t.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(t.rows.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { state.dataTableName = t.name; state.mode = .data }
            .contextMenu {
                Button(L("Afficher les données")) { state.dataTableName = t.name; state.mode = .data }
                Button(L("Nouvelle mesure…")) { state.newMeasure(in: t.name) }
                Button(L("Renommer…")) { draft = t.name; renaming = t.name }
                if t.source != nil { Button(L("Actualiser")) { state.refreshAll() } }
                Divider()
                Button(L("Supprimer la table"), role: .destructive) { state.deleteTable(t.name) }
            }
        }
    }

    private func measureRow(_ m: Measure) -> some View {
        let used = state.mode == .report
            && (state.selectedVisual?.values.contains { $0.measure && $0.field == m.field } ?? false)
        return HStack(spacing: 6) {
            if state.mode == .report {
                Image(systemName: used ? "checkmark.square.fill" : "square")
                    .foregroundStyle(used ? Theme.accent : .secondary)
            }
            Image(systemName: "function").font(.system(size: 10)).foregroundStyle(Theme.accent).frame(width: 14)
            Text(m.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if state.mode == .report { state.quickAdd(m.field) } }
        .onTapGesture(count: 2) { state.editMeasure(m) }
        .draggable(m.field.payload) {
            Label(m.name, systemImage: "function")
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
        }
        .contextMenu {
            Button(L("Modifier la mesure…")) { state.editMeasure(m) }
            Button(L("Supprimer la mesure"), role: .destructive) { state.deleteMeasure(m) }
        }
        .help(L("Mesure : %@", m.expression))
    }

    private func fieldRow(_ t: DataTable, _ c: DataColumn) -> some View {
        let field = FieldRef(table: t.name, column: c.name)
        let used = state.mode == .report
            && (state.selectedVisual?.allFields.contains { $0.columnKey == field.columnKey } ?? false)
        return HStack(spacing: 6) {
            if state.mode == .report {
                Image(systemName: used ? "checkmark.square.fill" : "square")
                    .foregroundStyle(used ? Theme.accent : .secondary)
            }
            Image(systemName: c.type.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(c.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if state.mode == .report { state.quickAdd(field) } else { state.dataTableName = t.name }
        }
        .draggable(field.payload) {
            Label(c.name, systemImage: c.type.symbol)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
        }
        .help(L("Cliquez pour ajouter au visuel sélectionné, ou glissez vers un emplacement de champ"))
    }
}

// MARK: - Filters pane

struct FiltersPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PaneHeader(title: L("Filtres"))
                Button { state.showFilters = false } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                    .help(L("Masquer le volet Filtres"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let cf = state.crossFilter, cf.pageID == state.currentPageID {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Filtre croisé")).font(.system(size: 11, weight: .semibold))
                                Text("\(cf.field.displayName) = \(cf.label)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { state.crossFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.10)))
                    }
                    if let v = state.selectedVisual {
                        let fs = visualFilterSummary(v)
                        if !fs.isEmpty {
                            Text(L("Appliqués à ce visuel")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(fs, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Divider()
                        }
                    }
                    Text(L("Filtres sur cette page")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(state.currentPage.filters) { f in FilterCard(filter: f) }
                    FieldDropZone(placeholder: L("Ajouter des champs de données ici")) { state.addPageFilter($0) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.background)
    }

    private func visualFilterSummary(_ v: Visual) -> [String] {
        state.filters(for: v).map { f in
            let values = f.allowed.sorted()
            let shown = values.prefix(3).joined(separator: ", ")
            return "\(f.field.displayName) : \(shown)\(values.count > 3 ? " +\(values.count - 3)" : "")"
        }
    }
}

struct FilterCard: View {
    let filter: PageFilter
    @Environment(AppState.self) private var state
    @State private var expanded = true
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(filter.field.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.column(for: filter.field)?.type == .date {
                    Menu {
                        ForEach(DateLevel.allCases, id: \.self) { l in
                            Button(l.label) {
                                state.mutateFilter(filter.id) { $0.field.dateLevel = l; $0.selected = [] }
                            }
                        }
                    } label: { Image(systemName: "calendar") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                if !filter.selected.isEmpty {
                    Button { state.mutateFilter(filter.id) { $0.selected = [] } } label: {
                        Image(systemName: "eraser")
                    }
                    .buttonStyle(.plain).help(L("Effacer le filtre"))
                }
                Button { state.removePageFilter(filter.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L("Supprimer le filtre"))
            }
            if expanded {
                let all = Engine.distinctValues(filter.field, state.tables)
                if all.count > 8 {
                    TextField(L("Rechercher"), text: $search).textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
                let values = search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(values, id: \.self) { v in
                            let on = filter.selected.contains(v)
                            HStack(spacing: 6) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? Theme.accent : .secondary)
                                Text(v).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.mutateFilter(filter.id) { f in
                                    if f.selected.contains(v) { f.selected.remove(v) } else { f.selected.insert(v) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var summary: String {
        if filter.selected.isEmpty { return L("est (Tout)") }
        let s = filter.selected.sorted()
        return L("est ") + s.prefix(2).joined(separator: ", ") + (s.count > 2 ? " +\(s.count - 2)" : "")
    }
}
