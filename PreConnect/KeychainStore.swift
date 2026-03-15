import Foundation
import Security

// MARK: - Raw Keychain CRUD

struct KeychainStore {
    private static let service = "com.preconnect.session"

    static func save(_ data: Data, forKey key: String) {
        var q = base(key)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(forKey key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData  as String] = true
        q[kSecMatchLimit  as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(forKey key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass       as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

// MARK: - Persisted Session

/// Codable representation of a paired session stored in Keychain.
/// The `token` field is never printed or logged.
struct PersistedSession: Codable {
    let token: String
    let expiresAtISO: String?
    let serverName: String
    let endpointString: String
    let deviceId: String
    let deviceName: String

    private static let key = "active_session"

    // MARK: Lifecycle

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainStore.save(data, forKey: Self.key)
    }

    static func restore() -> PersistedSession? {
        guard let data = KeychainStore.load(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    static func wipe() {
        KeychainStore.delete(forKey: key)
    }

    // MARK: Conversion

    func toSessionInfo() -> SessionInfo? {
        guard let url = URL(string: endpointString) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expiresAt = expiresAtISO.flatMap { iso.date(from: $0) }
        if expiresAt == nil {
            iso.formatOptions = [.withInternetDateTime]
            expiresAt = expiresAtISO.flatMap { iso.date(from: $0) }
        }
        return SessionInfo(
            token: token, expiresAt: expiresAt, serverName: serverName,
            endpoint: url, deviceId: deviceId, deviceName: deviceName
        )
    }
}
