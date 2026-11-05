import AppKit
import SwiftUI
import VPNCore

@MainActor final class AppModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var services: [VPNService] = []
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var message: String?
    @Published var monitoringError: String?
    @Published var notice: String?
    @Published var ready = false
    @Published var savedPasswords: Set<UUID> = []
    @Published private(set) var copyingPassword = false
    @Published private(set) var passwordSentFor: UUID?
    private let store: ProfileStore
    private let vault: PasswordVault
    private let transport: any VPNTransport
    private let connector: VPNConnector
    private let readPassword: @Sendable (UUID) async throws -> String?
    private let clipboard: PasswordClipboard
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var refreshing = false
    private var firstScan = true
    private var requestInFlight = false
    private var disconnecting = false
    private var copyRequestInFlight = false

    var active: VPNService? { services.first { !$0.isInactive } }
    var sortedProfiles: [VPNProfile] {
        profiles.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    init(store: ProfileStore = ProfileStore(), vault: PasswordVault = PasswordVault(),
         transport: any VPNTransport = SystemTransport(), startMonitoring: Bool = true,
         readPassword: (@Sendable (UUID) async throws -> String?)? = nil,
         clipboard: PasswordClipboard? = nil) {
        self.store = store
        self.vault = vault
        self.transport = transport
        self.connector = VPNConnector(transport: transport)
        self.clipboard = clipboard ?? PasswordClipboard()
        self.readPassword = readPassword ?? { id in
            // Security can wait for a system prompt. Keep the UI's main thread free.
            try await Task.detached(priority: .userInitiated) { try vault.read(id) }.value
        }
        do {
            firstScan = !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.json").path)
            profiles = try store.load()
            savedPasswords = Set(profiles.filter { vault.contains($0.id) }.map(\.id))
            ready = true
        } catch { message = "Impossible de lire les profils. Les données existantes sont conservées. \(error.localizedDescription)" }
        selectedID = sortedProfiles.first?.id
        guard startMonitoring else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        LoginAssistant.shared.refreshPermission()
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let latest = try await transport.services()
            if services != latest { services = latest }
            if monitoringError != nil { monitoringError = nil }
            // Import only names, never inspect SonicWall's credentials or configuration files.
            if ready && firstScan {
                firstScan = false
                try importServices(services)
            }
        } catch {
            if monitoringError != error.localizedDescription { monitoringError = error.localizedDescription }
        }
    }

    func importProfiles() async {
        do { try importServices(await transport.services()) }
        catch { message = error.localizedDescription }
    }

    private func importServices(_ services: [VPNService]) throws {
        guard ready else { return }
        var updated = profiles
        for service in services where !updated.contains(where: { $0.connectionName == service.name }) {
            updated.append(VPNProfile(name: service.name, connectionName: service.name))
        }
        if updated != profiles {
            try store.save(updated)
            profiles = updated
            if selectedID == nil { selectedID = sortedProfiles.first?.id }
        }
    }

    func delete(_ profile: VPNProfile) {
        let previous = profiles
        let updated = profiles.filter { $0.id != profile.id }
        do {
            try store.save(updated)
            do { try vault.delete(profile.id) }
            catch { try store.save(previous); throw error }
            profiles = updated
            savedPasswords.remove(profile.id)
            selectedID = sortedProfiles.first?.id
        } catch { message = error.localizedDescription }
    }

    func save(_ draft: VPNProfile, password: String, forgetPassword: Bool) throws {
        let profile = try draft.validated(existingNames: services.map(\.name))
        guard !profiles.contains(where: { $0.id != profile.id && $0.connectionName == profile.connectionName }) else {
            throw VPNError.message("Ce profil SonicWall est déjà dans la liste.")
        }
        let previous = profiles
        var updated = profiles
        if let i = updated.firstIndex(where: { $0.id == profile.id }) { updated[i] = profile }
        else { updated.append(profile) }
        try store.save(updated)
        do {
            if forgetPassword { try vault.delete(profile.id) }
            else if !password.isEmpty { try vault.save(password, id: profile.id) }
        } catch {
            do { try store.save(previous) } catch {
                // Keep the UI consistent with the file if a rollback itself fails.
                profiles = updated
                throw VPNError.message("Erreur du Trousseau et de restauration des profils. Relance SonicSwitch et vérifie ce profil.")
            }
            throw error
        }
        profiles = updated
        selectedID = profile.id
        passwordSentFor = nil
        if vault.contains(profile.id) { savedPasswords.insert(profile.id) }
        else { savedPasswords.remove(profile.id) }
    }

    func connect(_ profile: VPNProfile) {
        guard !requestInFlight, !disconnecting, ready else { return }
        requestInFlight = true
        operation = Task {
            // Let menu/view callbacks finish before publishing new UI state.
            await Task.yield()
            busy = true
            message = nil
            selectedID = profile.id
            passwordSentFor = nil
            notice = "Lecture du mot de passe dans le Trousseau… Autorise l’accès si macOS le demande."
            defer { busy = false; requestInFlight = false }
            do {
                // Read before disconnecting, so a locked/refused Keychain leaves the current VPN alone.
                let password = try await readPassword(profile.id)
                if savedPasswords.contains(profile.id), password?.isEmpty != false {
                    throw VPNError.message("Le mot de passe enregistré n’a pas pu être retrouvé. Ouvre la modification du profil et enregistre-le à nouveau.")
                }
                try Task.checkCancellation()
                let hasPassword = password?.isEmpty == false
                try await connector.connect(profile: profile, password: password) { [weak self] stage in
                    await self?.showProgress(stage, profile: profile, hasPassword: hasPassword)
                }
                notice = "Connecté à \(profile.name)."
            } catch is CancellationError {
                notice = "Arrêt de la tentative…"
            } catch { message = error.localizedDescription; notice = nil }
            await refresh()
        }
    }

    private func showProgress(_ stage: ConnectionStage, profile: VPNProfile, hasPassword: Bool) {
        switch stage {
        case .disconnecting: notice = "Déconnexion du VPN précédent…"
        case .launching: notice = "Envoi de la demande à Mobile Connect…"
        case .waitingForClient:
            if hasPassword { passwordSentFor = profile.id }
            notice = "En attente de SonicWall : valide les éventuelles autorisations dans Mobile Connect. Si rien ne démarre, vérifie Préférences > URL Control."
        case .connecting: notice = "SonicWall établit le tunnel vers \(profile.name)…"
        }
    }

    func copyPassword(_ profile: VPNProfile) {
        guard !copyRequestInFlight else { return }
        copyRequestInFlight = true
        Task {
            await Task.yield()
            copyingPassword = true
            defer { copyingPassword = false; copyRequestInFlight = false }
            do {
                guard let password = try await readPassword(profile.id), !password.isEmpty else {
                    throw VPNError.message("Aucun mot de passe enregistré pour ce profil.")
                }
                clipboard.copy(password)
                notice = "Mot de passe de \(profile.name) copié. Colle-le dans SonicWall avec ⌘V. Le presse-papiers sera vidé après 30 secondes si tu n’as rien copié d’autre."
            } catch { message = error.localizedDescription }
        }
    }

    func clearCopiedPassword() { clipboard.clearIfOwned() }

    func disconnect() {
        guard !disconnecting else { return }
        disconnecting = true
        let previous = operation
        previous?.cancel()
        operation = Task {
            await Task.yield()
            busy = true
            notice = "Déconnexion…"
            await previous?.value
            // The previous operation resets this flag as it finishes.
            busy = true
            defer { busy = false; requestInFlight = false; disconnecting = false }
            do {
                try await connector.disconnect()
                notice = "VPN SonicWall déconnecté."
            } catch { message = error.localizedDescription; notice = nil }
            await refresh()
        }
    }

    func openSonicWall() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SystemTransport.bundleID) else {
            message = "SonicWall Mobile Connect est introuvable."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
