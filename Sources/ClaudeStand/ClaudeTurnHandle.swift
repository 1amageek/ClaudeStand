import Foundation

public struct ClaudeTurnHandle: Sendable {
    public let messages: AsyncThrowingStream<ClaudeMessageEvent, Error>
    public let activity: AsyncThrowingStream<ClaudeActivityEvent, Error>

    private let cancelOperation: @Sendable () async -> Void

    public init(
        messages: AsyncThrowingStream<ClaudeMessageEvent, Error>,
        activity: AsyncThrowingStream<ClaudeActivityEvent, Error>,
        cancelOperation: @escaping @Sendable () async -> Void
    ) {
        self.messages = messages
        self.activity = activity
        self.cancelOperation = cancelOperation
    }

    public func cancel() async {
        await cancelOperation()
    }
}
