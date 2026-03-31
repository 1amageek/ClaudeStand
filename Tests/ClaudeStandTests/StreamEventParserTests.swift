import Testing
@testable import ClaudeStand

@Suite("StreamEventParser")
struct StreamEventParserTests {

    let parser = StreamEventParser()

    @Test("Parse system init event")
    func parseSystemInit() throws {
        let json = """
        {"type":"system","session_id":"abc-123","cwd":"/project","model":"claude-sonnet-4-6","tools":["Read","Write"],"mcp_servers":[{"name":"test","status":"connected"}],"permissionMode":"default"}
        """
        let event = try parser.parse(json)
        guard case .system(let sys) = event else {
            Issue.record("Expected system event")
            return
        }
        #expect(sys.sessionID == "abc-123")
        #expect(sys.cwd == "/project")
        #expect(sys.model == "claude-sonnet-4-6")
        #expect(sys.tools == ["Read", "Write"])
        #expect(sys.mcpServers.count == 1)
        #expect(sys.mcpServers[0].name == "test")
        #expect(sys.mcpServers[0].status == "connected")
        #expect(sys.permissionMode == "default")
    }

    @Test("Parse text delta event")
    func parseTextDelta() throws {
        let json = """
        {"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}
        """
        let event = try parser.parse(json)
        guard case .streamEvent(let delta) = event else {
            Issue.record("Expected stream event")
            return
        }
        #expect(delta.sessionID == "abc-123")
        guard case .textDelta(let index, let text) = delta.event else {
            Issue.record("Expected text delta")
            return
        }
        #expect(index == 0)
        #expect(text == "Hello")
    }

    @Test("Parse tool use start event")
    func parseToolUseStart() throws {
        let json = """
        {"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"Read"}}}
        """
        let event = try parser.parse(json)
        guard case .streamEvent(let delta) = event else {
            Issue.record("Expected stream event")
            return
        }
        guard case .toolUseStart(let index, let toolID, let toolName) = delta.event else {
            Issue.record("Expected tool use start")
            return
        }
        #expect(index == 1)
        #expect(toolID == "tool-1")
        #expect(toolName == "Read")
    }

    @Test("Parse assistant message with text and tool_use")
    func parseAssistant() throws {
        let json = """
        {"type":"assistant","session_id":"abc-123","message":{"id":"msg-1","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Let me read that file."},{"type":"tool_use","id":"tu-1","name":"Read","input":{"file_path":"main.swift"}}]},"parent_tool_use_id":null}
        """
        let event = try parser.parse(json)
        guard case .assistant(let msg) = event else {
            Issue.record("Expected assistant event")
            return
        }
        #expect(msg.sessionID == "abc-123")
        #expect(msg.messageID == "msg-1")
        #expect(msg.content.count == 2)

        guard case .text(let text) = msg.content[0] else {
            Issue.record("Expected text block")
            return
        }
        #expect(text == "Let me read that file.")

        guard case .toolUse(let id, let name, let input) = msg.content[1] else {
            Issue.record("Expected tool_use block")
            return
        }
        #expect(id == "tu-1")
        #expect(name == "Read")
        #expect(input.contains("main.swift"))
    }

    @Test("Parse result event")
    func parseResult() throws {
        let json = """
        {"type":"result","session_id":"abc-123","result":"Done.","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.0042,"duration_ms":1500,"num_turns":3}
        """
        let event = try parser.parse(json)
        guard case .result(let res) = event else {
            Issue.record("Expected result event")
            return
        }
        #expect(res.sessionID == "abc-123")
        #expect(res.result == "Done.")
        #expect(res.isError == false)
        #expect(res.stopReason == "end_turn")
        #expect(res.totalCostUSD == 0.0042)
        #expect(res.durationMS == 1500)
        #expect(res.numTurns == 3)
    }

    @Test("Parse message lifecycle events")
    func parseMessageLifecycle() throws {
        let events: [(String, (DeltaEvent) -> Bool)] = [
            ("""
            {"type":"stream_event","session_id":"s","event":{"type":"message_start"}}
            """, { if case .messageStart = $0 { return true }; return false }),
            ("""
            {"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0}}
            """, { if case .contentBlockStart(0) = $0 { return true }; return false }),
            ("""
            {"type":"stream_event","session_id":"s","event":{"type":"content_block_stop","index":0}}
            """, { if case .contentBlockStop(0) = $0 { return true }; return false }),
            ("""
            {"type":"stream_event","session_id":"s","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}
            """, { if case .messageDelta(let r) = $0 { return r == "end_turn" }; return false }),
            ("""
            {"type":"stream_event","session_id":"s","event":{"type":"message_stop"}}
            """, { if case .messageStop = $0 { return true }; return false }),
        ]

        for (json, check) in events {
            let event = try parser.parse(json)
            guard case .streamEvent(let delta) = event else {
                Issue.record("Expected stream event for: \(json.prefix(50))")
                continue
            }
            #expect(check(delta.event), "Failed check for: \(json.prefix(50))")
        }
    }

    @Test("Ignored types throw ignoredType error")
    func ignoredTypes() {
        let json = """
        {"type":"user","session_id":"s","message":{}}
        """
        #expect(throws: StreamEventParser.ParserError.self) {
            try parser.parse(json)
        }
    }

    @Test("Missing type field throws missingType error")
    func missingType() {
        let json = """
        {"session_id":"s","data":"something"}
        """
        #expect(throws: StreamEventParser.ParserError.self) {
            try parser.parse(json)
        }
    }
}
