import Foundation
import SQLite3
import CryptoKit
import CommonCrypto

// MARK: - Source description

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case file, sqlite, postgres, mysql, web
    var id: String { rawValue }

    var label: String {
        switch self {
        case .file: L("Fichier (CSV, Excel, JSON)")
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .web: L("Web / API (JSON)")
        }
    }
}

extension DataSource {
    var sourceKind: SourceKind { kind ?? .file }

    /// Keychain account holding the password (databases) or the HTTP header value (web).
    var secretAccount: String {
        switch sourceKind {
        case .web: "web:\(url ?? "")"
        default: "db:\(sourceKind.rawValue)://\(user ?? "")@\(host ?? ""):\(port ?? 0)/\(database ?? "")"
        }
    }

    var displayName: String {
        switch sourceKind {
        case .file: return URL(fileURLWithPath: path).lastPathComponent + (sheet.map { " › \($0)" } ?? "")
        case .sqlite: return URL(fileURLWithPath: path).lastPathComponent
        case .postgres, .mysql: return "\(sourceKind.label) · \(host ?? ""):\(port ?? 0)/\(database ?? "")"
        case .web: return url ?? ""
        }
    }
}

extension Importer {
    /// Loads the table(s) described by a source. Database and web sources return one table named `name`.
    static func load(source: DataSource, name: String) throws -> [DataTable] {
        switch source.sourceKind {
        case .file:
            return try load(URL(fileURLWithPath: source.path))
        case .sqlite:
            let grid = try SQLiteReader.query(path: source.path, sql: source.query ?? "")
            return [try table(name, grid, source)]
        case .postgres:
            let pg = PostgresClient(host: source.host ?? "localhost", port: source.port ?? 5432, database: source.database ?? "",
                                    user: source.user ?? "", password: Keychain.get(source.secretAccount) ?? "", tls: source.tls ?? false)
            return [try table(name, try pg.query(source.query ?? ""), source)]
        case .mysql:
            let grid = try MySQLCLI.query(source, password: Keychain.get(source.secretAccount) ?? "")
            return [try table(name, grid, source)]
        case .web:
            guard let s = source.url, let url = URL(string: s) else { throw ImportError(message: L("Adresse web invalide.")) }
            let data = try WebReader.fetch(url, header: source.header, value: Keychain.get(source.secretAccount))
            let ext = url.pathExtension.lowercased()
            if source.sheet != nil || ["xlsx", "xlsm", "csv", "tsv"].contains(ext) {
                // A file hosted online: read it like a local file.
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prisme-web-\(UUID().uuidString).\(ext.isEmpty ? "xlsx" : ext)")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let loaded = try load(tmp)
                guard var t = loaded.first(where: { source.sheet == nil || $0.source?.sheet == source.sheet || $0.name == source.sheet }) ?? loaded.first else {
                    throw ImportError(message: L("La requête n'a renvoyé aucune donnée."))
                }
                t.name = name
                t.source = source
                return [t]
            }
            return [try table(name, try JSONReader.grid(data, path: source.jsonPath), source)]
        }
    }

    private static func table(_ name: String, _ grid: [[RawCell]], _ source: DataSource) throws -> DataTable {
        guard let t = makeTable(name: name, grid: grid, source: source) else {
            throw ImportError(message: L("La requête n'a renvoyé aucune donnée."))
        }
        return t
    }
}

// MARK: - SQLite

enum SQLiteReader {
    static func query(path: String, sql: String) throws -> [[RawCell]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ImportError(message: L("Impossible d'ouvrir la base SQLite « %@ ».", path))
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError(message: L("Erreur SQL : %@", String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        var grid: [[RawCell]] = [(0..<n).map { .text(String(cString: sqlite3_column_name(stmt, $0))) }]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ImportError(message: L("Erreur SQL : %@", String(cString: sqlite3_errmsg(db)))) }
            grid.append((0..<n).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER, SQLITE_FLOAT: return .number(sqlite3_column_double(stmt, i))
                case SQLITE_NULL: return .empty
                default:
                    guard let c = sqlite3_column_text(stmt, i) else { return .empty }
                    let s = String(cString: c)
                    return s.isEmpty ? .empty : .text(s)
                }
            })
        }
        return grid
    }

    /// Table names, to help write the query.
    static func tables(path: String) -> [String] {
        (try? query(path: path, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"))?
            .dropFirst().compactMap { if case .text(let s) = $0.first { return s }; return nil } ?? []
    }
}

// MARK: - PostgreSQL (native wire protocol v3, simple query)

/// Blocking TCP connection based on Foundation streams (supports upgrading to TLS mid-stream).
final class BlockingSocket {
    private let input: InputStream
    private let output: OutputStream

    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        var i: InputStream?, o: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &i, outputStream: &o)
        guard let i, let o else { throw ImportError(message: L("Connexion impossible à %@:%@.", host, port)) }
        input = i
        output = o
        input.open()
        output.open()
        let deadline = Date().addingTimeInterval(timeout)
        while output.streamStatus == .opening || input.streamStatus == .opening {
            if Date() > deadline { throw ImportError(message: L("Délai dépassé pour %@:%@.", host, port)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let e = output.streamError ?? input.streamError {
            throw ImportError(message: L("Connexion impossible à %@:%@ (%@).", host, port, e.localizedDescription))
        }
    }

    deinit {
        input.close()
        output.close()
    }

    func startTLS(host: String) {
        for s in [input as Stream, output as Stream] {
            s.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
            s.setProperty([kCFStreamSSLPeerName as String: host], forKey: Stream.PropertyKey(kCFStreamPropertySSLSettings as String))
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            while offset < data.count {
                let n = output.write(p.baseAddress! + offset, maxLength: data.count - offset)
                guard n > 0 else { throw ImportError(message: output.streamError?.localizedDescription ?? L("Connexion interrompue.")) }
                offset += n
            }
        }
    }

    func read(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: max(count, 1))
        while out.count < count {
            let n = input.read(&buf, maxLength: count - out.count)
            guard n > 0 else { throw ImportError(message: input.streamError?.localizedDescription ?? L("Connexion interrompue.")) }
            out.append(buf, count: n)
        }
        return out
    }
}

final class PostgresClient {
    let host: String, port: Int, database: String, user: String, password: String, tls: Bool
    private var socket: BlockingSocket?

    init(host: String, port: Int, database: String, user: String, password: String, tls: Bool) {
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.tls = tls
    }

    private func int32(_ v: Int32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private func cstr(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

    private func send(_ type: Character?, _ body: Data) throws {
        var msg = Data()
        if let type { msg.append(UInt8(type.asciiValue!)) }
        msg.append(int32(Int32(body.count + 4)))
        msg.append(body)
        try socket!.write(msg)
    }

    private func receive() throws -> (type: Character, body: Data) {
        let head = try socket!.read(5)
        let type = Character(UnicodeScalar(head[0]))
        let len = Int(head[1...4].reduce(0) { $0 << 8 | UInt32($1) }) - 4
        return (type, len > 0 ? try socket!.read(len) : Data())
    }

    private func errorText(_ body: Data) -> String {
        var fields: [UInt8: String] = [:]
        var i = 0
        let bytes = [UInt8](body)
        while i < bytes.count, bytes[i] != 0 {
            let code = bytes[i]
            i += 1
            var s = [UInt8]()
            while i < bytes.count, bytes[i] != 0 { s.append(bytes[i]); i += 1 }
            i += 1
            fields[code] = String(decoding: s, as: UTF8.self)
        }
        return fields[UInt8(ascii: "M")] ?? L("Erreur PostgreSQL")
    }

    func query(_ sql: String) throws -> [[RawCell]] {
        socket = try BlockingSocket(host: host, port: port)
        defer { try? send("X", Data()); socket = nil }
        if tls {
            try socket!.write(int32(8) + int32(80_877_103))
            let answer = try socket!.read(1)
            guard answer.first == UInt8(ascii: "S") else { throw ImportError(message: L("Le serveur refuse les connexions chiffrées (TLS).")) }
            socket!.startTLS(host: host)
        }
        var startup = int32(196_608)
        startup += cstr("user") + cstr(user) + cstr("database") + cstr(database) + cstr("client_encoding") + cstr("UTF8") + Data([0])
        try send(nil, startup)
        try authenticate()

        var grid: [[RawCell]] = []
        var types: [Int32] = []
        var sent = false
        while true {
            let (t, body) = try receive()
            let b = [UInt8](body)
            func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1]))) }
            func i32(_ o: Int) -> Int32 { Int32(bitPattern: b[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) }) }
            switch t {
            case "Z":
                if sent { return grid }
                try send("Q", cstr(sql))
                sent = true
            case "E":
                throw ImportError(message: L("PostgreSQL : %@", errorText(body)))
            case "T":
                let n = i16(0)
                var o = 2
                var names: [RawCell] = []
                types = []
                for _ in 0..<n {
                    var s = [UInt8]()
                    while b[o] != 0 { s.append(b[o]); o += 1 }
                    o += 1
                    names.append(.text(String(decoding: s, as: UTF8.self)))
                    types.append(i32(o + 6))
                    o += 18
                }
                grid = [names]
            case "D":
                let n = i16(0)
                var o = 2
                var row: [RawCell] = []
                for c in 0..<n {
                    let len = Int(i32(o))
                    o += 4
                    if len < 0 { row.append(.empty); continue }
                    let s = String(decoding: b[o..<o + len], as: UTF8.self)
                    o += len
                    row.append(Self.cell(s, type: c < types.count ? types[c] : 25))
                }
                grid.append(row)
            default:
                continue   // CommandComplete, NoticeResponse, ParameterStatus…
            }
        }
    }

    private static let numericTypes: Set<Int32> = [20, 21, 23, 26, 700, 701, 790, 1700]
    private static let dateTypes: Set<Int32> = [1082, 1114, 1184]

    static func cell(_ s: String, type: Int32) -> RawCell {
        if numericTypes.contains(type), let d = Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) {
            return .number(d)
        }
        if dateTypes.contains(type) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = s.count >= 19 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
            if let d = f.date(from: String(s.prefix(19))) { return .date(d) }
        }
        return s.isEmpty ? .empty : .text(s)
    }

    private func authenticate() throws {
        var nonce = "", clientFirstBare = ""
        var serverSignature = Data()
        while true {
            let (t, body) = try receive()
            if t == "E" { throw ImportError(message: L("PostgreSQL : %@", errorText(body))) }
            guard t == "R" else { if t == "Z" || t == "S" || t == "K" { continue }; continue }
            let code = body.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            switch code {
            case 0:
                return
            case 3:
                try send("p", cstr(password))
            case 5:
                let salt = body.dropFirst(4).prefix(4)
                func md5hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }
                let inner = md5hex(Data((password + user).utf8))
                try send("p", cstr("md5" + md5hex(Data(inner.utf8) + salt)))
            case 10:
                let mechanisms = String(decoding: body.dropFirst(4), as: UTF8.self)
                guard mechanisms.contains("SCRAM-SHA-256") else { throw ImportError(message: L("Méthode d'authentification non prise en charge.")) }
                nonce = PowerBIAuth.randomURLSafeString(bytes: 18)
                clientFirstBare = "n=,r=\(nonce)"
                let first = Data("n,,\(clientFirstBare)".utf8)
                try send("p", cstr("SCRAM-SHA-256") + int32(Int32(first.count)) + first)
            case 11:
                let serverFirst = String(decoding: body.dropFirst(4), as: UTF8.self)
                var attrs: [String: String] = [:]
                for part in serverFirst.split(separator: ",") {
                    let kv = part.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { attrs[String(kv[0])] = String(kv[1]) }
                }
                guard let r = attrs["r"], r.hasPrefix(nonce), let s = attrs["s"], let salt = Data(base64Encoded: s),
                      let iterations = attrs["i"].flatMap(Int.init) else {
                    throw ImportError(message: L("Réponse d'authentification invalide."))
                }
                let scram = Self.scramFinal(password: password, clientFirstBare: clientFirstBare, serverFirst: serverFirst,
                                            serverNonce: r, salt: salt, iterations: iterations)
                serverSignature = scram.serverSignature
                try send("p", Data(scram.message.utf8))
            case 12:
                let final = String(decoding: body.dropFirst(4), as: UTF8.self)
                guard final.hasPrefix("v="), Data(base64Encoded: String(final.dropFirst(2))) == serverSignature else {
                    throw ImportError(message: L("Le serveur n'a pas pu être authentifié."))
                }
            default:
                throw ImportError(message: L("Méthode d'authentification non prise en charge."))
            }
        }
    }

    /// SCRAM-SHA-256 client-final message (RFC 5802 / 7677) and the expected server signature.
    static func scramFinal(password: String, clientFirstBare: String, serverFirst: String, serverNonce: String,
                           salt: Data, iterations: Int) -> (message: String, serverSignature: Data) {
        let salted = pbkdf2(password, salt: salt, rounds: iterations)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: SymmetricKey(data: salted)))
        let storedKey = Data(SHA256.hash(data: clientKey))
        let finalBare = "c=biws,r=\(serverNonce)"
        let authMessage = Data("\(clientFirstBare),\(serverFirst),\(finalBare)".utf8)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: SymmetricKey(data: storedKey)))
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        let serverKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: SymmetricKey(data: salted)))
        let serverSignature = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: SymmetricKey(data: serverKey)))
        return ("\(finalBare),p=\(proof.base64EncodedString())", serverSignature)
    }

    static func pbkdf2(_ password: String, salt: Data, rounds: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, 32)
        }
        return Data(out)
    }
}

// MARK: - MySQL (through the mysql command-line client)

enum MySQLCLI {
    static let candidates = ["/opt/homebrew/bin/mysql", "/opt/homebrew/opt/mysql-client/bin/mysql",
                             "/usr/local/bin/mysql", "/usr/local/mysql/bin/mysql", "/opt/homebrew/opt/mariadb/bin/mariadb"]

    static var executable: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func query(_ s: DataSource, password: String) throws -> [[RawCell]] {
        guard let exe = executable else {
            throw ImportError(message: L("Client mysql introuvable. Installez-le avec Homebrew : brew install mysql-client"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--host=\(s.host ?? "localhost")", "--port=\(s.port ?? 3306)", "--user=\(s.user ?? "")",
                       "--database=\(s.database ?? "")", "--batch", "--raw", "--execute=\(s.query ?? "")"]
            + ((s.tls ?? false) ? ["--ssl-mode=REQUIRED"] : [])
        var env = ProcessInfo.processInfo.environment
        env["MYSQL_PWD"] = password
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ImportError(message: L("MySQL : %@", msg.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { f in
                f == "NULL" || f.isEmpty ? .empty : .text(String(f))
            }
        }
    }
}

// MARK: - Web / JSON

enum WebReader {
    static func fetch(_ url: URL, header: String?, value: String?) throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let h = header, !h.isEmpty, let v = value { req.setValue(v, forHTTPHeaderField: h) }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(ImportError(message: L("Aucune réponse.")))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(ImportError(message: L("Le serveur a répondu %@.", http.statusCode)))
            } else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}

enum JSONReader {
    /// Turns JSON into a grid: an array of objects (nested objects become "a.b" columns), found at `path`
    /// ("data.items") or, by default, at the top level or in the first array-valued key.
    static func grid(_ data: Data, path: String?) throws -> [[RawCell]] {
        guard var node = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ImportError(message: L("Le contenu n'est pas du JSON valide."))
        }
        if let path, !path.isEmpty {
            for key in path.split(separator: ".") {
                if let d = node as? [String: Any], let v = d[String(key)] { node = v }
                else if let a = node as? [Any], let i = Int(key), i < a.count { node = a[i] }
                else { throw ImportError(message: L("Chemin JSON introuvable : %@", path)) }
            }
        }
        if let d = node as? [String: Any] {
            let preferred = ["data", "items", "results", "value", "records", "rows"]
            if let k = preferred.first(where: { d[$0] is [Any] }) ?? d.keys.sorted().first(where: { d[$0] is [Any] }) {
                node = d[k]!
            } else {
                node = [d]
            }
        }
        guard let array = node as? [Any] else { throw ImportError(message: L("Aucun tableau trouvé dans le JSON.")) }
        var columns: [String] = []
        var rows: [[String: RawCell]] = []
        for item in array {
            var flat: [String: RawCell] = [:]
            if let obj = item as? [String: Any] { flatten(obj, prefix: "", into: &flat, columns: &columns) }
            else { flat["Value"] = cell(item); if !columns.contains("Value") { columns.append("Value") } }
            rows.append(flat)
        }
        return [columns.map { .text($0) }] + rows.map { r in columns.map { r[$0] ?? .empty } }
    }

    private static func flatten(_ obj: [String: Any], prefix: String, into out: inout [String: RawCell], columns: inout [String], depth: Int = 0) {
        for key in obj.keys.sorted() {
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = obj[key] as? [String: Any], depth < 3 {
                flatten(nested, prefix: name, into: &out, columns: &columns, depth: depth + 1)
            } else {
                if !columns.contains(name) { columns.append(name) }
                out[name] = cell(obj[key]!)
            }
        }
    }

    private static func cell(_ v: Any) -> RawCell {
        switch v {
        case is NSNull: return .empty
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .text(n.boolValue ? "TRUE" : "FALSE") }
            return .number(n.doubleValue)
        case let s as String: return s.isEmpty ? .empty : .text(s)
        default:
            let d = (try? JSONSerialization.data(withJSONObject: v)) ?? Data()
            return .text(String(decoding: d, as: UTF8.self))
        }
    }
}
