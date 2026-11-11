import SwiftUI

struct ReportCanvas: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let s = max(0.3, min((geo.size.width - 48) / PageSize.width, (geo.size.height - 48) / PageSize.height))
            let pw = PageSize.width * s, ph = PageSize.height * s
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .onTapGesture { state.clearSelection() }
                // The page is laid out at its logical size, then scaled to fit (text scales too).
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white)
                        .onTapGesture { state.clearSelection() }
                    ForEach(state.currentPage.visuals) { v in
                        VisualContainer(visual: v, scale: s)
                    }
                    if state.currentPage.visuals.isEmpty {
                        EmptyPageView()
                    }
                }
                .frame(width: PageSize.width, height: PageSize.height, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: pw, height: ph, alignment: .topLeading)
                .clipped()
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .environment(\.colorScheme, .light)
                .overlay(alignment: .topLeading) {
                    if state.drillthroughOrigin != nil {
                        Button { state.drillthroughBack() } label: {
                            Label(L("Retour"), systemImage: "chevron.backward.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                if let pbi = files.first(where: { PowerBIImporter.extensions.contains($0.pathExtension.lowercased()) }) {
                    state.importPowerBI(pbi)
                    return true
                }
                state.importFiles(files)
                return true
            }
        }
    }
}

struct EmptyPageView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: state.tables.isEmpty ? "cylinder.split.1x2" : "chart.bar.xaxis")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            if state.tables.isEmpty {
                Text(L("Ajouter des données à votre rapport")).font(.title2.weight(.semibold))
                Text(L("Importez un fichier CSV ou Excel (ou glissez-le ici), puis construisez vos visuels."))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("Importer un fichier…")) { state.importWithPanel() }.buttonStyle(.borderedProminent)
                    Button(L("Utiliser les données d'exemple")) { state.loadSample() }
                }
                .controlSize(.large)
            } else {
                Text(L("Créez votre premier visuel")).font(.title2.weight(.semibold))
                Text(L("Choisissez un type dans le volet Visualisations, ou cliquez sur un champ du volet Données."))
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

// MARK: - Visual container (move, resize, select)

struct VisualContainer: View {
    let visual: Visual
    let scale: CGFloat
    @Environment(AppState.self) private var state
    @State private var drag: CGSize = .zero
    @State private var resize: CGSize = .zero
    @State private var hover = false

    var body: some View {
        let f = visual.frame
        let selected = state.selectedVisualID == visual.id
        let w = max(120, f.width + resize.width)
        let h = max(70, f.height + resize.height)

        let element = visual.type.isElement
        VisualContentView(visual: visual)
            .padding(element ? 0 : 10)
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 4).fill(element ? Color.clear : Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Theme.accent : Color.black.opacity(hover ? 0.18 : (element ? 0 : 0.06)),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected || hover { headerMenu.padding(4) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected { resizeHandle }
            }
            .contentShape(Rectangle())
            .offset(x: f.minX + drag.width, y: f.minY + drag.height)
            .simultaneousGesture(TapGesture().onEnded {
                if visual.type == .button, NSEvent.modifierFlags.contains(.command) {
                    state.perform(visual.element.action)
                    return
                }
                if state.selectedVisualID != visual.id { state.selectedVisualID = visual.id }
            })
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { g in
                        if state.selectedVisualID != visual.id { state.selectedVisualID = visual.id }
                        drag = CGSize(width: g.translation.width / scale, height: g.translation.height / scale)
                    }
                    .onEnded { g in
                        let nf = f.offsetBy(dx: g.translation.width / scale, dy: g.translation.height / scale)
                        drag = .zero
                        state.moveVisual(visual.id, to: nf)
                    }
            )
            .onHover { hover = $0 }
            .contextMenu {
                Button(L("Dupliquer")) { state.duplicateVisual(visual.id) }
                Button(L("Mettre au premier plan")) { state.bringToFront(visual.id) }
                Button(L("Exporter les données (CSV)…")) { state.exportCSV(visual.id) }
                drillthroughItems
                Divider()
                Button(L("Supprimer"), role: .destructive) { state.deleteVisual(visual.id) }
            }
    }

    private var headerMenu: some View {
        HStack(spacing: 2) {
            if visual.supportsHierarchy && visual.axis.count > 1 {
                drillButton("arrow.up", L("Remonter"), enabled: visual.level > 0) { state.drillUp(visual) }
                drillButton("arrow.down", visual.drillMode == true ? L("Désactiver l'exploration au clic") : L("Explorer au clic"),
                            enabled: true, active: visual.drillMode == true) { state.toggleDrillMode(visual) }
                drillButton("arrow.down.to.line", L("Niveau suivant"), enabled: visual.canDrillDown) { state.nextLevel(visual) }
            }
            menu
        }
    }

    private func drillButton(_ symbol: String, _ help: String, enabled: Bool, active: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(active ? Theme.accent.opacity(0.25) : Color.white.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? (active ? Theme.accent : Color.secondary) : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private var drillthroughItems: some View {
        if let cf = state.crossFilter, cf.visualID == visual.id {
            let targets = state.drillthroughTargets(for: cf.field)
            if !targets.isEmpty {
                Divider()
                ForEach(targets) { p in
                    Button(L("Extraire « %@ » vers %@", cf.label, p.name)) { state.drillthrough(to: p.id, field: cf.field, label: cf.label) }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(L("Dupliquer")) { state.duplicateVisual(visual.id) }
            Button(L("Mettre au premier plan")) { state.bringToFront(visual.id) }
            Button(L("Exporter les données (CSV)…")) { state.exportCSV(visual.id) }
            drillthroughItems
            Divider()
            Button(L("Supprimer"), role: .destructive) { state.deleteVisual(visual.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.9)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent))
            .offset(x: 4, y: 4)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        resize = CGSize(width: g.translation.width / scale, height: g.translation.height / scale)
                    }
                    .onEnded { g in
                        var nf = visual.frame
                        nf.size.width += g.translation.width / scale
                        nf.size.height += g.translation.height / scale
                        resize = .zero
                        state.moveVisual(visual.id, to: nf)
                    }
            )
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }
}
