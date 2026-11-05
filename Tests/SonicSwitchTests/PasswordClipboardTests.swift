import AppKit
import XCTest
@testable import SonicSwitch
import VPNCore

final class PasswordClipboardTests: XCTestCase {
    @MainActor func testCopiedPasswordExpires() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = PasswordClipboard(pasteboard: pasteboard, lifetime: .milliseconds(5))
        clipboard.copy("test-only-password")
        XCTAssertEqual(pasteboard.string(forType: .string), "test-only-password")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor func testExpiryKeepsTextCopiedLaterByUser() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = PasswordClipboard(pasteboard: pasteboard, lifetime: .milliseconds(5))
        clipboard.copy("test-only-password")
        pasteboard.clearContents()
        pasteboard.setString("user's next copy", forType: .string)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pasteboard.string(forType: .string), "user's next copy")
    }

    @MainActor func testClearingOnQuitRemovesOnlyOwnedPassword() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = PasswordClipboard(pasteboard: pasteboard)
        clipboard.copy("test-only-password")
        clipboard.clearIfOwned()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testOnlyPublicSettingsAreUsedAndExplicitFieldsTakePrecedence() {
        let settings = ConnectionDefaults.parse("""
            AuthName : configured-user
            LoginGroupOrDomain : Local Domain
            Password : DO-NOT-IMPORT
            AuthPassword : DO-NOT-IMPORT
            RemoteAddress : vpn.example.com
        """)
        let imported = settings.fillingMissingFields(in: VPNProfile(name: "Existing", connectionName: "Existing"))
        XCTAssertEqual(imported.username, "configured-user")
        XCTAssertEqual(imported.group, "Local Domain")
        XCTAssertEqual(imported.server, "vpn.example.com")
        let explicit = VPNProfile(server: "explicit.example.com", username: "override", group: "override-realm", usesRealm: true)
        XCTAssertEqual(settings.fillingMissingFields(in: explicit), explicit)
    }
}
