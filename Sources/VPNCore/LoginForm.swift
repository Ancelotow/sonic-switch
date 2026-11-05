import Foundation

public struct LoginRequest: Sendable {
    public let server: String
    public let username: String
    public let password: String
    public init(server: String, username: String, password: String) {
        self.server = server; self.username = username; self.password = password
    }
}

/// A snapshot contains no secure-field values. IDs refer only to this scan.
public struct LoginControl: Sendable {
    public let id: Int
    public let role: String
    public let secure: Bool
    public let editable: Bool
    public let enabled: Bool
    public let label: String
    public let value: String
    public init(id: Int, role: String, secure: Bool = false, editable: Bool = false,
                enabled: Bool = true, label: String = "", value: String = "") {
        self.id = id; self.role = role; self.secure = secure
        self.editable = editable; self.enabled = enabled; self.label = label
        self.value = secure ? "" : value
    }
}

public struct LoginFormMatch: Equatable, Sendable {
    public let usernameID: Int
    public let passwordID: Int
    public let submitID: Int?
}

public enum LoginFormPolicy {
    public static func match(_ controls: [LoginControl], request: LoginRequest) -> LoginFormMatch? {
        guard !request.username.isEmpty, !request.password.isEmpty,
              let endpoint = endpoint(request.server) else { return nil }
        let labels = controls.map(\.label).joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let excluded = ["one-time", "one time", "verification", "otp", "passcode", "token", "2fa", "mfa", "proxy", "password change", "changer le mot de passe", "nouveau mot de passe", "new password"]
        guard !excluded.contains(where: { labels.contains($0) }) else { return nil }
        // A different server or a generic password/OTP prompt must never receive this secret.
        guard controls.contains(where: { !$0.editable && !$0.secure && endpointValue($0.value, equals: endpoint) }) else { return nil }
        let secrets = controls.filter { $0.secure && $0.editable && $0.enabled }
        guard secrets.count == 1 else { return nil }
        let textFields = controls.filter { $0.role == "AXTextField" && !$0.secure && $0.editable && $0.enabled }
        guard textFields.count == 1, let user = textFields.first else { return nil }
        let userLabel = user.label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let identifiedUsername = ["username", "user name", "utilisateur", "login", "identifiant"].contains { userLabel.contains($0) }
        guard user.value == request.username || (user.value.isEmpty && identifiedUsername) else { return nil }
        let buttons = controls.filter { $0.role == "AXButton" && $0.enabled && ["login", "log in", "connect", "connexion", "se connecter"].contains($0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        return LoginFormMatch(usernameID: user.id, passwordID: secrets[0].id,
                              submitID: buttons.count == 1 ? buttons[0].id : nil)
    }

    private static func endpoint(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let c = URLComponents(string: value.contains("://") ? value : "https://" + value),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { return nil }
        return host.lowercased() + ":" + String(c.port ?? 443)
    }

    private static func endpointValue(_ value: String, equals expected: String) -> Bool {
        // Exact address only; substring matching could confuse two gateways.
        endpoint(value) == expected
    }
}
