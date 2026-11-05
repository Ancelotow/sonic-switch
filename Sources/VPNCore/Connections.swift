import Foundation

public struct VPNService: Equatable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public var isConnected: Bool { state == "Connected" }
    public var isInactive: Bool { state == "Disconnected" }
    public var stateLabel: String {
        switch state {
        case "Connected": return "Connecté"
        case "Disconnected": return "Déconnecté"
        case "Connecting": return "Connexion…"
        case "Disconnecting": return "Déconnexion…"
        default: return "État inconnu"
        }
    }
    public init(id: String, name: String, state: String) {
        self.id = id; self.name = name; self.state = state
    }

    public static func parseList(_ output: String) throws -> [VPNService] {
        guard output.contains("Available network connection services") else {
            throw VPNError.message("macOS ne permet pas de lire l’état des VPN.")
        }
        let pattern = #"^\s*\*?\s*\(([^)]+)\)\s+([A-Fa-f0-9-]{36})\s+VPN\s+\(com\.sonicwall\.[^)]+\)\s+\"(.*)\"\s+\[VPN:"#
        let regex = try NSRegularExpression(pattern: pattern)
        return try output.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("[VPN:com.sonicwall.") else { return nil }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                throw VPNError.message("Le format de l’état SonicWall n’est pas reconnu. Aucun basculement effectué.")
            }
            func value(_ n: Int) -> String { String(line[Range(match.range(at: n), in: line)!]) }
            return VPNService(id: value(2), name: value(3), state: value(1))
        }
    }
}

public protocol VPNTransport: Sendable {
    func services() async throws -> [VPNService]
    func stop(id: String) async throws
    func openConnection(_ url: URL) async throws
    func ensureClientAvailable() async throws
    func checkConnectionResponse() async throws
    func connectionDefaults(id: String) async throws -> ConnectionDefaults
    func finishConnectionAttempt() async
}

public extension VPNTransport {
    func checkConnectionResponse() async throws { }
    func connectionDefaults(id: String) async throws -> ConnectionDefaults { ConnectionDefaults() }
    func finishConnectionAttempt() async { }
}

public enum ConnectionStage: Sendable {
    case disconnecting, launching, waitingForClient, connecting
}

public actor VPNConnector {
    private let transport: any VPNTransport
    private let disconnectTimeout: Duration
    private let connectionTimeout: Duration
    private let pollInterval: Duration
    private let startupTimeout: Duration
    private var busy = false

    public init(transport: any VPNTransport, disconnectTimeout: Duration = .seconds(20),
                connectionTimeout: Duration = .seconds(120), pollInterval: Duration = .seconds(1),
                startupTimeout: Duration = .seconds(20)) {
        self.transport = transport
        self.disconnectTimeout = disconnectTimeout
        self.connectionTimeout = connectionTimeout
        self.pollInterval = pollInterval
        self.startupTimeout = startupTimeout
    }

    public func connect(profile: VPNProfile, password: String?,
                        progress: @Sendable (ConnectionStage) async -> Void = { _ in }) async throws {
        guard !busy else { throw VPNError.message("Une opération VPN est déjà en cours.") }
        busy = true
        defer { busy = false }
        do {
            try await performConnect(profile: profile, password: password, progress: progress)
            await transport.finishConnectionAttempt()
        } catch {
            await transport.finishConnectionAttempt()
            throw error
        }
    }

    private func performConnect(profile: VPNProfile, password: String?,
                                progress: @Sendable (ConnectionStage) async -> Void) async throws {
        try Task.checkCancellation()
        try await transport.ensureClientAvailable()
        let services = try await transport.services()
        var profile = try profile.validated(existingNames: services.map(\.name))
        if services.contains(where: { $0.name == profile.connectionName && $0.isConnected }) { return }
        if let password, !password.isEmpty {
            if let service = services.first(where: { $0.name == profile.connectionName }),
               profile.username.isEmpty || profile.group.isEmpty || profile.server.isEmpty {
                profile = try await transport.connectionDefaults(id: service.id).fillingMissingFields(in: profile)
                profile = try profile.validated(existingNames: services.map(\.name))
            }
            guard !profile.username.isEmpty else {
                throw VPNError.message("Renseigne l’utilisateur dans ce profil pour que Mobile Connect puisse utiliser le mot de passe enregistré.")
            }
        }
        let url = try SonicURL.connect(profile: profile, password: password)
        await progress(.disconnecting)
        try await stopAndWait(services)
        try Task.checkCancellation()
        // Recheck immediately before opening: an external client may have reconnected.
        guard try await transport.services().allSatisfy(\.isInactive) else {
            throw VPNError.message("Un VPN SonicWall s’est reconnecté. Vérifie la reconnexion automatique dans Mobile Connect.")
        }
        await progress(.launching)
        try await transport.openConnection(url)
        await progress(.waitingForClient)
        let clock = ContinuousClock()
        let deadline = clock.now + connectionTimeout
        let startupDeadline = clock.now + startupTimeout
        var started = false
        while clock.now < deadline {
            try Task.checkCancellation()
            let current = try await transport.services()
            if current.contains(where: { $0.name == profile.connectionName && $0.isConnected }) { return }
            try await transport.checkConnectionResponse()
            if current.contains(where: { $0.name == profile.connectionName && $0.state == "Connecting" }) {
                if !started { await progress(.connecting) }
                started = true
            }
            if started && current.allSatisfy(\.isInactive) {
                throw VPNError.message("SonicWall a interrompu la connexion. Consulte le message dans Mobile Connect : identifiants, certificat ou validation MFA.")
            }
            if !started && clock.now >= startupDeadline {
                throw VPNError.message("Mobile Connect n’a démarré aucun tunnel. Dans SonicWall Mobile Connect > Préférences, active URL Control, puis relance la connexion. Valide aussi toute fenêtre d’autorisation ou d’authentification affichée par SonicWall.")
            }
            try await Task.sleep(for: pollInterval)
        }
        throw VPNError.message("Connexion non confirmée après 2 minutes. Vérifie Mobile Connect : autorisation URL Control, identifiants, certificat ou code MFA. La tentative peut encore être en cours ; utilise Déconnecter pour l’arrêter.")
    }

    public func disconnect() async throws {
        guard !busy else { throw VPNError.message("Une opération VPN est déjà en cours.") }
        busy = true
        defer { busy = false }
        let services = try await transport.services()
        try await stopAndWait(services)
    }

    private func stopAndWait(_ services: [VPNService]) async throws {
        guard services.allSatisfy({ ["Connected", "Connecting", "Disconnecting", "Disconnected"].contains($0.state) }) else {
            throw VPNError.message("État VPN inconnu. Vérifie Mobile Connect avant de basculer.")
        }
        for service in services where !service.isInactive {
            try Task.checkCancellation()
            if service.state != "Disconnecting" { try await transport.stop(id: service.id) }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + disconnectTimeout
        while clock.now < deadline {
            try Task.checkCancellation()
            if try await transport.services().allSatisfy(\.isInactive) { return }
            try await Task.sleep(for: pollInterval)
        }
        throw VPNError.message("Le VPN précédent reste actif. Aucun autre VPN n’a été lancé. Désactive la reconnexion automatique dans Mobile Connect si nécessaire.")
    }
}
