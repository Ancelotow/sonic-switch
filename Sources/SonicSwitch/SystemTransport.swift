import AppKit
import Foundation
import VPNCore

struct SystemTransport: VPNTransport {
    static let bundleID = "com.sonicwall.SonicWALL-Mobile-Connect"

    func services() async throws -> [VPNService] {
        try VPNService.parseList(await command(["--nc", "list"]))
    }

    func stop(id: String) async throws {
        _ = try await command(["--nc", "stop", id])
    }

    func connectionDefaults(id: String) async throws -> ConnectionDefaults {
        // Read only the target service's public settings, never SonicWall's Keychain.
        ConnectionDefaults.parse(try await command(["--nc", "show", id]))
    }

    @MainActor func ensureClientAvailable() async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil else {
            throw VPNError.message("Installe SonicWall Mobile Connect depuis l’App Store pour utiliser SonicSwitch.")
        }
    }

    @MainActor func openConnection(_ url: URL) async throws {
        try Task.checkCancellation()
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw VPNError.message("SonicWall Mobile Connect est introuvable.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // SonicWall may require an authorization, login, certificate or MFA prompt.
        configuration.activates = true
        let requestURL = ConnectionFeedback.shared.prepare(url)
        LoginAssistant.shared.prepare(url)
        // Direct, explicit delivery to SonicWall. No shell, clipboard, browser or URL log.
        let delivery = ClientDelivery()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delivery.begin(continuation)
                NSWorkspace.shared.open([requestURL], withApplicationAt: applicationURL, configuration: configuration) { app, error in
                    let accepted = error == nil && app?.bundleIdentifier == Self.bundleID
                    Task { @MainActor in
                        // The system error can include the URL; never propagate it.
                        delivery.finish(accepted ? nil : VPNError.message("Mobile Connect n’a pas accepté la demande. Vérifie son réglage URL Control."))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in delivery.finish(CancellationError()) }
        }
    }

    @MainActor func checkConnectionResponse() async throws {
        if let failure = ConnectionFeedback.shared.failure { throw failure }
        await LoginAssistant.shared.tick()
    }

    @MainActor func finishConnectionAttempt() { LoginAssistant.shared.finish() }

    private func command(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                throw VPNError.message("Impossible d’interroger les VPN macOS.")
            }
            // Bound even an unexpectedly stalled system command; output is small (service list only).
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else {
                throw VPNError.message("macOS a refusé l’opération VPN. Vérifie Mobile Connect ou les Réglages Système > VPN.")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// NSWorkspace's completion is outside our control. Bound it and resume once,
/// including when cancellation and a late completion race with the watchdog.
@MainActor final class ClientDelivery {
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    func begin(_ continuation: CheckedContinuation<Void, Error>, timeout: Duration = .seconds(10)) {
        self.continuation = continuation
        watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            finish(VPNError.message("Mobile Connect ne répond pas à la demande d’ouverture. Affiche-le et vérifie ses autorisations avant de réessayer."))
        }
    }
    func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        watchdog?.cancel()
        watchdog = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
