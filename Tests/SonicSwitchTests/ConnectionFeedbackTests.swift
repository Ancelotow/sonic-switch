import Foundation
import XCTest
import VPNCore
@testable import SonicSwitch

final class ConnectionFeedbackTests: XCTestCase {
    @MainActor private func request(_ feedback: ConnectionFeedback) throws -> (URL, URL) {
        let original = try SonicURL.connect(profile: VPNProfile(name: "Test", connectionName: "Test"), password: "a+b%&é#?")
        let request = feedback.prepare(original)
        let items = URLComponents(url: request, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "password" }?.value, "a+b%&é#?")
        return (request, URL(string: items.first { $0.name == "callbackurl" }!.value!)!)
    }

    @MainActor func testCallbackReportsOnlyCurrentErrorCode() throws {
        let feedback = ConnectionFeedback()
        let (_, callback) = try request(feedback)
        feedback.receive(URL(string: callback.absoluteString.replacingOccurrences(of: "$ERROR_CODE$", with: "42"))!)
        XCTAssertTrue(feedback.failure?.localizedDescription.contains("42") == true)
    }

    @MainActor func testOldCallbackCannotRejectNewAttempt() throws {
        let feedback = ConnectionFeedback()
        let (_, old) = try request(feedback)
        _ = try request(feedback)
        feedback.receive(URL(string: old.absoluteString.replacingOccurrences(of: "$ERROR_CODE$", with: "99"))!)
        XCTAssertNil(feedback.failure)
    }

    @MainActor func testUnexpectedCallbackDataIsIgnored() throws {
        let feedback = ConnectionFeedback()
        let (_, callback) = try request(feedback)
        feedback.receive(callback) // Unexpanded tokens are not an error or success.
        XCTAssertNil(feedback.failure)
        feedback.receive(URL(string: callback.absoluteString.replacingOccurrences(of: "$ERROR_CODE$", with: "0"))!)
        XCTAssertNil(feedback.failure)
        // A duplicate response cannot change a completed request.
        feedback.receive(URL(string: callback.absoluteString.replacingOccurrences(of: "$ERROR_CODE$", with: "99"))!)
        XCTAssertNil(feedback.failure)
    }

    @MainActor func testWorkspaceTimeoutAndLateCompletionResumeOnce() async {
        let delivery = ClientDelivery()
        do {
            try await withCheckedThrowingContinuation { continuation in
                delivery.begin(continuation, timeout: .milliseconds(5))
            }
            XCTFail("Expected opening timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ne répond pas")) }
        delivery.finish(nil) // Late system callback must be harmless.
    }

    @MainActor func testWorkspaceCancellationAndLateCompletionResumeOnce() async {
        let delivery = ClientDelivery()
        do {
            try await withCheckedThrowingContinuation { continuation in
                delivery.begin(continuation)
                delivery.finish(CancellationError())
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        delivery.finish(nil)
    }
}
