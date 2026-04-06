import Foundation
import Security

public struct KeychainCredentialStoreProvider: ClaudeCredentialStoreProviding {
    public let account: String
    public let service: String

    public init(
        account: String = "default",
        service: String = "Claude Code-credentials"
    ) {
        self.account = account
        self.service = service
    }

    public func credentialStoreData() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if account != "default" {
            query[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw ClaudeAuthenticationError.keychainLoadFailed(status: status)
        }

        return data
    }
}
