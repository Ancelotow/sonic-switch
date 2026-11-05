import Foundation

/// Public connection settings from macOS, excluding all password/reference fields.
public struct ConnectionDefaults: Sendable {
    public let username: String
    public let group: String
    public let server: String
    public init(username: String = "", group: String = "", server: String = "") {
        self.username = username
        self.group = group
        self.server = server
    }

    public static func parse(_ output: String) -> ConnectionDefaults {
        var values: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "AuthName" || key == "LoginGroupOrDomain" || key == "RemoteAddress" else { continue }
            values[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return ConnectionDefaults(username: values["AuthName"] ?? "", group: values["LoginGroupOrDomain"] ?? "", server: values["RemoteAddress"] ?? "")
    }

    public func fillingMissingFields(in profile: VPNProfile) -> VPNProfile {
        var result = profile
        if result.username.isEmpty { result.username = username }
        if result.group.isEmpty { result.group = group }
        if result.server.isEmpty { result.server = server }
        return result
    }
}
