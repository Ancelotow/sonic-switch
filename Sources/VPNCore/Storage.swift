import Foundation
import Security
import LocalAuthentication

public struct ProfileStore: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SonicSwitch", isDirectory: true)
    }
    public func load() throws -> [VPNProfile] {
        let file = directory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([VPNProfile].self, from: Data(contentsOf: file))
    }
    public func save(_ profiles: [VPNProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("profiles.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public struct PasswordVault: Sendable {
    private let service: String
    public init(service: String = "fr.local.SonicSwitch.credentials") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
    public func read(_ id: UUID) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let result = String(data: data, encoding: .utf8) else {
            throw VPNError.message("Le mot de passe dans le Trousseau est illisible.")
        }
        return result
    }
    public func contains(_ id: UUID) -> Bool {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let result = SecItemCopyMatching(q as CFDictionary, nil)
        return result == errSecSuccess || result == errSecInteractionNotAllowed
    }
    public func save(_ password: String, id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let result = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query(id).merging(attributes) { _, new in new }
            q[kSecAttrLabel as String] = "SonicSwitch — mot de passe VPN"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(result) }
    }
    public func delete(_ id: UUID) throws {
        let result = SecItemDelete(query(id) as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Erreur \(status)"
            throw VPNError.message("Trousseau macOS : \(message)")
        }
    }
}
