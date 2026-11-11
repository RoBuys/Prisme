import SwiftUI

enum Theme {
    static let palette: [Color] = [
        0x2E6FD8, 0xF28C28, 0x2BA37A, 0xC2417B, 0x7E57C2, 0xE0B400, 0x4BB3D8, 0x8C6D4F, 0xD9534F, 0x5C6F82,
    ].map { Color(hex: $0) }

    static func colors(_ n: Int) -> [Color] {
        (0..<max(n, 1)).map { palette[$0 % palette.count] }
    }

    static let accent = Color(hex: 0x2E6FD8)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            RibbonView()
            Divider()
            HStack(spacing: 0) {
                ModeRail()
                Divider()
                if state.mode == .report {
                    VStack(spacing: 0) {
                        ReportCanvas()
                        Divider()
                        PageTabsBar()
                    }
                    Divider()
                    if state.showFilters {
                        FiltersPane().frame(width: 220)
                    } else {
                        CollapsedPaneStrip(title: "Filtres", count: state.activeFilterCount) { state.showFilters = true }
                    }
                    Divider()
                    VisualizationsPane().frame(width: 236)
                    Divider()
                    FieldsPane().frame(width: 220)
                } else if state.mode == .data {
                    DataGridView()
                    Divider()
                    FieldsPane().frame(width: 220)
                } else if state.mode == .powerbi {
                    PowerBIView()
                } else {
                    ModelView()
                    Divider()
                    RelationshipsPane().frame(width: 260)
                }
            }
        }
        .navigationTitle(state.windowTitle)
        .overlay {
            if state.isImporting {
                ProgressView("Chargement des données…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: Binding(get: { state.measureDraft }, set: { state.measureDraft = $0 })) { d in
            MeasureEditor(draft: d).environment(state)
        }
        .alert("Prisme", isPresented: Binding(get: { state.alertMessage != nil },
                                              set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(state.alertMessage ?? "")
        }
    }
}

// MARK: - Ribbon

struct RibbonView: View {
    @Environment(AppState.self) private var state
    @State private var showVisualPicker = false

    var body: some View {
        HStack(spacing: 2) {
            RibbonGroup("Fichier") {
                RibbonButton("Ouvrir", "folder") { state.openDocument() }
                RibbonButton("Enregistrer", "square.and.arrow.down") { state.save() }
                RibbonButton("Annuler", "arrow.uturn.backward") { state.undo() }.disabled(!state.canUndo)
                RibbonButton("Rétablir", "arrow.uturn.forward") { state.redo() }.disabled(!state.canRedo)
            }
            RibbonDivider()
            RibbonGroup("Données") {
                RibbonButton("Obtenir des données", "cylinder.split.1x2") { state.importWithPanel() }
                RibbonButton("Exemple", "sparkles") { state.loadSample() }
                RibbonButton("Actualiser", "arrow.clockwise") { state.refreshAll() }
                    .disabled(state.tables.isEmpty)
            }
            RibbonDivider()
            RibbonGroup("Calculs") {
                RibbonButton("Nouvelle mesure", "function") { state.newMeasure() }
                    .disabled(state.tables.isEmpty)
            }
            RibbonDivider()
            RibbonGroup("Insérer") {
                RibbonButton("Nouveau visuel", "chart.bar.xaxis") { showVisualPicker.toggle() }
                    .popover(isPresented: $showVisualPicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(VisualType.allCases) { t in
                                Button {
                                    showVisualPicker = false
                                    state.mode = .report
                                    state.addVisual(t)
                                } label: {
                                    Label(t.label, systemImage: t.symbol)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4).padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .frame(width: 200)
                    }
                RibbonButton("Nouvelle page", "doc.badge.plus") { state.mode = .report; state.addPage() }
            }
            RibbonDivider()
            RibbonGroup("Visuel") {
                RibbonButton("Dupliquer", "plus.square.on.square") { state.duplicateVisual() }
                    .disabled(state.selectedVisualID == nil)
                RibbonButton("Supprimer", "trash") { state.deleteVisual() }
                    .disabled(state.selectedVisualID == nil)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) { content }
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

struct RibbonDivider: View {
    var body: some View { Divider().frame(height: 52).padding(.horizontal, 6) }
}

struct RibbonLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18)).frame(height: 22)
            Text(title).font(.system(size: 10.5)).lineLimit(1)
        }
        .frame(minWidth: 64)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct RibbonButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            RibbonLabel(title: title, symbol: symbol)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .onHover { hover = $0 }
    }
}

// MARK: - Mode rail

struct ModeRail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 6) {
            item(.report, "chart.bar.doc.horizontal", "Rapport")
            item(.data, "tablecells", "Données")
            item(.model, "point.3.connected.trianglepath.dotted", "Modèle")
            Divider().frame(width: 30).padding(.vertical, 2)
            item(.powerbi, "cloud", "Power BI")
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 52)
        .background(.background.secondary)
    }

    private func item(_ mode: AppMode, _ symbol: String, _ label: String) -> some View {
        Button { state.mode = mode } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 38, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(state.mode == mode ? Theme.accent.opacity(0.16) : .clear))
                .overlay(alignment: .leading) {
                    if state.mode == mode {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 20).offset(x: -6)
                    }
                }
                .foregroundStyle(state.mode == mode ? Theme.accent : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Page tabs

struct PageTabsBar: View {
    @Environment(AppState.self) private var state
    @State private var renaming: UUID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.pages) { p in tab(p) }
                    Button { state.addPage() } label: {
                        Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nouvelle page")
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Text("Page \(state.pageIndex + 1) sur \(state.pages.count)")
                .font(.caption).foregroundStyle(.secondary).padding(.trailing, 12)
        }
        .frame(height: 34)
        .background(.bar)
    }

    @ViewBuilder
    private func tab(_ p: ReportPage) -> some View {
        let active = p.id == state.currentPageID
        Group {
            if renaming == p.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(width: 120)
                    .onSubmit { commit(p.id) }
                    .onChange(of: focused) { _, f in if !f { commit(p.id) } }
            } else {
                Text(p.name).lineLimit(1)
            }
        }
        .font(.system(size: 12, weight: active ? .semibold : .regular))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.primary.opacity(0.09) : .clear))
        .overlay(alignment: .bottom) {
            if active { Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 8) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(p) }
        .onTapGesture { state.selectPage(p.id) }
        .contextMenu {
            Button("Renommer") { startRename(p) }
            Button("Dupliquer") { state.duplicatePage(p.id) }
            Button("Supprimer", role: .destructive) { state.deletePage(p.id) }.disabled(state.pages.count < 2)
        }
    }

    private func startRename(_ p: ReportPage) {
        draft = p.name
        renaming = p.id
        DispatchQueue.main.async { focused = true }
    }

    private func commit(_ id: UUID) {
        guard renaming == id else { return }
        state.renamePage(id, draft)
        renaming = nil
    }
}

/// Thin vertical strip shown when a side pane is collapsed (click to expand).
struct CollapsedPaneStrip: View {
    let title: String
    var count = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 20, height: 60)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.accent))
                }
                Spacer()
            }
            .padding(.top, 12)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background)
        .help("Afficher le volet \(title)")
    }
}
