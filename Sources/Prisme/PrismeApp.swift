import SwiftUI
import AppKit

@main
struct PrismeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    init() {
        // `Prisme --inspect <file>…` prints how files are imported, then quits (handy for debugging imports).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--inspect") {
            for path in args.dropFirst(i + 1) {
                do {
                    for t in try Importer.load(URL(fileURLWithPath: path)) {
                        print("▸ \(t.name) — \(t.rows.count) lignes")
                        for (c, col) in t.columns.enumerated() {
                            let sample = t.rows.prefix(3).map { Fmt.cell($0[c]) }.joined(separator: " | ")
                            print("   \(col.name) [\(col.type.label)]  \(sample)")
                        }
                    }
                } catch {
                    print("✗ \(path): \(error.localizedDescription)")
                }
            }
            exit(0)
        }
        if args.contains("--sample") {
            AppState.shared.loadSample()
            AppState.shared.isDirty = false
            AppState.shared.resetHistory()
        }
        if let i = args.firstIndex(of: "--edit-measure"), i + 1 < args.count,
           let m = AppState.shared.measures.first(where: { $0.name == args[i + 1] }) {
            AppState.shared.editMeasure(m)
        }
        if args.contains("--model") { AppState.shared.mode = .model }
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let n = Int(args[i + 1]),
           n >= 1, n <= AppState.shared.pages.count {
            AppState.shared.selectPage(AppState.shared.pages[n - 1].id)
        }
        if args.contains("--powerbi") { AppState.shared.mode = .powerbi }
        if args.contains("--data") { AppState.shared.mode = .data }
    }

    var body: some Scene {
        Window("Prisme", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 920)

        Settings {
            SettingsView().environment(state)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("Rechercher les mises à jour…")) { Task { await Updater.shared.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {
                let _ = state.language   // rebuild menus when the language changes
                Button(L("Nouveau rapport")) { state.newDocument() }.keyboardShortcut("n")
                Button(L("Ouvrir…")) { state.openDocument() }.keyboardShortcut("o")
                Button(L("Importer un rapport Power BI (.pbit, .pbip, .pbix)…")) { state.importPowerBIWithPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Divider()
                Button(L("Obtenir des données…")) { state.showGetData = true }.keyboardShortcut("i")
                Button(L("Importer un fichier…")) { state.importWithPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L("Charger les données d'exemple")) { state.loadSample() }
                Button(L("Actualiser les données")) { state.refreshAll() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("Annuler|undo")) { Self.undoOrTextUndo(redo: false) }.keyboardShortcut("z")
                Button(L("Rétablir")) { Self.undoOrTextUndo(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Enregistrer")) { state.save() }.keyboardShortcut("s")
                Button(L("Enregistrer sous…")) { state.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu(L("Exporter")) {
                    Button(L("Toutes les pages en PDF…")) { state.exportPDF() }.keyboardShortcut("p", modifiers: [.command, .shift])
                    Button(L("Page affichée en image (PNG)…")) { state.exportPNG() }
                    Button(L("Données du visuel (CSV)…")) { if let id = state.selectedVisualID { state.exportCSV(id) } }
                        .disabled(state.selectedVisualID == nil)
                    Divider()
                    Button(L("Modèle Power BI (.pbit)…")) { state.exportPBIT() }
                        .disabled(state.tables.isEmpty)
                }
            }
            CommandMenu(L("Visuel")) {
                Menu(L("Nouveau visuel")) {
                    ForEach(VisualType.allCases) { t in
                        Button(t.label) { state.mode = .report; state.addVisual(t) }
                    }
                }
                Divider()
                Button(L("Dupliquer")) { state.duplicateVisual() }
                    .keyboardShortcut("d")
                    .disabled(state.selectedVisualID == nil)
                Button(L("Supprimer")) { state.deleteVisual() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.selectedVisualID == nil)
                Divider()
                Button(L("Nouvelle page")) { state.addPage() }.keyboardShortcut("t")
            }
        }
    }
}

extension PrismeApp {
    /// ⌘Z goes to the text being edited when a text field has focus, otherwise to the document.
    static func undoOrTextUndo(redo: Bool) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let um = text.undoManager,
           redo ? um.canRedo : um.canUndo {
            redo ? um.redo() : um.undo()
            return
        }
        redo ? AppState.shared.redo() : AppState.shared.undo()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { Updater.shared.checkAtLaunch() }
        // `--install-update`: checks and installs the latest release without asking (testing aid).
        if CommandLine.arguments.contains("--install-update") {
            Task { @MainActor in
                await Updater.shared.check(userInitiated: true)
                if case .available(let r) = Updater.shared.phase { await Updater.shared.install(r) }
            }
        }
        // `--snapshot <file.png>`: renders the main window to an image after launch (debugging aid).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            // `--width <points>`: resizes the window first (to check the layout at a given size).
            if let w = args.firstIndex(of: "--width").flatMap({ $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let win = NSApp.windows.first(where: { $0.isVisible }) else { return }
                    var f = win.frame
                    f.size.width = w
                    win.setFrame(f, display: true)
                }
            }
            // `--snapshot-main`: the main window even when a sheet (an alert) is shown; `--delay <s>`.
            let delay = args.firstIndex(of: "--delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil })
                let target = args.contains("--snapshot-main") ? main : (main?.attachedSheet ?? main)
                guard let view = target?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let state = AppState.shared
        let reports = urls.filter { $0.pathExtension.lowercased() == "prisme" }
        if let r = reports.first, state.confirmDiscard() { state.open(r) }
        if let pbi = urls.first(where: { PowerBIImporter.extensions.contains($0.pathExtension.lowercased()) }) {
            state.importPowerBI(pbi)
            return
        }
        state.importFiles(urls.filter { $0.pathExtension.lowercased() != "prisme" })
    }
}
