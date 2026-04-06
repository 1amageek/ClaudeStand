import Foundation

public protocol ClaudeCredentialStoreProviding: Sendable {
    func credentialStoreData() throws -> Data
}
