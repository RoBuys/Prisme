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
        }
        if let i = args.firstIndex(of: "--edit-measure"), i + 1 < args.count,
           let m = AppState.shared.measures.first(where: { $0.name == args[i + 1] }) {
            AppState.shared.editMeasure(m)
        }
        if args.contains("--model") { AppState.shared.mode = .model }
    }

    var body: some Scene {
        Window("Prisme", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau rapport") { state.newDocument() }.keyboardShortcut("n")
                Button("Ouvrir…") { state.openDocument() }.keyboardShortcut("o")
                Divider()
                Button("Obtenir des données…") { state.importWithPanel() }.keyboardShortcut("i")
                Button("Charger les données d'exemple") { state.loadSample() }
                Button("Actualiser les données") { state.refreshAll() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Enregistrer") { state.save() }.keyboardShortcut("s")
                Button("Enregistrer sous…") { state.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Visuel") {
                Menu("Nouveau visuel") {
                    ForEach(VisualType.allCases) { t in
                        Button(t.label) { state.mode = .report; state.addVisual(t) }
                    }
                }
                Divider()
                Button("Dupliquer") { state.duplicateVisual() }
                    .keyboardShortcut("d")
                    .disabled(state.selectedVisualID == nil)
                Button("Supprimer") { state.deleteVisual() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(state.selectedVisualID == nil)
                Divider()
                Button("Nouvelle page") { state.addPage() }.keyboardShortcut("t")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `--snapshot <file.png>`: renders the main window to an image after launch (debugging aid).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let main = NSApp.windows.first(where: { $0.isVisible })
                guard let view = (main?.attachedSheet ?? main)?.contentView,
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
        state.importFiles(urls.filter { $0.pathExtension.lowercased() != "prisme" })
    }
}
