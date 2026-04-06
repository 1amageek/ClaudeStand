import Foundation

public struct ClaudeCredentialStoreDocument: Codable, Sendable {
    public var claudeAiOauth: ClaudeOAuthCredentials

    public init(claudeAiOauth: ClaudeOAuthCredentials) {
        self.claudeAiOauth = claudeAiOauth
    }
}
