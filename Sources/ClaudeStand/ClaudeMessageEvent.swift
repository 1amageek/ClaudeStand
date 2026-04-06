import Foundation

public enum ClaudeMessageEvent: Sendable, Equatable {
    case sessionStarted(ClaudeSessionDescriptor)
    case assistantTextDelta(String)
    case assistantMessage(ClaudeAssistantMessage)
    case result(ClaudeResultSummary)
}

public struct ClaudeSessionDescriptor: Sendable, Equatable {
    public var sessionID: String
    public var cwd: String
    public var model: String
    public var tools: [String]
    public var mcpServers: [ClaudeMCPServerStatus]
    public var permissionMode: String

    public init(
        sessionID: String,
        cwd: String,
        model: String,
        tools: [String],
        mcpServers: [ClaudeMCPServerStatus],
        permissionMode: String
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = model
        self.tools = tools
        self.mcpServers = mcpServers
        self.permissionMode = permissionMode
    }
}

public struct ClaudeMCPServerStatus: Sendable, Equatable {
    public var name: String
    public var status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public struct ClaudeAssistantMessage: Sendable, Equatable {
    public var sessionID: String
    public var messageID: String
    public var model: String
    public var content: [ClaudeAssistantContent]
    public var parentToolUseID: String?

    public init(
        sessionID: String,
        messageID: String,
        model: String,
        content: [ClaudeAssistantContent],
        parentToolUseID: String?
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.model = model
        self.content = content
        self.parentToolUseID = parentToolUseID
    }
}

public enum ClaudeAssistantContent: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case unknown(type: String, payload: String)
}

public struct ClaudeResultSummary: Sendable, Equatable {
    public var sessionID: String
    public var result: String
    public var isError: Bool
    public var stopReason: String
    public var totalCostUSD: Double
    public var durationMS: Int
    public var numTurns: Int

    public init(
        sessionID: String,
        result: String,
        isError: Bool,
        stopReason: String,
        totalCostUSD: Double,
        durationMS: Int,
        numTurns: Int
    ) {
        self.sessionID = sessionID
        self.result = result
        self.isError = isError
        self.stopReason = stopReason
        self.totalCostUSD = totalCostUSD
        self.durationMS = durationMS
        self.numTurns = numTurns
    }
}
