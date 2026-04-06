import Foundation

public struct ClaudeConversationOptions: Sendable, Equatable {
    public var resumeToken: String?

    public init(resumeToken: String? = nil) {
        self.resumeToken = resumeToken
    }
}
