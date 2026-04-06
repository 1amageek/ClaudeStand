import Foundation

public enum ClaudeActivityEvent: Sendable, Equatable {
    case system(ClaudeSessionDescriptor)
    case toolStarted(ClaudeToolInvocation)
    case toolUpdated(ClaudeToolInvocation)
    case toolFinished(ClaudeToolResult)
    case warning(String)
    case diagnostic(String)
    case protocolMismatch(String)
}

public struct ClaudeToolInvocation: Sendable, Equatable {
    public var id: String
    public var name: String
    public var inputJSON: String

    public init(id: String, name: String, inputJSON: String) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
    }
}

public struct ClaudeToolResult: Sendable, Equatable {
    public var invocation: ClaudeToolInvocation
    public var finishReason: String

    public init(invocation: ClaudeToolInvocation, finishReason: String) {
        self.invocation = invocation
        self.finishReason = finishReason
    }
}
