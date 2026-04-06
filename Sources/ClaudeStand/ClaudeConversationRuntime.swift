import Foundation

actor ClaudeConversationRuntime {
    private struct ActiveTurn {
        var id: Int
        var continuation: AsyncThrowingStream<ClaudeMessageEvent, Error>.Continuation?
        var deliveredSessionRevision: Int
    }

    private var nextTurnID = 1
    private var activeTurn: ActiveTurn?
    private var currentSession: ClaudeSessionDescriptor?
    private var sessionRevision = 0

    func beginTurn() throws -> (turnID: Int, stream: AsyncThrowingStream<ClaudeMessageEvent, Error>) {
        guard activeTurn == nil else {
            throw ClaudeRuntimeError.turnInProgress
        }

        var capturedContinuation: AsyncThrowingStream<ClaudeMessageEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ClaudeMessageEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            throw ClaudeRuntimeError.streamSetupFailed
        }

        let turnID = nextTurnID
        nextTurnID += 1
        activeTurn = ActiveTurn(id: turnID, continuation: continuation, deliveredSessionRevision: 0)
        deliverCachedSessionIfNeeded()
        return (turnID, stream)
    }

    func currentSessionID() -> String? {
        currentSession?.sessionID
    }

    func updateSession(_ session: ClaudeSessionDescriptor) {
        currentSession = session
        sessionRevision += 1
        deliverCachedSessionIfNeeded()
    }

    func emitTextDelta(_ text: String) {
        activeTurn?.continuation?.yield(.assistantTextDelta(text))
    }

    func emitAssistantMessage(_ message: ClaudeAssistantMessage) {
        activeTurn?.continuation?.yield(.assistantMessage(message))
    }

    func emitResult(_ result: ClaudeResultSummary) {
        activeTurn?.continuation?.yield(.result(result))
    }

    func finishTurn() {
        activeTurn?.continuation?.finish()
        activeTurn = nil
    }

    func failTurn(_ error: Error) {
        activeTurn?.continuation?.finish(throwing: error)
        activeTurn = nil
    }

    func detachTurn(_ turnID: Int) {
        guard activeTurn?.id == turnID else { return }
        activeTurn?.continuation = nil
    }

    func clearSession() {
        currentSession = nil
        sessionRevision = 0
    }

    func hasActiveTurn() -> Bool {
        activeTurn != nil
    }

    private func deliverCachedSessionIfNeeded() {
        guard let currentSession else { return }
        guard var activeTurn else { return }
        guard activeTurn.deliveredSessionRevision < sessionRevision else { return }
        activeTurn.continuation?.yield(.sessionStarted(currentSession))
        activeTurn.deliveredSessionRevision = sessionRevision
        self.activeTurn = activeTurn
    }
}
