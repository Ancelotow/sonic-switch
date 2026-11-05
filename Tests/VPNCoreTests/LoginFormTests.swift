import XCTest
import VPNCore

final class LoginFormTests: XCTestCase {
    private let request = LoginRequest(server: "vpn.example.com:4433", username: "test-user", password: "test-only-secret")
    private func form(server: String = "vpn.example.com:4433", username: String = "test-user") -> [LoginControl] {
        [LoginControl(id: 0, role: "AXStaticText", value: server),
         LoginControl(id: 1, role: "AXTextField", editable: true, label: "usernameField Username", value: username),
         LoginControl(id: 2, role: "AXTextField", secure: true, editable: true, label: "Password"),
         LoginControl(id: 3, role: "AXButton", label: "Login")]
    }

    func testVerifiedGatewayAndUsernameAllowFillingAndSubmission() {
        let match = LoginFormPolicy.match(form(), request: request)
        XCTAssertEqual(match?.usernameID, 1)
        XCTAssertEqual(match?.passwordID, 2)
        XCTAssertEqual(match?.submitID, 3)
        XCTAssertNotNil(LoginFormPolicy.match(form(server: "https://VPN.EXAMPLE.COM:4433/"), request: request))
    }

    func testDifferentOrLookalikeGatewayAndPortAreRejected() {
        for server in ["other.example.com:4433", "vpn.example.com.attacker.invalid:4433", "vpn.example.com:443", "prefix vpn.example.com:4433"] {
            XCTAssertNil(LoginFormPolicy.match(form(server: server), request: request))
        }
    }

    func testDifferentUsernameIsNeverOverwritten() {
        XCTAssertNil(LoginFormPolicy.match(form(username: "someone-else"), request: request))
        XCTAssertNotNil(LoginFormPolicy.match(form(username: ""), request: request))
    }

    func testMFAAndGenericPasswordPromptAreNotFilled() {
        var otp = form()
        otp.append(LoginControl(id: 4, role: "AXStaticText", label: "Verification code OTP"))
        XCTAssertNil(LoginFormPolicy.match(otp, request: request))
        XCTAssertNil(LoginFormPolicy.match(form().filter { $0.id != 1 }, request: request))
    }

    func testPasswordChangeAndAmbiguousUsernameAreRejected() {
        var change = form()
        change.append(LoginControl(id: 4, role: "AXTextField", secure: true, editable: true, label: "Confirm"))
        XCTAssertNil(LoginFormPolicy.match(change, request: request))
        var ambiguous = form()
        ambiguous.append(LoginControl(id: 4, role: "AXTextField", editable: true, value: "test-user"))
        XCTAssertNil(LoginFormPolicy.match(ambiguous, request: request))
    }

    func testUnidentifiedSubmitButtonIsNotPressed() {
        let noButton = form().filter { $0.id != 3 }
        XCTAssertNotNil(LoginFormPolicy.match(noButton, request: request))
        XCTAssertNil(LoginFormPolicy.match(noButton, request: request)?.submitID)
    }

    func testSnapshotsNeverRetainSecureFieldContents() {
        XCTAssertEqual(LoginControl(id: 1, role: "AXTextField", secure: true, value: "must-not-be-retained").value, "")
    }
}
