import Foundation

public struct VPNProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var connectionName: String
    public var server: String
    public var username: String
    public var group: String
    public var usesRealm: Bool
    public var favorite: Bool

    public init(id: UUID = UUID(), name: String = "", connectionName: String = "",
                server: String = "", username: String = "", group: String = "",
                usesRealm: Bool = false, favorite: Bool = false) {
        self.id = id
        self.name = name
        self.connectionName = connectionName
        self.server = server
        self.username = username
        self.group = group
        self.usesRealm = usesRealm
        self.favorite = favorite
    }

    public func validated(existingNames: [String]) throws -> VPNProfile {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.connectionName = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, !result.connectionName.isEmpty else {
            throw VPNError.message("Indique un nom et le nom du profil SonicWall.")
        }
        guard existingNames.filter({ $0 == result.connectionName }).count <= 1 else {
            throw VPNError.message("Plusieurs profils SonicWall portent ce nom. Renomme-les dans Mobile Connect.")
        }
        if result.server.isEmpty {
            guard existingNames.contains(result.connectionName) else {
                throw VPNError.message("Ce profil n’existe pas dans SonicWall. Indique son serveur (ex. vpn.exemple.fr:4433).")
            }
        } else {
            let address = result.server.contains("://") ? result.server : "https://" + result.server
            guard let c = URLComponents(string: address), c.scheme == "https",
                  let host = c.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
                  c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
                  c.path.isEmpty || c.path == "/", c.port.map({ (1...65535).contains($0) }) ?? true else {
                throw VPNError.message("Serveur invalide. Utilise un nom d’hôte ou une IP, avec un port facultatif, sans chemin ni identifiants.")
            }
            result.server = String(address.dropFirst("https://".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return result
    }
}

public enum VPNError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

public enum SonicURL {
    // Encode every value separately, including '+' and '%' in passwords. Never log this URL.
    public static func connect(profile: VPNProfile, password: String?) throws -> URL {
        var items = [("name", profile.connectionName)]
        if !profile.server.isEmpty { items.append(("server", profile.server)) }
        if !profile.username.isEmpty { items.append(("username", profile.username)) }
        if !profile.group.isEmpty { items.append((profile.usesRealm ? "realm" : "domain", profile.group)) }
        if let password, !password.isEmpty { items.append(("password", password)) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let query = items.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        guard let url = URL(string: "sonicwallmobileconnect://connect/?" + query) else {
            throw VPNError.message("Impossible de préparer la connexion SonicWall.")
        }
        return url
    }
}
