import Foundation

enum RawClaudeEvent: Sendable, Equatable {
    case system(ClaudeSessionDescriptor)
    case assistant(ClaudeAssistantMessage)
    case result(ClaudeResultSummary)
    case stream(RawClaudeStreamEnvelope)
    case ignored(type: String)
    case unknown(type: String, payload: String)
}

struct RawClaudeStreamEnvelope: Sendable, Equatable {
    var sessionID: String?
    var parentToolUseID: String?
    var event: RawClaudeStreamEvent
}

enum RawClaudeStreamEvent: Sendable, Equatable {
    case messageStart
    case contentBlockStart(index: Int, block: RawClaudeContentBlock?)
    case contentBlockDelta(index: Int, delta: RawClaudeContentDelta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case unknown(type: String, payload: String)
}

enum RawClaudeContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case unknown(type: String, payload: String)
}

enum RawClaudeContentDelta: Sendable, Equatable {
    case text(String)
    case inputJSON(String)
    case unknown(type: String, payload: String)
}
