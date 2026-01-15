import Foundation
import Security

class KeychainService {
    static let shared = KeychainService()

    private let serviceName = "com.fluent.api"
    private let apiKeyAccount = "openai-api-key"

    private init() {}

    // MARK: - API Key Management

    func saveAPIKey(_ apiKey: String) -> Bool {
        // Delete existing key first
        deleteAPIKey()

        guard let data = apiKey.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: apiKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            return nil
        }

        return apiKey
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: apiKeyAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func hasAPIKey() -> Bool {
        return getAPIKey() != nil
    }

    // MARK: - API Key Validation

    func isValidAPIKeyFormat(_ apiKey: String) -> Bool {
        // OpenAI API keys start with "sk-" and are typically 51 characters
        // But newer keys may have different formats, so we're lenient
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-") && trimmed.count >= 20
    }

    // Returns masked version for display (e.g., "sk-...abc123")
    func getMaskedAPIKey() -> String? {
        guard let apiKey = getAPIKey() else { return nil }
        guard apiKey.count > 10 else { return "sk-***" }

        let prefix = String(apiKey.prefix(3))
        let suffix = String(apiKey.suffix(6))
        return "\(prefix)...\(suffix)"
    }
}
