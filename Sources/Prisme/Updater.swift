import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Automatic updates from the GitHub releases of the project.
///
/// The latest release is read from the public GitHub API (nothing about the user is sent). Its zipped app is
/// downloaded over HTTPS, checked against the SHA-256 digest GitHub publishes for the asset, unzipped, and checked
/// again (bundle identifier, newer version). The running app is then replaced by a small script that waits for
/// Prisme to quit, swaps the bundles (the old one goes to the Trash) and relaunches the new version.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repository = "RoBuys/Prisme"
    nonisolated static let bundleIdentifier = "local.prisme"
    private static let autoKey = "prisme.update.auto"
    private static let lastCheckKey = "prisme.update.lastCheck"
    private static let skippedKey = "prisme.update.skipped"

    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var assetURL: URL
        var assetSize: Int
        /// "sha256:…" as published by GitHub (nil for very old releases).
        var digest: String?
        var page: URL?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Double), installing, failed(String)
    }

    var phase: Phase = .idle
    var showSheet = false

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Versions

    /// Numeric components of "v1.2.3" / "1.2" (missing ones are 0).
    nonisolated static func components(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Checking

    /// The latest release from the GitHub API response (the zipped macOS app asset).
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-macOS.zip") == true }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), tag: tag,
                       notes: json["body"] as? String ?? "", assetURL: url, assetSize: asset["size"] as? Int ?? 0,
                       digest: asset["digest"] as? String, page: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// Checks at launch, at most once a day, when automatic checks are on.
    func checkAtLaunch() {
        guard automatic, !Self.runningFromBuildFolder else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if userInitiated { phase = .checking; showSheet = true }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Prisme-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let r = Self.parseRelease(data) else {
                throw ImportError(message: L("Réponse inattendue du serveur de mises à jour."))
            }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if Self.isNewer(r.version, than: Self.currentVersion) {
                if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedKey) == r.version { return }
                phase = .available(r)
                showSheet = true
            } else if userInitiated {
                phase = .upToDate
            }
        } catch {
            if userInitiated { phase = .failed(error.localizedDescription) }
        }
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: Self.skippedKey)
        showSheet = false
        phase = .idle
    }

    // MARK: Installing

    /// Apps launched from a quarantined download run from a read-only copy: they can't replace themselves.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Development builds (`swift run`, not an .app bundle) aren't updated.
    static var runningFromBuildFolder: Bool { !Bundle.main.bundlePath.hasSuffix(".app") }

    func install(_ r: Release) async {
        guard !Self.isTranslocated else {
            phase = .failed(L("Déplacez Prisme dans le dossier Applications, relancez-le, puis réessayez."))
            return
        }
        guard !Self.runningFromBuildFolder else {
            phase = .failed(L("Cette copie de Prisme n'est pas une application installée."))
            return
        }
        phase = .downloading(0)
        do {
            let zip = try await download(r)
            phase = .installing
            let newApp = try Self.unpackAndVerify(zip: zip, release: r)
            // Unsaved changes are handled before anything is replaced.
            guard AppState.shared.confirmDiscard() else {
                phase = .available(r)
                return
            }
            try Self.replaceAndRelaunch(current: Bundle.main.bundleURL, with: newApp)
            // An open sheet keeps the app from quitting: close it, quit, and make sure it does.
            showSheet = false
            AppState.shared.isDirty = false
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
            try? await Task.sleep(for: .seconds(3))
            exit(0)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ r: Release) async throws -> URL {
        // Downloaded to a file by the URL session; progress comes from a delegate.
        let progress = DownloadProgress { [weak self] f in Task { @MainActor in self?.phase = .downloading(f) } }
        let (file, response) = try await URLSession.shared.download(from: r.assetURL, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ImportError(message: L("Le téléchargement de la mise à jour a échoué."))
        }
        try Self.verifyDigest(try Data(contentsOf: file), r.digest)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(r.assetURL.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: zip)
        return zip
    }

    nonisolated static func verifyDigest(_ data: Data, _ digest: String?) throws {
        guard let digest else { return }   // releases older than GitHub's asset digests
        guard digest.hasPrefix("sha256:") else { throw ImportError(message: L("Empreinte de la mise à jour inconnue.")) }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == digest.dropFirst(7).lowercased() else {
            throw ImportError(message: L("La mise à jour téléchargée est corrompue (empreinte différente)."))
        }
    }

    /// Unzips the release and checks the app inside: same bundle identifier, the announced (newer) version.
    nonisolated static func unpackAndVerify(zip: URL, release r: Release) throws -> URL {
        let dir = zip.deletingLastPathComponent().appendingPathComponent("unzipped")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw ImportError(message: L("L'archive de la mise à jour est illisible."))
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              !isNewer(version, than: r.version), !isNewer(r.version, than: version) else {   // 1.1 = 1.1.0
            throw ImportError(message: L("L'archive ne contient pas la version attendue de Prisme."))
        }
        return app
    }

    /// Script run after Prisme quits: swap the bundles (old one to the Trash), clear quarantine, relaunch.
    nonisolated static func swapScript(pid: Int32, current: URL, new: URL, relaunch: Bool = true, trash: Bool = true) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Prisme-previous-\(UUID().uuidString).app")
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        mv \(q(current.path)) \(q(backup.path)) || exit 1
        if mv \(q(new.path)) \(q(current.path)); then
          xattr -dr com.apple.quarantine \(q(current.path)) 2>/dev/null
          \(trash ? "osascript -e 'on run argv' -e 'tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)' -e 'end run' \(q(backup.path)) >/dev/null 2>&1 || " : "")rm -rf \(q(backup.path))
        else
          mv \(q(backup.path)) \(q(current.path))
        fi
        \(relaunch ? "open \(q(current.path))" : "")
        """
    }

    nonisolated static func replaceAndRelaunch(current: URL, with new: URL) throws {
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw ImportError(message: L("Impossible de remplacer Prisme dans %@ (droits insuffisants).", current.deletingLastPathComponent().path))
        }
        let script = new.deletingLastPathComponent().appendingPathComponent("install.sh")
        try swapScript(pid: ProcessInfo.processInfo.processIdentifier, current: current, new: new).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
    }
}

/// Reports download progress (0…1).
final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
    }
}

// MARK: - Views

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.phase {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text(L("Recherche de mises à jour…")) }
            case .upToDate:
                Text(L("Prisme est à jour")).font(.title3.weight(.semibold))
                Text(L("Vous utilisez la dernière version (%@).", Updater.currentVersion)).foregroundStyle(.secondary)
                buttons { Button("OK") { close() }.keyboardShortcut(.defaultAction) }
            case .available(let r):
                Text(L("Prisme %@ est disponible", r.version)).font(.title3.weight(.semibold))
                Text(L("Vous avez la version %@.", Updater.currentVersion)).foregroundStyle(.secondary)
                ScrollView {
                    Text(LocalizedStringKey(r.notes)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                buttons {
                    Button(L("Ignorer cette version")) { updater.skip(r) }
                    Button(L("Plus tard")) { close() }.keyboardShortcut(.cancelAction)
                    Button(L("Installer et relancer")) { Task { await updater.install(r) } }.keyboardShortcut(.defaultAction)
                }
            case .downloading(let f):
                Text(L("Téléchargement de la mise à jour…"))
                ProgressView(value: f)
            case .installing:
                HStack { ProgressView().controlSize(.small); Text(L("Installation…")) }
            case .failed(let msg):
                Text(L("La mise à jour n'a pas pu être installée")).font(.title3.weight(.semibold))
                Text(msg).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                buttons {
                    Button(L("Voir les versions sur GitHub")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/releases/latest")!)
                    }
                    Button("OK") { close() }.keyboardShortcut(.defaultAction)
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func buttons<B: View>(@ViewBuilder _ b: () -> B) -> some View {
        HStack { Spacer(); b() }
    }

    private func close() {
        updater.showSheet = false
        updater.phase = .idle
        dismiss()
    }
}
