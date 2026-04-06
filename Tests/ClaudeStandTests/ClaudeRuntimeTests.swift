import Foundation
import Synchronization
import Testing
@testable import ClaudeStand

@Suite("ClaudeRuntime")
struct ClaudeRuntimeTests {
    @Test("message stream and activity stream are delivered independently")
    func messageAndActivityStreams() async throws {
        let process = StubProcessSession()
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            process
        }

        let handle = try await runtime.send(prompt: "Inspect the file")
        let messageTask = Task { try await collect(handle.messages) }
        let activityTask = Task { try await collect(handle.activity) }

        await process.emitStdout("""
        {"type":"system","session_id":"sess-1","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await process.emitStdout("""
        {"type":"stream_event","session_id":"sess-1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Working"}}}
        """)
        await process.emitStdout("""
        {"type":"stream_event","session_id":"sess-1","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"main.swift"}}}}
        """)
        await process.emitStdout("""
        {"type":"stream_event","session_id":"sess-1","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"line\\":1}"}}}
        """)
        await process.emitStdout("""
        {"type":"stream_event","session_id":"sess-1","event":{"type":"content_block_stop","index":1}}
        """)
        await process.emitStdout("""
        {"type":"assistant","session_id":"sess-1","message":{"id":"msg-1","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Done"}]},"parent_tool_use_id":null}
        """)
        await process.emitStdout("""
        {"type":"result","session_id":"sess-1","result":"Done","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.001,"duration_ms":50,"num_turns":1}
        """)

        let messages = try await messageTask.value
        let activity = try await activityTask.value

        #expect(messages.count == 4)
        #expect(activity.count >= 4)

        guard case .sessionStarted(let session) = messages[0] else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(session.sessionID == "sess-1")

        guard case .assistantTextDelta(let textDelta) = messages[1] else {
            Issue.record("expected assistantTextDelta")
            return
        }
        #expect(textDelta == "Working")

        guard case .assistantMessage(let assistant) = messages[2] else {
            Issue.record("expected assistantMessage")
            return
        }
        #expect(assistant.messageID == "msg-1")

        guard case .result(let result) = messages[3] else {
            Issue.record("expected result")
            return
        }
        #expect(result.stopReason == "end_turn")

        guard let system = activity.compactMap({ event -> ClaudeSessionDescriptor? in
            if case .system(let session) = event {
                return session
            }
            return nil
        }).first else {
            Issue.record("expected system activity")
            return
        }
        #expect(system.sessionID == "sess-1")

        guard let toolStarted = activity.compactMap({ event -> ClaudeToolInvocation? in
            if case .toolStarted(let invocation) = event {
                return invocation
            }
            return nil
        }).first else {
            Issue.record("expected toolStarted")
            return
        }
        #expect(toolStarted.id == "tool-1")
        #expect(toolStarted.name == "Read")

        guard let toolUpdated = activity.compactMap({ event -> ClaudeToolInvocation? in
            if case .toolUpdated(let invocation) = event {
                return invocation
            }
            return nil
        }).first else {
            Issue.record("expected toolUpdated")
            return
        }
        #expect(toolUpdated.inputJSON.contains(#""line":1"#))

        guard let toolFinished = activity.compactMap({ event -> ClaudeToolResult? in
            if case .toolFinished(let result) = event {
                return result
            }
            return nil
        }).first else {
            Issue.record("expected toolFinished")
            return
        }
        #expect(toolFinished.invocation.id == "tool-1")
    }

    @Test("cancel does not reuse stale session metadata on the next send")
    func cancelClearsSession() async throws {
        let first = StubProcessSession()
        let second = StubProcessSession()
        let factory = StubProcessSessionFactory(processes: [first, second])
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            factory.next()
        }

        let firstHandle = try await runtime.send(prompt: "First prompt")
        let firstMessages = Task { try await collect(firstHandle.messages) }
        let firstActivity = Task { try await collect(firstHandle.activity) }

        await first.emitStdout("""
        {"type":"system","session_id":"sess-old","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await firstHandle.cancel()

        do { _ = try await firstMessages.value } catch {}
        do { _ = try await firstActivity.value } catch {}

        let secondHandle = try await runtime.send(prompt: "Second prompt")
        let secondMessages = Task { try await collect(secondHandle.messages) }
        let secondActivity = Task { try await collect(secondHandle.activity) }
        await second.emitStdout("""
        {"type":"system","session_id":"sess-new","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await second.emitStdout("""
        {"type":"result","session_id":"sess-new","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)

        _ = try await secondMessages.value
        _ = try await secondActivity.value

        // Text-only prompts use inline transport (prefersInlinePromptTransport=true).
        #expect(await first.inlinePrompts == ["First prompt"])
        #expect(await second.inlinePrompts == ["Second prompt"])
        #expect(await first.firstInputString() == nil)
        #expect(await second.firstInputString() == nil)
        #expect(await first.resumeTokens == [nil])
        #expect(await second.resumeTokens == [nil])
    }

    @Test("resume token is only applied when starting a new runtime")
    func explicitResumeOnlyOnStart() async throws {
        let process = StubProcessSession()
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            process
        }

        try await runtime.start(options: ClaudeConversationOptions(resumeToken: "resume-1"))
        #expect(await process.resumeTokens.isEmpty)

        await #expect(throws: ClaudeRuntimeError.self) {
            _ = try await runtime.send(
                prompt: "No inline resume",
                options: ClaudeConversationOptions(resumeToken: "resume-2")
            )
        }

        let handle = try await runtime.send(prompt: "Resumed prompt")
        let messageTask = Task { try await collect(handle.messages) }
        let activityTask = Task { await collectActivity(handle.activity) }

        await process.emitStdout("""
        {"type":"system","session_id":"resume-1","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await process.emitStdout("""
        {"type":"result","session_id":"resume-1","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)

        _ = try await messageTask.value
        _ = await activityTask.value
        #expect(await process.resumeTokens == ["resume-1"])
        // Text-only prompts use inline transport (prefersInlinePromptTransport=true).
        #expect(await process.inlinePrompts == ["Resumed prompt"])
        #expect(await process.firstInputString() == nil)
    }

    @Test("subsequent sends resume the last session over stdin transport")
    func subsequentSendUsesResumeToken() async throws {
        let first = StubProcessSession()
        let second = StubProcessSession()
        let factory = StubProcessSessionFactory(processes: [first, second])
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            factory.next()
        }

        let firstHandle = try await runtime.send(prompt: "First")
        let firstMessages = Task { try await collect(firstHandle.messages) }
        let firstActivity = Task { await collectActivity(firstHandle.activity) }
        await first.emitStdout("""
        {"type":"system","session_id":"sess-continue","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await first.emitStdout("""
        {"type":"result","session_id":"sess-continue","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)
        _ = try await firstMessages.value
        _ = await firstActivity.value

        let secondHandle = try await runtime.send(prompt: "Second")
        let secondMessages = Task { try await collect(secondHandle.messages) }
        let secondActivity = Task { await collectActivity(secondHandle.activity) }
        await second.emitStdout("""
        {"type":"system","session_id":"sess-continue","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await second.emitStdout("""
        {"type":"result","session_id":"sess-continue","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)
        _ = try await secondMessages.value
        _ = await secondActivity.value

        // Text-only prompts use inline transport (prefersInlinePromptTransport=true).
        #expect(await first.inlinePrompts == ["First"])
        #expect(await second.inlinePrompts == ["Second"])
        #expect(await first.firstInputString() == nil)
        #expect(await second.firstInputString() == nil)
        #expect(await first.resumeTokens == [nil])
        #expect(await second.resumeTokens == ["sess-continue"])
    }

    @Test("text prompts use inline transport when no images are present")
    func textPromptUsesInlineTransport() async throws {
        let process = StubProcessSession()
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            process
        }

        let handle = try await runtime.send(prompt: "Hello inline")
        let messageTask = Task { try await collect(handle.messages) }
        let activityTask = Task { await collectActivity(handle.activity) }

        await process.emitStdout("""
        {"type":"system","session_id":"sess-inline","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await process.emitStdout("""
        {"type":"result","session_id":"sess-inline","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)

        _ = try await messageTask.value
        _ = await activityTask.value

        // Text-only prompts use inline transport (prefersInlinePromptTransport=true).
        // No stdin payload is sent — the prompt is passed as a CLI argument.
        #expect(await process.inlinePrompts == ["Hello inline"])
        #expect(await process.firstInputString() == nil)
    }

    @Test("protocol mismatch fails the active turn instead of hanging")
    func protocolMismatchFailsTurn() async throws {
        let process = StubProcessSession()
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            process
        }

        let handle = try await runtime.send(prompt: "Trigger mismatch")
        let messageTask = Task { () -> Error? in
            do {
                _ = try await collect(handle.messages)
                return nil
            } catch {
                return error
            }
        }
        let activityTask = Task {
            await collectActivity(handle.activity)
        }

        await process.emitStdout("""
        {"type":"system","session_id":"sess-mismatch","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await process.emitStdout("""
        {"type":"mystery","session_id":"sess-mismatch","payload":{}}
        """)

        let messageError = try #require(await messageTask.value)
        let activity = await activityTask.value

        #expect(messageError.localizedDescription.contains("protocol mismatch"))
        #expect(activity.contains { event in
            if case .protocolMismatch = event { return true }
            return false
        })
    }

    @Test("clean process exit after a completed turn is not treated as failure")
    func cleanExitAfterCompletedTurn() async throws {
        let process = StubProcessSession()
        let runtime = ClaudeRuntime(configuration: ClaudeConfiguration()) {
            process
        }

        let handle = try await runtime.send(prompt: "Clean exit")
        let messageTask = Task { try await collect(handle.messages) }
        let activityTask = Task { await collectActivity(handle.activity) }

        await process.emitStdout("""
        {"type":"system","session_id":"sess-clean","cwd":"/tmp/project","model":"claude-sonnet-4-6","tools":["Read"],"mcp_servers":[],"permissionMode":"default"}
        """)
        await process.emitStdout("""
        {"type":"result","session_id":"sess-clean","result":"ok","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0,"duration_ms":1,"num_turns":1}
        """)
        await process.emitExit(code: 0, message: "cli.js exited with code 0")

        let messages = try await messageTask.value
        let activity = await activityTask.value

        #expect(messages.contains { event in
            if case .result(let result) = event { return result.result == "ok" }
            return false
        })
        #expect(activity.contains { event in
            if case .system(let session) = event { return session.sessionID == "sess-clean" }
            return false
        })
    }

    private func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
        var events: [T] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func collectActivity(_ stream: AsyncThrowingStream<ClaudeActivityEvent, Error>) async -> [ClaudeActivityEvent] {
        var events: [ClaudeActivityEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch {
        }
        return events
    }
}

private final class StubProcessSessionFactory: Sendable {
    private struct State: Sendable {
        var remaining: [StubProcessSession]
    }
    private let state: Mutex<State>

    init(processes: [StubProcessSession]) {
        self.state = Mutex(State(remaining: processes))
    }

    func next() -> StubProcessSession {
        state.withLock { state in
            if state.remaining.isEmpty {
                return StubProcessSession()
            }
            return state.remaining.removeFirst()
        }
    }
}

private actor StubProcessSession: ClaudeProcessSessioning {
    private let stdoutStream: AsyncStream<String>
    private let diagnosticsStream: AsyncStream<String>
    private let exitStream: AsyncStream<ClaudeProcessExit>
    private let stdoutContinuation: AsyncStream<String>.Continuation
    private let diagnosticsContinuation: AsyncStream<String>.Continuation
    private let exitContinuation: AsyncStream<ClaudeProcessExit>.Continuation

    private var sentInputs: [Data] = []
    private var terminateCalls: [Int32] = []
    private(set) var resumeTokens: [String?] = []
    private(set) var inlinePrompts: [String?] = []
    private var started = false

    init() {
        var stdoutContinuation: AsyncStream<String>.Continuation?
        self.stdoutStream = AsyncStream<String> { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutContinuation = stdoutContinuation!

        var diagnosticsContinuation: AsyncStream<String>.Continuation?
        self.diagnosticsStream = AsyncStream<String> { continuation in
            diagnosticsContinuation = continuation
        }
        self.diagnosticsContinuation = diagnosticsContinuation!

        var exitContinuation: AsyncStream<ClaudeProcessExit>.Continuation?
        self.exitStream = AsyncStream<ClaudeProcessExit> { continuation in
            exitContinuation = continuation
        }
        self.exitContinuation = exitContinuation!
    }

    func start(resumeToken: String?, prompt: String?, stdinPayload: Data? = nil) async throws -> ClaudeProcessStreams {
        resumeTokens.append(resumeToken)
        inlinePrompts.append(prompt)
        if let stdinPayload {
            sentInputs.append(stdinPayload)
        }
        started = true
        return ClaudeProcessStreams(stdout: stdoutStream, diagnostics: diagnosticsStream, exits: exitStream)
    }

    func terminate(exitCode: Int32) async {
        terminateCalls.append(exitCode)
        if exitCode == 0 {
            exitContinuation.yield(.init(exitCode: exitCode, message: "terminated"))
            exitContinuation.finish()
        }
    }

    func shutdown() async {
        stdoutContinuation.finish()
        diagnosticsContinuation.finish()
        exitContinuation.finish()
    }

    func emitStdout(_ line: String) {
        // Real CLI writes NDJSON: each event is a JSON line terminated by \n.
        stdoutContinuation.yield(line.hasSuffix("\n") ? line : line + "\n")
    }

    func emitExit(code: Int32, message: String) {
        stdoutContinuation.finish()
        diagnosticsContinuation.finish()
        exitContinuation.yield(.init(exitCode: code, message: message))
        exitContinuation.finish()
    }

    func firstInputString() -> String? {
        guard let first = sentInputs.first else { return nil }
        return String(decoding: first, as: UTF8.self)
    }
}
