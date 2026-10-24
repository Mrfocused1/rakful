import Foundation
import Security

/// Where cloud-backed features (product identification, pricing, listing
/// generation, eBay publishing) would be served from.
///
/// The iOS app never contains API secrets. Third-party credentials (eBay,
/// AI providers) live on the Rakful server; the app only knows the base
/// URL and holds a per-user session token in the Keychain. When no base URL is
/// configured (the default in this build), every cloud feature reports itself
/// unavailable and the app stays fully on-device.
struct BackendConfiguration: Sendable, Equatable {
    var baseURL: URL?

    var isConfigured: Bool { baseURL != nil }

    static func fromBundle(_ bundle: Bundle = .main) -> BackendConfiguration {
        guard
            let raw = bundle.object(forInfoDictionaryKey: "RRBackendBaseURL") as? String,
            let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
            url.scheme == "https"
        else { return BackendConfiguration(baseURL: nil) }
        return BackendConfiguration(baseURL: url)
    }

    static let unconfigured = BackendConfiguration(baseURL: nil)
}

/// Minimal Keychain wrapper for server session tokens.
struct KeychainStore: Sendable {
    var service = "com.rackful.app"

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    func removeAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    struct KeychainError: Error { let status: OSStatus }
}
