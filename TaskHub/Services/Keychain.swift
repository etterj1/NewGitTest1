import Foundation
import Security

/// Secrets for an account. Stored as JSON in the Keychain, never on disk in plain text.
enum Credential: Codable {
    /// Personal API token (ClickUp, Asana, Slack user token).
    case token(String)
    /// OAuth access/refresh token pair (Google).
    case oauth(OAuthToken)
}

struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

enum CredentialStore {
    private static let service = "com.jasonetter.taskhub.credentials"

    static func save(_ credential: Credential, for accountID: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIError.api("Couldn't save to Keychain (status \(status)).")
        }
    }

    static func load(for accountID: UUID) -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    static func delete(for accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Named secrets (AI API keys)

    static func saveSecret(_ value: String, named name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError.api("Couldn't save to Keychain (status \(status)).") }
    }

    static func secret(named name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func token(for accountID: UUID) throws -> String {
        guard case .token(let token)? = load(for: accountID) else { throw APIError.missingCredential }
        return token
    }
}
