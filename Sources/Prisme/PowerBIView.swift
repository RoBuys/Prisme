import SwiftUI
import WebKit

/// "Power BI" view: browse and display reports shared with you in the Power BI service.
struct PowerBIView: View {
    @State private var store = PowerBIStore.shared
    @State private var link = ""
    @State private var search = ""
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 290)
            Divider()
            content
        }
        .sheet(isPresented: $showSettings) { PowerBISettings(store: store) }
        .onAppear { if store.isSignedIn && store.myReports.isEmpty && store.workspaces.isEmpty { Task { await store.refreshCatalog() } } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PaneHeader(title: "Power BI")
                if store.isBusy { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12).help("Réglages Power BI")
            }
            VStack(alignment: .leading, spacing: 8) {
                if !store.isConfigured {
                    Text("Pour accéder à vos rapports, Prisme a besoin de l'identifiant d'une application enregistrée dans Microsoft Entra ID.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Configurer…") { showSettings = true }.buttonStyle(.borderedProminent)
                } else if !store.isSignedIn {
                    Button {
                        Task { await store.signIn() }
                    } label: {
                        Label("Se connecter avec Microsoft", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                        Text(store.userName ?? "Connecté").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Menu {
                            Button("Actualiser la liste") { Task { await store.refreshCatalog() } }
                            Button("Se déconnecter") { store.signOut() }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    TextField("Coller un lien de rapport…", text: $link)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit { Task { await store.openLink(link) } }
                    Button { Task { await store.openLink(link) } } label: { Image(systemName: "arrow.right.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(link.isEmpty)
                }
                if let e = store.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if store.isSignedIn {
                TextField("Rechercher un rapport", text: $search)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(.horizontal, 12)
                List {
                    Section("Mon espace et partagés avec moi") {
                        ForEach(filtered(store.myReports)) { reportRow($0) }
                        if store.myReports.isEmpty { Text("Aucun rapport").foregroundStyle(.secondary).font(.system(size: 11)) }
                    }
                    if !store.workspaces.isEmpty {
                        Section("Espaces de travail") {
                            ForEach(store.workspaces) { w in
                                DisclosureGroup {
                                    ForEach(filtered(store.workspaceReports[w.id] ?? [])) { reportRow($0) }
                                } label: {
                                    Label(w.name, systemImage: "square.stack.3d.up").font(.system(size: 12)).lineLimit(1)
                                }
                                .onAppear { if !search.isEmpty { Task { await store.loadReports(workspace: w) } } }
                                .simultaneousGesture(TapGesture().onEnded { Task { await store.loadReports(workspace: w) } })
                            }
                        }
                    }
                    if !store.apps.isEmpty {
                        Section("Applications") {
                            ForEach(store.apps) { a in
                                DisclosureGroup {
                                    ForEach(filtered(store.appReports[a.id] ?? [])) { reportRow($0) }
                                } label: {
                                    Label(a.name, systemImage: "app.badge").font(.system(size: 12)).lineLimit(1)
                                }
                                .simultaneousGesture(TapGesture().onEnded { Task { await store.loadReports(app: a) } })
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                Spacer()
                Text("Les liens « Publier sur le web » s'ouvrent sans connexion.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(12)
            }
        }
        .background(.background)
    }

    private func filtered(_ reports: [PBIReport]) -> [PBIReport] {
        search.isEmpty ? reports : reports.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func reportRow(_ r: PBIReport) -> some View {
        let active: Bool = { if case .report(let id, _, _) = store.content { return id == r.id }; return false }()
        return HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(active ? Theme.accent : .secondary)
            Text(r.name).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.open(r) }
        .contextMenu {
            if let w = r.webUrl, let u = URL(string: w) { Button("Ouvrir dans le navigateur") { NSWorkspace.shared.open(u) } }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let c = store.content {
            PowerBIEmbedView(content: c, store: store).id(contentKey(c))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text("Rapports Power BI").font(.title3.weight(.semibold))
                Text("Choisissez un rapport dans la liste, ou collez un lien copié depuis app.powerbi.com.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func contentKey(_ c: PBIContent) -> String {
        switch c {
        case .report(let id, _, _): id
        case .publicPage(let u): u.absoluteString
        }
    }
}

// MARK: - Settings

struct PowerBISettings: View {
    @Bindable var store: PowerBIStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Réglages Power BI").font(.title3.weight(.semibold))
            Text("Enregistrez une application dans Microsoft Entra ID (type « Client public / natif », URI de redirection « \(PowerBIAuth.redirectURI) », autorisations déléguées Power BI Service : Report.Read.All, Workspace.Read.All, App.Read.All, Dataset.Read.All), puis collez ici son identifiant. La procédure détaillée est dans le README.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("ID d'application (client)", text: $store.clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                TextField("Locataire (tenant)", text: $store.tenant, prompt: Text("organizations"))
            }
            Text("Locataire : laissez « organizations » ou indiquez l'ID de répertoire (tenant ID) ou le domaine de votre organisation.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if !store.clientID.isEmpty && !store.isConfigured {
                Text("L'identifiant doit être un GUID.").font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Link("Ouvrir le portail Entra", destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                Spacer()
                Button("Terminé") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Embedded report (WKWebView + powerbi-client)

struct PowerBIEmbedView: NSViewRepresentable {
    let content: PBIContent
    let store: PowerBIStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "prisme")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        switch content {
        case .publicPage(let url):
            web.load(URLRequest(url: url))
        case .report(let id, _, let embedUrl):
            context.coordinator.pending = (id, embedUrl)
            web.loadHTMLString(Self.html, baseURL: URL(string: "https://prisme.local/"))
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "prisme")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let store: PowerBIStore
        weak var web: WKWebView?
        var pending: (id: String, embedUrl: String)?
        var timer: Timer?

        init(store: PowerBIStore) { self.store = store }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let p = pending else { return }
            pending = nil
            Task { @MainActor in
                do {
                    let token = try await store.token()
                    let args = try JSONSerialization.data(withJSONObject: ["id": p.id, "embedUrl": p.embedUrl, "token": token])
                    _ = try? await webView.evaluateJavaScript("embedReport(\(String(data: args, encoding: .utf8)!))")
                    startTokenRefresh()
                } catch {
                    store.error = error.localizedDescription
                }
            }
        }

        /// Entra tokens last about an hour: hand the report a fresh one regularly.
        private func startTokenRefresh() {
            timer = Timer.scheduledTimer(withTimeInterval: 45 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let t = try? await self.store.token(),
                          let s = try? JSONSerialization.data(withJSONObject: [t]),
                          let json = String(data: s, encoding: .utf8) else { return }
                    _ = try? await self.web?.evaluateJavaScript("updateToken(\(json)[0])")
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "error" {
                let detail = (body["message"] as? String) ?? "Erreur inconnue"
                Task { @MainActor in self.store.error = "Rapport : \(detail)" }
            }
        }

        // Links inside the report open in the default browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, action.targetFrame?.isMainFrame != false {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style>html,body,#report{margin:0;height:100%;width:100%;background:#f3f3f3}#report iframe{border:0}</style>
    <script src="https://cdn.jsdelivr.net/npm/powerbi-client@2.25.0/dist/powerbi.min.js"
      integrity="sha384-SrjLlpANfs97fxkXskhuVvaqQxGMLks+Gsp3CFR5s44ctRosSm7lCDqh24rhaNsp" crossorigin="anonymous"></script>
    </head><body><div id="report"></div>
    <script>
    let report = null;
    function post(m) { window.webkit.messageHandlers.prisme.postMessage(m); }
    function embedReport(p) {
      if (!window['powerbi-client']) { post({type: 'error', message: 'bibliothèque Power BI non chargée (connexion Internet ?)'}); return; }
      const models = window['powerbi-client'].models;
      report = powerbi.embed(document.getElementById('report'), {
        type: 'report', id: p.id, embedUrl: p.embedUrl, accessToken: p.token,
        tokenType: models.TokenType.Aad, permissions: models.Permissions.Read, viewMode: models.ViewMode.View,
        settings: { panes: { filters: { expanded: false, visible: true }, pageNavigation: { visible: true } } }
      });
      report.on('error', e => post({type: 'error', message: (e.detail && (e.detail.detailedMessage || e.detail.message)) || 'erreur'}));
      report.on('loaded', () => post({type: 'loaded'}));
    }
    function updateToken(t) { if (report) report.setAccessToken(t); }
    </script></body></html>
    """
}
