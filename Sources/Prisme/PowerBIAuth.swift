import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
import Security

/// Microsoft Entra ID sign-in for the Power BI service: OAuth 2.0 authorization code flow with PKCE
/// (public client, no secret). The refresh token is kept in the Keychain; access tokens stay in memory.
final class PowerBIAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "prisme://auth"
    static let callbackScheme = "prisme"
    static let scopes = [
        "openid", "profile", "offline_access",
        "https://analysis.windows.net/powerbi/api/Report.Read.All",
        "https://analysis.windows.net/powerbi/api/Workspace.Read.All",
        "https://analysis.windows.net/powerbi/api/App.Read.All",
        "https://analysis.windows.net/powerbi/api/Dataset.Read.All",
    ].joined(separator: " ")

    struct Tokens {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String?
        var userName: String?
    }

    private var session: ASWebAuthenticationSession?

    // MARK: Sign-in

    @MainActor
    func signIn(clientID: String, tenant: String) async throws -> Tokens {
        let verifier = Self.randomURLSafeString(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(bytes: 16)

        var comps = URLComponents(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? PowerBIError.message("Connexion annulée.")) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: PowerBIError.message("Impossible d'ouvrir la fenêtre de connexion.")) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let err = item("error") {
            throw PowerBIError.message(item("error_description")?.replacingOccurrences(of: "+", with: " ") ?? err)
        }
        guard item("state") == state, let code = item("code") else {
            throw PowerBIError.message("Réponse de connexion invalide.")
        }
        return try await requestToken(tenant: tenant, form: [
            "client_id": clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": Self.redirectURI, "code_verifier": verifier, "scope": Self.scopes,
        ])
    }

    func refresh(clientID: String, tenant: String, refreshToken: String) async throws -> Tokens {
        try await requestToken(tenant: tenant, form: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken, "scope": Self.scopes,
        ])
    }

    private func requestToken(tenant: String, form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            let desc = (json["error_description"] as? String)?.components(separatedBy: "\r\n").first
            throw PowerBIError.message(desc ?? "Échec de l'obtention du jeton Microsoft.")
        }
        let expires = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return Tokens(accessToken: access, expiresAt: Date().addingTimeInterval(expires - 120),
                      refreshToken: json["refresh_token"] as? String,
                      userName: (json["id_token"] as? String).flatMap(Self.userName(fromIDToken:)))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }

    // MARK: Helpers

    static func userName(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (claims["name"] as? String) ?? (claims["preferred_username"] as? String)
    }

    static func randomURLSafeString(bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64URL(Data(b))
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum PowerBIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Minimal Keychain storage for the refresh token.
enum Keychain {
    private static let service = "local.prisme.powerbi"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
