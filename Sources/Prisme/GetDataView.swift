import SwiftUI
import UniformTypeIdentifiers

/// "Get data" sheet: files, SQLite, PostgreSQL, MySQL and web (JSON) sources.
struct GetDataView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .file
    @State private var name = ""
    @State private var path = ""
    @State private var host = "localhost"
    @State private var port = ""
    @State private var database = ""
    @State private var user = ""
    @State private var password = ""
    @State private var tls = false
    @State private var query = ""
    @State private var url = ""
    @State private var header = ""
    @State private var headerValue = ""
    @State private var jsonPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Obtenir des données")).font(.title3.weight(.semibold))
            Picker("", selection: $kind) {
                ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch kind {
                case .file:
                    Text(L("Fichiers CSV, TSV, Excel (.xlsx) ou JSON. Vous pouvez aussi les glisser sur la page."))
                        .foregroundStyle(.secondary)
                case .sqlite:
                    HStack {
                        TextField(L("Fichier de base"), text: $path)
                        Button(L("Choisir…")) { chooseSQLite() }
                    }
                    if !path.isEmpty {
                        let tables = SQLiteReader.tables(path: path)
                        if !tables.isEmpty {
                            Picker(L("Table"), selection: Binding(get: { "" }, set: { t in
                                query = "SELECT * FROM \"\(t)\""
                                if name.isEmpty { name = t }
                            })) {
                                Text("—").tag("")
                                ForEach(tables, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    queryField
                case .postgres, .mysql:
                    TextField(L("Serveur"), text: $host)
                    TextField(L("Port"), text: $port, prompt: Text(kind == .postgres ? "5432" : "3306"))
                    TextField(L("Base de données"), text: $database)
                    TextField(L("Utilisateur"), text: $user)
                    SecureField(L("Mot de passe"), text: $password)
                    Toggle(L("Connexion chiffrée (TLS)"), isOn: $tls)
                    queryField
                    if kind == .mysql && MySQLCLI.executable == nil {
                        Text(L("Client mysql introuvable. Installez-le avec Homebrew : brew install mysql-client"))
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                case .web:
                    TextField(L("Adresse (URL)"), text: $url, prompt: Text("https://api.example.com/data"))
                    TextField(L("En-tête (facultatif)"), text: $header, prompt: Text("Authorization"))
                    if !header.isEmpty { SecureField(L("Valeur de l'en-tête"), text: $headerValue) }
                    TextField(L("Chemin dans le JSON (facultatif)"), text: $jsonPath, prompt: Text("data.items"))
                }
                if kind != .file {
                    TextField(L("Nom de la table"), text: $name)
                }
            }
            Text(L("Les mots de passe et jetons sont enregistrés dans le trousseau macOS, jamais dans le rapport."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button(L("Annuler"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .file ? L("Choisir des fichiers…") : L("Importer")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || state.isImporting)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var queryField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Requête SQL")).font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $query)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
        }
    }

    private var canSubmit: Bool {
        switch kind {
        case .file: true
        case .sqlite: !path.isEmpty && !query.isEmpty
        case .postgres, .mysql: !host.isEmpty && !database.isEmpty && !user.isEmpty && !query.isEmpty
        case .web: URL(string: url)?.scheme?.hasPrefix("http") == true
        }
    }

    private func chooseSQLite() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sqlite", "sqlite3", "db"].compactMap { UTType(filenameExtension: $0) } + [.data]
        if panel.runModal() == .OK, let u = panel.url { path = u.path }
    }

    private func submit() {
        var s = DataSource(kind: kind)
        switch kind {
        case .file:
            dismiss()
            state.importWithPanel()
            return
        case .sqlite:
            s.path = path
            s.query = query
        case .postgres, .mysql:
            s.host = host
            s.port = Int(port) ?? (kind == .postgres ? 5432 : 3306)
            s.database = database
            s.user = user
            s.tls = tls
            s.query = query
        case .web:
            s.url = url
            s.header = header.isEmpty ? nil : header
            s.jsonPath = jsonPath.isEmpty ? nil : jsonPath
        }
        state.importSource(s, name: name, secret: kind == .web ? headerValue : password)
    }
}
