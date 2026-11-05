import Foundation
import VPNCore

/// Only accepts a response for the current, randomly identified request.
/// Never requests a password or a free-form error message in the callback.
@MainActor final class ConnectionFeedback {
    static let shared = ConnectionFeedback()
    private var requestID: UUID?
    private(set) var failure: VPNError?

    func prepare(_ url: URL) -> URL {
        let id = UUID()
        requestID = id
        failure = nil
        let callback = "sonicswitch://vpn-callback/\(id.uuidString)?error_code=$ERROR_CODE$"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Preserve the original encoding, especially '+' and '%' in passwords.
        components.percentEncodedQuery = (components.percentEncodedQuery ?? "") + "&callbackurl=" + callback.addingPercentEncoding(withAllowedCharacters: allowed)!
        return components.url!
    }

    func receive(_ url: URL) {
        guard let id = requestID, url.scheme == "sonicswitch", url.host == "vpn-callback",
              url.path == "/" + id.uuidString,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "error_code" })?.value,
              let code = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        requestID = nil
        if code != 0 {
            failure = .message("SonicWall a refusé la connexion (code \(code)). Consulte Mobile Connect pour le détail et les éventuelles validations.")
        }
        // A callback never declares success: macOS must confirm the tunnel.
    }
}
