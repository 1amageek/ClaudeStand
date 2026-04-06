import Foundation

actor ClaudeActivityRuntime {
    private struct ActiveToolState: Sendable {
        var id: String
        var name: String
        var inputJSON: String
    }

    private struct ActiveTurn {
        var id: Int
        var continuation: AsyncThrowingStream<ClaudeActivityEvent, Error>.Continuation?
        var toolsByIndex: [Int: ActiveToolState]
        var seenToolIDs: Set<String>
    }

    private var nextTurnID = 1
    private var activeTurn: ActiveTurn?
    private var bufferedWarnings: [String] = []

    func beginTurn() throws -> (turnID: Int, stream: AsyncThrowingStream<ClaudeActivityEvent, Error>) {
        guard activeTurn == nil else {
            throw ClaudeRuntimeError.turnInProgress
        }
        bufferedWarnings.removeAll(keepingCapacity: false)

        var capturedContinuation: AsyncThrowingStream<ClaudeActivityEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ClaudeActivityEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            throw ClaudeRuntimeError.streamSetupFailed
        }

        let turnID = nextTurnID
        nextTurnID += 1
        activeTurn = ActiveTurn(
            id: turnID,
            continuation: continuation,
            toolsByIndex: [:],
            seenToolIDs: []
        )
        return (turnID, stream)
    }

    func emitSystem(_ session: ClaudeSessionDescriptor) {
        activeTurn?.continuation?.yield(.system(session))
    }

    func emitDiagnostic(_ line: String) {
        activeTurn?.continuation?.yield(.diagnostic(line))
    }

    func emitWarning(_ warning: String) {
        if activeTurn != nil {
            activeTurn?.continuation?.yield(.warning(warning))
        } else {
            bufferedWarnings.append(warning)
        }
    }

    func emitProtocolMismatch(_ warning: String) {
        if activeTurn != nil {
            activeTurn?.continuation?.yield(.protocolMismatch(warning))
        } else {
            bufferedWarnings.append(warning)
        }
    }

    func handleContentBlockStart(index: Int, block: RawClaudeContentBlock?) {
        guard let block else { return }
        guard case .toolUse(let id, let name, let inputJSON) = block else { return }
        guard var activeTurn else { return }
        activeTurn.toolsByIndex[index] = ActiveToolState(id: id, name: name, inputJSON: inputJSON)
        activeTurn.seenToolIDs.insert(id)
        activeTurn.continuation?.yield(.toolStarted(.init(id: id, name: name, inputJSON: inputJSON)))
        self.activeTurn = activeTurn
    }

    func handleContentBlockDelta(index: Int, delta: RawClaudeContentDelta) {
        guard case .inputJSON(let partialJSON) = delta else { return }
        guard var activeTurn else { return }
        guard var tool = activeTurn.toolsByIndex[index] else { return }
        tool.inputJSON += partialJSON
        activeTurn.toolsByIndex[index] = tool
        activeTurn.continuation?.yield(.toolUpdated(.init(id: tool.id, name: tool.name, inputJSON: tool.inputJSON)))
        self.activeTurn = activeTurn
    }

    func handleContentBlockStop(index: Int, finishReason: String = "content_block_stop") {
        guard var activeTurn else { return }
        guard let tool = activeTurn.toolsByIndex.removeValue(forKey: index) else { return }
        let invocation = ClaudeToolInvocation(id: tool.id, name: tool.name, inputJSON: tool.inputJSON)
        activeTurn.continuation?.yield(.toolFinished(.init(invocation: invocation, finishReason: finishReason)))
        self.activeTurn = activeTurn
    }

    func emitAssistantToolsIfNeeded(from message: ClaudeAssistantMessage) {
        guard var activeTurn else { return }
        for block in message.content {
            guard case .toolUse(let id, let name, let inputJSON) = block else { continue }
            guard activeTurn.seenToolIDs.contains(id) == false else { continue }
            activeTurn.seenToolIDs.insert(id)
            let invocation = ClaudeToolInvocation(id: id, name: name, inputJSON: inputJSON)
            activeTurn.continuation?.yield(.toolStarted(invocation))
            activeTurn.continuation?.yield(.toolFinished(.init(invocation: invocation, finishReason: "assistant_message")))
        }
        self.activeTurn = activeTurn
    }

    func finishTurn(result: ClaudeResultSummary?) {
        if let result, var activeTurn {
            let remaining = activeTurn.toolsByIndex.values.map {
                ClaudeToolResult(
                    invocation: ClaudeToolInvocation(id: $0.id, name: $0.name, inputJSON: $0.inputJSON),
                    finishReason: result.stopReason
                )
            }
            activeTurn.toolsByIndex.removeAll(keepingCapacity: false)
            for tool in remaining {
                activeTurn.continuation?.yield(.toolFinished(tool))
            }
            self.activeTurn = activeTurn
        }
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
}
