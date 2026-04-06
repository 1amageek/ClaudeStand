import Foundation
import os.log

private let runtimeLogger = Logger(subsystem: "com.claudestand", category: "Runtime")

public actor ClaudeRuntime {
    typealias ProcessSessionFactory = @Sendable () -> any ClaudeProcessSessioning

    enum RuntimeState: String, Sendable {
        case idle
        case starting
        case running
        case turnActive
        case stopping
        case stopped
        case failed
    }

    public let configuration: ClaudeConfiguration

    private let processSessionFactory: ProcessSessionFactory
    private let parser = RawClaudeEventParser()
    private let conversationRuntime = ClaudeConversationRuntime()
    private let activityRuntime = ClaudeActivityRuntime()

    private var processSession: (any ClaudeProcessSessioning)?
    private var stdoutTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var state: RuntimeState = .idle
    private var recentDiagnostics: [String] = []
    private var lastFailureMessage: String?
    private var pendingStartOptions = ClaudeConversationOptions()
    private var stdoutBuffer: String = ""

    public init(
        configuration: ClaudeConfiguration = ClaudeConfiguration()
    ) {
        let location = (try? ClaudeStandStorageLocation.applicationSupport())
            ?? ClaudeStandStorageLocation(
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ClaudeStand", isDirectory: true)
            )
        self.init(
            configuration: configuration,
            authenticator: AuthSession(location: location),
            storageLocation: location
        )
    }

    public init(
        configuration: ClaudeConfiguration = ClaudeConfiguration(),
        authenticator: any ClaudeAuthenticating
    ) {
        self.init(
            configuration: configuration,
            processSessionFactory: {
                ClaudeProcessSession(
                    configuration: configuration,
                    authenticator: authenticator,
                    storageLocation: nil
                )
            }
        )
    }

    public init(
        configuration: ClaudeConfiguration = ClaudeConfiguration(),
        authenticator: any ClaudeAuthenticating,
        storageLocation: ClaudeStandStorageLocation
    ) {
        self.init(
            configuration: configuration,
            processSessionFactory: {
                ClaudeProcessSession(
                    configuration: configuration,
                    authenticator: authenticator,
                    storageLocation: storageLocation
                )
            }
        )
    }

    init(
        configuration: ClaudeConfiguration,
        processSessionFactory: @escaping ProcessSessionFactory
    ) {
        self.configuration = configuration
        self.processSessionFactory = processSessionFactory
    }

    public func start(options: ClaudeConversationOptions = ClaudeConversationOptions()) async throws {
        switch state {
        case .running:
            if options.resumeToken != nil, await conversationRuntime.currentSessionID() != nil {
                throw ClaudeRuntimeError.invalidResumeState
            }
            pendingStartOptions = options
            return
        case .turnActive:
            throw ClaudeRuntimeError.turnInProgress
        case .stopping:
            throw ClaudeRuntimeError.stopping
        case .idle, .stopped, .failed:
            break
        case .starting:
            throw ClaudeRuntimeError.notStarted
        }

        pendingStartOptions = options
        lastFailureMessage = nil
        recentDiagnostics.removeAll(keepingCapacity: true)
        transition(to: .running, reason: "start()")
    }

    public func send(
        prompt: String,
        images: [ImageAttachment] = [],
        options: ClaudeConversationOptions = ClaudeConversationOptions()
    ) async throws -> ClaudeTurnHandle {
        switch state {
        case .idle, .stopped, .failed:
            try await start(options: options)
        case .running:
            break
        case .starting:
            throw ClaudeRuntimeError.notStarted
        case .turnActive:
            throw ClaudeRuntimeError.turnInProgress
        case .stopping:
            throw ClaudeRuntimeError.stopping
        }

        let messageTurn = try await conversationRuntime.beginTurn()
        let activityTurn = try await activityRuntime.beginTurn()
        let processSession = processSessionFactory()
        self.processSession = processSession

        let currentSessionID = await conversationRuntime.currentSessionID()
        if let explicitResumeToken = options.resumeToken {
            let seededResumeToken = pendingStartOptions.resumeToken
            if currentSessionID != nil || seededResumeToken != explicitResumeToken {
                self.processSession = nil
                await conversationRuntime.failTurn(ClaudeRuntimeError.invalidResumeState)
                await activityRuntime.failTurn(ClaudeRuntimeError.invalidResumeState)
                throw ClaudeRuntimeError.invalidResumeState
            }
        }
        let resumeToken = try resolvedResumeToken(
            options: options,
            currentSessionID: currentSessionID
        )
        let inlinePrompt = configuration.prefersInlinePromptTransport && images.isEmpty
            ? prompt
            : nil

        // Build stdin payload before starting the process so it can be
        // pre-queued. BunProcess drains pre-queued stdin during boot,
        // before the CLI's async init reads stdin.
        let stdinPayload: Data?
        if inlinePrompt == nil {
            stdinPayload = try SDKUserMessageBuilder().build(
                prompt: prompt,
                images: images,
                sessionID: currentSessionID
            )
        } else {
            stdinPayload = nil
        }

        await emitRuntimeDiagnostic(
            "turn setup promptChars=\(prompt.count) images=\(images.count) currentSession=\(currentSessionID ?? "<none>") resumeToken=\(resumeToken ?? "<none>") inlinePrompt=\((inlinePrompt != nil).description) stdinPayload=\(stdinPayload?.count ?? 0)bytes cwd=\(configuration.workingDirectory?.path ?? FileManager.default.currentDirectoryPath) model=\(configuration.model ?? "<default>") tools=\(configuration.allowedTools.joined(separator: ","))"
        )

        let streams: ClaudeProcessStreams
        do {
            streams = try await processSession.start(
                resumeToken: resumeToken,
                prompt: inlinePrompt,
                stdinPayload: stdinPayload
            )
        } catch {
            await emitRuntimeDiagnostic("turn start failed error=\(error.localizedDescription)")
            self.processSession = nil
            await failActiveTurn(with: error)
            transition(to: .failed, reason: "start(turn) failed")
            throw error
        }

        attachStreams(streams)
        transition(to: .turnActive, reason: "send()")
        await emitRuntimeDiagnostic("turn process started transport=\(inlinePrompt == nil ? "stdin-stream-json" : "inline-argument")")

        pendingStartOptions = ClaudeConversationOptions()
        return ClaudeTurnHandle(
            messages: messageTurn.stream,
            activity: activityTurn.stream,
            cancelOperation: { [weak self] in
                await self?.cancel()
            }
        )
    }

    public func cancel() async {
        await stop(clearSession: true, reason: "cancel()", failure: ClaudeRuntimeError.cancelled)
    }

    public func shutdown() async {
        await stop(clearSession: true, reason: "shutdown()", failure: nil)
    }

    private func attachStreams(_ streams: ClaudeProcessStreams) {
        stdoutTask?.cancel()
        diagnosticsTask?.cancel()
        exitTask?.cancel()

        stdoutBuffer = ""
        stdoutTask = Task { [weak self] in
            for await chunk in streams.stdout {
                await self?.handleStdoutChunk(chunk)
            }
            await self?.flushStdoutBuffer()
        }

        diagnosticsTask = Task { [weak self] in
            for await line in streams.diagnostics {
                await self?.handleDiagnosticLine(line)
            }
        }

        exitTask = Task { [weak self] in
            for await exit in streams.exits {
                await self?.handleProcessExit(exit)
            }
        }
    }

    private func handleStdoutChunk(_ chunk: String) async {
        stdoutBuffer.append(chunk)
        while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex])
            stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newlineIndex)...])
            await handleStdoutLine(line)
        }
    }

    private func flushStdoutBuffer() async {
        let remaining = stdoutBuffer
        stdoutBuffer = ""
        if !remaining.isEmpty {
            await handleStdoutLine(remaining)
        }
    }

    private func handleStdoutLine(_ line: String) async {
        guard line.isEmpty == false else { return }

        let event: RawClaudeEvent
        do {
            event = try parser.parse(line)
        } catch {
            let message = "Failed to parse stdout line: \(String(line.prefix(240)))"
            await handleProtocolMismatch(message)
            return
        }

        switch event {
        case .ignored:
            return
        case .unknown(let type, let payload):
            await handleProtocolMismatch("Unsupported event type '\(type)': \(payload)")
        case .system(let session):
            await conversationRuntime.updateSession(session)
            await activityRuntime.emitSystem(session)
        case .assistant(let message):
            await conversationRuntime.emitAssistantMessage(message)
            await activityRuntime.emitAssistantToolsIfNeeded(from: message)
        case .result(let result):
            await conversationRuntime.emitResult(result)
            await conversationRuntime.finishTurn()
            await activityRuntime.finishTurn(result: result)
            transition(to: .running, reason: "turn finished")
        case .stream(let stream):
            await handleStreamEvent(stream)
        }
    }

    private func handleStreamEvent(_ stream: RawClaudeStreamEnvelope) async {
        switch stream.event {
        case .messageStart, .messageDelta, .messageStop:
            return
        case .contentBlockStart(let index, let block):
            await activityRuntime.handleContentBlockStart(index: index, block: block)
        case .contentBlockDelta(_, let delta):
            switch delta {
            case .text(let text):
                await conversationRuntime.emitTextDelta(text)
            case .inputJSON:
                if case .contentBlockDelta(let index, let confirmedDelta) = stream.event {
                    await activityRuntime.handleContentBlockDelta(index: index, delta: confirmedDelta)
                }
            case .unknown(let type, let payload):
                await handleProtocolMismatch("Unsupported delta '\(type)': \(payload)")
            }
        case .contentBlockStop(let index):
            await activityRuntime.handleContentBlockStop(index: index)
        case .unknown(let type, let payload):
            await handleProtocolMismatch("Unsupported stream event '\(type)': \(payload)")
        }
    }

    private func handleDiagnosticLine(_ line: String) async {
        recentDiagnostics.append(line)
        if recentDiagnostics.count > 50 {
            recentDiagnostics.removeFirst(recentDiagnostics.count - 50)
        }
        await activityRuntime.emitDiagnostic(line)
    }

    private func handleProcessExit(_ exit: ClaudeProcessExit) async {
        let baseMessage = exit.message.isEmpty ? "cli.js exited" : exit.message
        let diagnosticsSuffix: String
        if recentDiagnostics.isEmpty {
            diagnosticsSuffix = ""
        } else {
            let tail = recentDiagnostics.suffix(12).joined(separator: "\n")
            diagnosticsSuffix = "\nRecent diagnostics:\n\(tail)"
        }
        let message = baseMessage + diagnosticsSuffix
        if configuration.diagnosticsEnabled {
            runtimeLogger.info("process exited: \(message, privacy: .public)")
        }
        var hasActiveTurn = await conversationRuntime.hasActiveTurn()

        // stdout and exit are delivered on separate streams, so process exit can
        // race slightly ahead of the final result event. Let the stdout reducer
        // drain first before treating the exit as a turn failure.
        if hasActiveTurn {
            if let stdoutTask {
                await stdoutTask.value
                hasActiveTurn = await conversationRuntime.hasActiveTurn()
            }

            for _ in 0..<20 {
                await Task.yield()
                hasActiveTurn = await conversationRuntime.hasActiveTurn()
                if hasActiveTurn == false {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    break
                }
            }
        }

        if state == .stopping {
            await conversationRuntime.clearSession()
            transition(to: .stopped, reason: "stopped")
        } else if hasActiveTurn == false {
            if exit.exitCode == 0 {
                transition(to: .running, reason: "turn process exited cleanly")
            } else {
                transition(to: .running, reason: "turn process exited after completion")
            }
        } else {
            lastFailureMessage = message
            // Clear stale session to prevent resume attempts with an
            // inaccessible session ID after an unexpected process exit.
            await conversationRuntime.clearSession()
            await failActiveTurn(with: ClaudeRuntimeError.processExited(message))
            transition(to: .failed, reason: "unexpected exit")
        }

        processSession = nil
        stdoutTask = nil
        diagnosticsTask = nil
        exitTask = nil
    }

    private func handleProtocolMismatch(_ message: String) async {
        let hasActiveTurn = await conversationRuntime.hasActiveTurn()
        if hasActiveTurn {
            await activityRuntime.emitProtocolMismatch(message)
            await failActiveTurn(with: ClaudeRuntimeError.protocolMismatch(message))
            transition(to: .stopping, reason: "protocol mismatch")
            await processSession?.terminate(exitCode: 1)
        } else {
            await activityRuntime.emitWarning(message)
        }
    }

    private func failActiveTurn(with error: Error) async {
        await conversationRuntime.failTurn(error)
        await activityRuntime.failTurn(error)
        if state == .turnActive {
            transition(to: .running, reason: "turn failed")
        }
    }

    private func stop(clearSession: Bool, reason: String, failure: Error?) async {
        transition(to: .stopping, reason: reason)
        if let failure {
            await conversationRuntime.failTurn(failure)
            await activityRuntime.failTurn(failure)
        } else {
            await conversationRuntime.finishTurn()
            await activityRuntime.finishTurn(result: nil)
        }

        if clearSession {
            await conversationRuntime.clearSession()
        }

        if let processSession {
            await processSession.terminate(exitCode: 0)
            await processSession.shutdown()
        }

        if let stdoutTask {
            await stdoutTask.value
            self.stdoutTask = nil
        }
        if let diagnosticsTask {
            await diagnosticsTask.value
            self.diagnosticsTask = nil
        }
        if let exitTask {
            await exitTask.value
            self.exitTask = nil
        }

        processSession = nil
        if state != .failed {
            transition(to: .stopped, reason: reason)
        }
    }

    private func resolvedResumeToken(
        options: ClaudeConversationOptions,
        currentSessionID: String?
    ) throws -> String? {
        if let explicit = options.resumeToken {
            guard currentSessionID == nil else {
                throw ClaudeRuntimeError.invalidResumeState
            }
            return explicit
        }
        if let currentSessionID {
            return currentSessionID
        }
        return pendingStartOptions.resumeToken
    }

    private func transition(to newState: RuntimeState, reason: String) {
        if state == newState { return }
        if configuration.diagnosticsEnabled {
            runtimeLogger.info("state \(self.state.rawValue, privacy: .public) -> \(newState.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        }
        state = newState
    }

    private func emitRuntimeDiagnostic(_ line: String) async {
        guard configuration.diagnosticsEnabled else {
            return
        }
        let formatted = "Runtime diagnostic: [claudestand] \(line)"
        recentDiagnostics.append(formatted)
        if recentDiagnostics.count > 50 {
            recentDiagnostics.removeFirst(recentDiagnostics.count - 50)
        }
        runtimeLogger.info("\(formatted, privacy: .public)")
        await activityRuntime.emitDiagnostic(formatted)
    }
}
