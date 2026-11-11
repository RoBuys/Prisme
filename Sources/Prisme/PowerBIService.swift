import Foundation
import SwiftUI

struct PBIWorkspace: Decodable, Identifiable, Hashable { let id: String; let name: String }
struct PBIApp: Decodable, Identifiable, Hashable { let id: String; let name: String }

struct PBIReport: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let embedUrl: String?
    let webUrl: String?
}

private struct ListResponse<T: Decodable>: Decodable { let value: [T] }

/// What the embed view shows: a report embedded with the user's token, or a public "Publish to web" page.
enum PBIContent: Equatable {
    case report(id: String, name: String, embedUrl: String)
    case publicPage(URL)
}

/// Power BI service state: settings, account, workspace browsing and the report being displayed.
@Observable
final class PowerBIStore {
    static let shared = PowerBIStore()

    var clientID: String { didSet { UserDefaults.standard.set(clientID, forKey: "powerbi.clientID") } }
    var tenant: String { didSet { UserDefaults.standard.set(tenant, forKey: "powerbi.tenant") } }

    var userName: String?
    var isSignedIn: Bool { refreshToken != nil || accessToken != nil }
    var isBusy = false
    var error: String?

    var myReports: [PBIReport] = []
    var workspaces: [PBIWorkspace] = []
    var apps: [PBIApp] = []
    var workspaceReports: [String: [PBIReport]] = [:]
    var appReports: [String: [PBIReport]] = [:]
    var content: PBIContent?

    private let auth = PowerBIAuth()
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshToken: String? {
        didSet { Keychain.set(refreshToken, for: "refresh_token") }
    }

    init() {
        clientID = UserDefaults.standard.string(forKey: "powerbi.clientID") ?? ""
        tenant = UserDefaults.standard.string(forKey: "powerbi.tenant") ?? "organizations"
        refreshToken = Keychain.get("refresh_token")
        userName = UserDefaults.standard.string(forKey: "powerbi.userName")
    }

    var isConfigured: Bool { UUID(uuidString: clientID.trimmingCharacters(in: .whitespaces)) != nil }
    private var tenantValue: String {
        let t = tenant.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "organizations" : t
    }

    // MARK: Account

    @MainActor
    func signIn() async {
        await run {
            let t = try await self.auth.signIn(clientID: self.clientID.trimmingCharacters(in: .whitespaces), tenant: self.tenantValue)
            self.apply(t)
            try await self.loadCatalog()
        }
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        userName = nil
        UserDefaults.standard.removeObject(forKey: "powerbi.userName")
        myReports = []; workspaces = []; apps = []; workspaceReports = [:]; appReports = [:]
        if case .report = content { content = nil }
    }

    private func apply(_ t: PowerBIAuth.Tokens) {
        accessToken = t.accessToken
        expiresAt = t.expiresAt
        if let r = t.refreshToken { refreshToken = r }
        if let n = t.userName {
            userName = n
            UserDefaults.standard.set(n, forKey: "powerbi.userName")
        }
    }

    /// A valid access token, refreshed when needed.
    func token() async throws -> String {
        if let a = accessToken, Date() < expiresAt { return a }
        guard let r = refreshToken else { throw PowerBIError.message(L("Connectez-vous à Power BI.")) }
        do {
            let t = try await auth.refresh(clientID: clientID.trimmingCharacters(in: .whitespaces), tenant: tenantValue, refreshToken: r)
            await MainActor.run { apply(t) }
            return t.accessToken
        } catch {
            await MainActor.run { signOut() }
            throw PowerBIError.message(L("Session expirée, reconnectez-vous. (%@)", error.localizedDescription))
        }
    }

    // MARK: REST API

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.powerbi.com/v1.0/myorg/" + path)!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            switch status {
            case 401: throw PowerBIError.message(L("Accès refusé par Power BI (401). Vérifiez votre licence Pro/PPU et les autorisations de l'application."))
            case 403: throw PowerBIError.message(L("Accès interdit (403) : vous n'avez pas les droits sur cet élément."))
            case 404: throw PowerBIError.message(L("Élément introuvable (404)."))
            default: throw PowerBIError.message(L("Erreur Power BI (%@).", status))
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @MainActor
    func loadCatalog() async throws {
        async let mine = get("reports", as: ListResponse<PBIReport>.self)
        async let groups = get("groups", as: ListResponse<PBIWorkspace>.self)
        async let installed = get("apps", as: ListResponse<PBIApp>.self)
        myReports = try await mine.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        workspaces = try await groups.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        apps = (try? await installed.value) ?? []
    }

    @MainActor
    func refreshCatalog() async { await run { try await self.loadCatalog() } }

    @MainActor
    func loadReports(workspace: PBIWorkspace) async {
        guard workspaceReports[workspace.id] == nil else { return }
        await run { self.workspaceReports[workspace.id] = try await self.get("groups/\(workspace.id)/reports", as: ListResponse<PBIReport>.self).value }
    }

    @MainActor
    func loadReports(app: PBIApp) async {
        guard appReports[app.id] == nil else { return }
        await run { self.appReports[app.id] = try await self.get("apps/\(app.id)/reports", as: ListResponse<PBIReport>.self).value }
    }

    @MainActor
    func open(_ r: PBIReport) {
        let url = r.embedUrl ?? "https://app.powerbi.com/reportEmbed?reportId=\(r.id)"
        content = .report(id: r.id, name: r.name, embedUrl: url)
    }

    /// Opens a link copied from the Power BI service (report, app report, or "Publish to web" link).
    @MainActor
    func openLink(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), host.hasSuffix("powerbi.com") else {
            error = L("Collez un lien app.powerbi.com.")
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.path.lowercased().hasPrefix("/view"), comps?.queryItems?.contains(where: { $0.name == "r" }) == true {
            content = .publicPage(url)   // "Publish to web": no sign-in needed
            return
        }
        let parts = url.path.split(separator: "/").map(String.init)
        func after(_ key: String) -> String? {
            guard let i = parts.firstIndex(where: { $0.lowercased() == key }), i + 1 < parts.count else { return nil }
            return parts[i + 1]
        }
        let reportID = after("reports") ?? comps?.queryItems?.first { $0.name.lowercased() == "reportid" }?.value
        guard let reportID else { error = L("Ce lien ne désigne pas un rapport."); return }
        let group = after("groups") ?? comps?.queryItems?.first { $0.name.lowercased() == "groupid" }?.value
        let app = after("apps")
        await run {
            let path: String
            if let app { path = "apps/\(app)/reports/\(reportID)" }
            else if let group, group.lowercased() != "me" { path = "groups/\(group)/reports/\(reportID)" }
            else { path = "reports/\(reportID)" }
            self.open(try await self.get(path, as: PBIReport.self))
        }
    }

    @MainActor
    private func run(_ body: @escaping () async throws -> Void) async {
        isBusy = true
        error = nil
        do { try await body() } catch { self.error = error.localizedDescription }
        isBusy = false
    }
}
