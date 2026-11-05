import AppKit
import Combine
import SwiftUI
import XCTest
import VPNCore
@testable import SonicSwitch

private actor TestTransport: VPNTransport {
    private var current: [VPNService] = []
    private var opens = 0
    private let failOpen: Bool
    init(failOpen: Bool = false) { self.failOpen = failOpen }
    func services() -> [VPNService] { current }
    func stop(id: String) { current = [] }
    func ensureClientAvailable() { }
    func openConnection(_ url: URL) throws {
        opens += 1
        if failOpen { throw VPNError.message("Mobile Connect n’a pas accepté la demande.") }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "name" }!.value!
        current = [VPNService(id: "test", name: name, state: "Connected")]
    }
    func openCount() -> Int { opens }
}

private actor PasswordGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var entered = false
    func read() async -> String? {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: "test-only"); continuation = nil }
}

final class AppModelTests: XCTestCase {
    private let profile = VPNProfile(name: "VPN de test", connectionName: "Test", server: "vpn.example.com", username: "test-user")

    private func store() throws -> ProfileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(directory: directory)
        try store.save([profile])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return store
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !(await condition()) {
            guard clock.now < deadline else { XCTFail("Timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor func testConnectionDefersPublishingAndKeepsProfileSelection() async throws {
        let transport = TestTransport()
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false, readPassword: { _ in nil })
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        model.connect(profile)
        // Calling from a menu/view callback must not publish within its render transaction.
        XCTAssertEqual(updates, 0)
        try await waitUntil { await transport.openCount() == 1 && !model.busy }
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertEqual(model.selectedID, profile.id)
        XCTAssertEqual(model.notice, "Connecté à VPN de test.")
        XCTAssertNil(model.message)
        withExtendedLifetime(subscription) { }
    }

    @MainActor func testPasswordPromptDoesNotPreventUIUpdates() async throws {
        let gate = PasswordGate()
        let transport = TestTransport()
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false,
                             readPassword: { _ in await gate.read() })
        model.connect(profile)
        try await waitUntil { await gate.entered }
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.notice?.contains("Trousseau") == true)
        // MainActor remains runnable while the vault waits for authorization.
        model.selectedID = profile.id
        XCTAssertEqual(model.selectedID, profile.id)
        let opens = await transport.openCount()
        XCTAssertEqual(opens, 0)
        await gate.release()
        try await waitUntil { await transport.openCount() == 1 && !model.busy }
        XCTAssertNil(model.message)
        XCTAssertEqual(model.passwordSentFor, profile.id)
    }

    @MainActor func testDoubleClickSendsOnlyOneConnection() async throws {
        let transport = TestTransport()
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false, readPassword: { _ in nil })
        model.connect(profile)
        model.connect(profile)
        try await waitUntil { await transport.openCount() == 1 && !model.busy }
        let opens = await transport.openCount()
        XCTAssertEqual(opens, 1)
    }

    @MainActor func testLaunchFailureKeepsWindowContentAndShowsError() async throws {
        _ = NSApplication.shared
        let transport = TestTransport(failOpen: true)
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false, readPassword: { _ in nil })
        let hosting = NSHostingView(rootView: MainView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        model.connect(profile)
        try await waitUntil { model.message != nil && !model.busy }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.message, "Mobile Connect n’a pas accepté la demande.")
        XCTAssertEqual(model.selectedID, profile.id)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertNotNil(window.contentView)
        XCTAssertGreaterThan(hosting.fittingSize.width, 100)
        XCTAssertGreaterThan(hosting.fittingSize.height, 100)
    }

    @MainActor func testUnchangedMonitoringDoesNotRepublish() async throws {
        let model = AppModel(store: try store(), transport: TestTransport(), startMonitoring: false, readPassword: { _ in nil })
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(subscription) { }
    }

    @MainActor func testCopyReadsStoredSecretWithoutStartingVPN() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let transport = TestTransport()
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false,
                             readPassword: { _ in "isolated-test-secret" },
                             clipboard: PasswordClipboard(pasteboard: pasteboard))
        model.copyPassword(profile)
        try await waitUntil { pasteboard.string(forType: .string) == "isolated-test-secret" && !model.copyingPassword }
        let opens = await transport.openCount()
        XCTAssertEqual(opens, 0)
        model.clearCopiedPassword()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor func testMissingAdvertisedPasswordDoesNotStartVPN() async throws {
        let transport = TestTransport()
        let model = AppModel(store: try store(), transport: transport, startMonitoring: false, readPassword: { _ in nil })
        model.savedPasswords.insert(profile.id)
        model.connect(profile)
        try await waitUntil { model.message != nil && !model.busy }
        XCTAssertTrue(model.message?.contains("retrouvé") == true)
        let opens = await transport.openCount()
        XCTAssertEqual(opens, 0)
    }
}
