import Foundation
import XCTest
@testable import VPNCore

final class ProfileTests: XCTestCase {
    func testPasswordRoundTripWithURLReservedCharacters() throws {
        let password = "a+b% &?#=/é🔒\n"
        let profile = VPNProfile(name: "Bureau", connectionName: "Paris & Lyon", server: "vpn.example.com:4433",
                                 username: "a+b@example.com", group: "Local Domain")
        let url = try SonicURL.connect(profile: profile, password: password)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["password"], password)
        XCTAssertEqual(values["name"], profile.connectionName)
        XCTAssertEqual(values["username"], profile.username)
        XCTAssertEqual(values["domain"], profile.group)
        XCTAssertNil(values["realm"])
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testRealmAndNoPassword() throws {
        let profile = VPNProfile(name: "SMA", connectionName: "SMA", group: "Corp", usesRealm: true)
        let url = try SonicURL.connect(profile: profile, password: nil)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "realm" }?.value, "Corp")
        XCTAssertFalse(items.contains { $0.name == "password" || $0.name == "domain" })
    }

    func testExistingProfileDoesNotRequireServer() throws {
        let p = VPNProfile(name: "Mon bureau", connectionName: "Bureau")
        XCTAssertNoThrow(try p.validated(existingNames: ["Bureau"]))
        XCTAssertThrowsError(try p.validated(existingNames: []))
        XCTAssertThrowsError(try p.validated(existingNames: ["Bureau", "Bureau"]))
    }

    func testServerValidation() throws {
        for server in ["vpn.example.com", "https://vpn.example.com:4433/", "192.0.2.1:4433", "[2001:db8::1]:4433"] {
            XCTAssertNoThrow(try VPNProfile(name: "Test", connectionName: "Test", server: server).validated(existingNames: []))
        }
        for server in ["http://vpn.example.com", "vpn.example.com/path", "user:secret@vpn.example.com", "vpn.example.com?password=x", "vpn.example.com#x", "vpn.example.com:0", "vpn.example.com:70000", "bad host"] {
            XCTAssertThrowsError(try VPNProfile(name: "Test", connectionName: "Test", server: server).validated(existingNames: []), server)
        }
    }

    func testStorageRoundTripAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        XCTAssertEqual(try store.load(), [])
        let p = VPNProfile(name: "Bureau", connectionName: "Bureau", username: "test", favorite: true)
        try store.save([p])
        XCTAssertEqual(try store.load(), [p])
        let file = directory.appendingPathComponent("profiles.json")
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.lowercased().contains("password"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt")
    }

    func testKeychainLifecycleWithIsolatedTestItem() throws {
        let vault = PasswordVault(service: "fr.local.SonicSwitch.tests." + UUID().uuidString)
        let id = UUID()
        defer { try? vault.delete(id) }
        XCTAssertNil(try vault.read(id))
        try vault.save("test-only-é+%", id: id)
        XCTAssertTrue(vault.contains(id))
        XCTAssertEqual(try vault.read(id), "test-only-é+%")
        try vault.save("updated-test-only", id: id)
        XCTAssertEqual(try vault.read(id), "updated-test-only")
        try vault.delete(id)
        XCTAssertFalse(vault.contains(id))
        XCTAssertNil(try vault.read(id))
        XCTAssertNoThrow(try vault.delete(id))
    }

    func testParseOnlySonicWallServices() throws {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      2A03012E-45DD-441A-8034-B1A0B52EC342 VPN (com.sonicwall.SonicWALL-Mobile-Connect) "Paris bureau" [VPN:com.sonicwall.SonicWALL-Mobile-Connect]
          (Disconnected)   813B8590-FADB-4E70-9CFF-5AA77229FFDE VPN (com.sonicwall.SonicWALL-Mobile-Connect) "Lyon" [VPN:com.sonicwall.SonicWALL-Mobile-Connect]
        * (Connected)      3A03012E-45DD-441A-8034-B1A0B52EC342 VPN (org.other) "Autre" [VPN:org.other]
        """
        let services = try VPNService.parseList(output)
        XCTAssertEqual(services.map(\.name), ["Paris bureau", "Lyon"])
        XCTAssertTrue(services[0].isConnected)
        XCTAssertTrue(services[1].isInactive)
        XCTAssertThrowsError(try VPNService.parseList("unrecognized output"))
        XCTAssertThrowsError(try VPNService.parseList("Available network connection services\ninvalid [VPN:com.sonicwall.foo]"))
    }
}

private actor FakeTransport: VPNTransport {
    var current: [VPNService]
    var events: [String] = []
    var refusesStop: Bool
    var unavailable: Bool
    var autoConnect: Bool
    var reconnectOnThirdRead: Bool
    var reads = 0
    var rejectRequest = false
    var statesAfterOpen: [String] = []
    var openedName: String?
    var defaults = ConnectionDefaults()
    var openedURL: URL?
    var finished = 0

    init(_ current: [VPNService], refusesStop: Bool = false, unavailable: Bool = false,
         autoConnect: Bool = true, reconnectOnThirdRead: Bool = false) {
        self.current = current
        self.refusesStop = refusesStop
        self.unavailable = unavailable
        self.autoConnect = autoConnect
        self.reconnectOnThirdRead = reconnectOnThirdRead
    }
    func ensureClientAvailable() throws {
        if unavailable { throw VPNError.message("Client absent") }
    }
    func services() -> [VPNService] {
        reads += 1
        if let openedName, !statesAfterOpen.isEmpty {
            current = [VPNService(id: "new", name: openedName, state: statesAfterOpen.removeFirst())]
        }
        if reconnectOnThirdRead && reads >= 3 {
            current = [VPNService(id: "old", name: "Ancien", state: "Connected")]
        }
        return current
    }
    func stop(id: String) {
        events.append("stop:" + id)
        if !refusesStop {
            current = current.map { $0.id == id ? VPNService(id: $0.id, name: $0.name, state: "Disconnected") : $0 }
        }
    }
    func openConnection(_ url: URL) {
        events.append("open")
        openedURL = url
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "name" }!.value!
        openedName = name
        if autoConnect { current = [VPNService(id: "new", name: name, state: "Connected")] }
    }
    func recordedEvents() -> [String] { events }
    func connectionDefaults(id: String) -> ConnectionDefaults { defaults }
    func setDefaults(_ value: ConnectionDefaults) { defaults = value }
    func requestURL() -> URL? { openedURL }
    func finishConnectionAttempt() { finished += 1 }
    func finishCount() -> Int { finished }
    func rejectNextRequest() { rejectRequest = true }
    func simulateStates(_ states: [String]) { statesAfterOpen = states }
    func checkConnectionResponse() throws {
        if rejectRequest { throw VPNError.message("SonicWall code 42") }
    }
}

final class SwitchingTests: XCTestCase {
    private let profile = VPNProfile(name: "Nouveau", connectionName: "Nouveau", server: "vpn.example.com", username: "test-user")
    private let old = VPNService(id: "old", name: "Ancien", state: "Connected")
    private func connector(_ t: FakeTransport) -> VPNConnector {
        VPNConnector(transport: t, disconnectTimeout: .milliseconds(15), connectionTimeout: .milliseconds(15), pollInterval: .milliseconds(1))
    }

    func testDisconnectBeforeConnect() async throws {
        let t = FakeTransport([old])
        try await connector(t).connect(profile: profile, password: "test")
        let events = await t.recordedEvents()
        XCTAssertEqual(events, ["stop:old", "open"])
        let finished = await t.finishCount()
        XCTAssertEqual(finished, 1)
    }

    func testExistingProfileSuppliesMissingUsernameAndDomainWithStoredPassword() async throws {
        let t = FakeTransport([VPNService(id: "target", name: "Nouveau", state: "Disconnected")])
        await t.setDefaults(ConnectionDefaults(username: "configured-user", group: "Configured Domain", server: "https://vpn.example.com:4433"))
        var imported = profile
        imported.username = ""
        imported.server = ""
        try await connector(t).connect(profile: imported, password: "test+secret%&")
        let url = await t.requestURL()!
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["username"], "configured-user")
        XCTAssertEqual(values["domain"], "Configured Domain")
        XCTAssertEqual(values["password"], "test+secret%&")
        XCTAssertEqual(values["server"], "vpn.example.com:4433")
    }

    func testStoredPasswordWithoutAnyUsernameDoesNotDisconnect() async {
        let t = FakeTransport([old])
        var missingUsername = profile
        missingUsername.username = ""
        do { try await connector(t).connect(profile: missingUsername, password: "test"); XCTFail("Expected missing username") }
        catch { XCTAssertTrue(error.localizedDescription.contains("utilisateur")) }
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testFailedDisconnectNeverOpensNextVPN() async {
        let t = FakeTransport([old], refusesStop: true)
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected timeout") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertEqual(events, ["stop:old"])
    }

    func testMissingClientLeavesActiveConnectionAlone() async {
        let t = FakeTransport([old], unavailable: true)
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected failure") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testInvalidProfileLeavesActiveConnectionAlone() async {
        let t = FakeTransport([old])
        let invalid = VPNProfile(name: "Missing", connectionName: "Missing")
        do { try await connector(t).connect(profile: invalid, password: nil); XCTFail("Expected validation error") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testUnknownStateLeavesAllConnectionsAlone() async {
        let t = FakeTransport([old, VPNService(id: "unknown", name: "Unknown", state: "Invalid")])
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected failure") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testAlreadyConnectedDoesNotReconnect() async throws {
        let t = FakeTransport([VPNService(id: "new", name: profile.connectionName, state: "Connected")])
        try await connector(t).connect(profile: profile, password: nil)
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testExternalReconnectBlocksNewConnection() async {
        let t = FakeTransport([old], reconnectOnThirdRead: true)
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected failure") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertEqual(events, ["stop:old"])
    }

    func testUnconfirmedConnectionIsAnError() async {
        let t = FakeTransport([], autoConnect: false)
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected timeout") }
        catch { }
        let events = await t.recordedEvents()
        XCTAssertEqual(events, ["open"])
    }

    func testNoTunnelReportsStartupFailurePromptly() async {
        let t = FakeTransport([], autoConnect: false)
        let c = VPNConnector(transport: t, connectionTimeout: .seconds(2), pollInterval: .milliseconds(1), startupTimeout: .milliseconds(8))
        let start = ContinuousClock.now
        do { try await c.connect(profile: profile, password: nil); XCTFail("Expected startup failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("URL Control")) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testClientRejectionIsShownWithoutWaitingForTimeout() async {
        let t = FakeTransport([], autoConnect: false)
        await t.rejectNextRequest()
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error.localizedDescription, "SonicWall code 42") }
        let finished = await t.finishCount()
        XCTAssertEqual(finished, 1)
    }

    func testStartedTunnelCanAuthenticateBeyondStartupTimeout() async throws {
        let t = FakeTransport([], autoConnect: false)
        await t.simulateStates(Array(repeating: "Connecting", count: 15) + ["Connected"])
        let c = VPNConnector(transport: t, connectionTimeout: .seconds(2), pollInterval: .milliseconds(1), startupTimeout: .milliseconds(1))
        try await c.connect(profile: profile, password: nil)
    }

    func testInterruptedTunnelIsReportedImmediately() async {
        let t = FakeTransport([], autoConnect: false)
        await t.simulateStates(["Connecting", "Disconnected"])
        do { try await connector(t).connect(profile: profile, password: nil); XCTFail("Expected interruption") }
        catch { XCTAssertTrue(error.localizedDescription.contains("interrompu")) }
    }

    func testCancelledAttemptDoesNotTouchVPN() async {
        let t = FakeTransport([old])
        let c = connector(t)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await c.connect(profile: profile, password: nil)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await t.recordedEvents()
        XCTAssertTrue(events.isEmpty)
        let finished = await t.finishCount()
        XCTAssertEqual(finished, 1)
    }
}
