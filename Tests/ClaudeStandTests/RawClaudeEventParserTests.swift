import Testing
@testable import ClaudeStand

@Suite("RawClaudeEventParser")
struct RawClaudeEventParserTests {
    let parser = RawClaudeEventParser()

    @Test("parses system event")
    func parseSystem() throws {
        let event = try parser.parse("""
        {"type":"system","session_id":"abc-123","cwd":"/project","model":"claude-sonnet-4-6","tools":["Read","Write"],"mcp_servers":[{"name":"test","status":"connected"}],"permissionMode":"default"}
        """)

        guard case .system(let session) = event else {
            Issue.record("expected system")
            return
        }
        #expect(session.sessionID == "abc-123")
        #expect(session.tools == ["Read", "Write"])
    }

    @Test("parses text delta and input json delta")
    func parseStreamDeltas() throws {
        let text = try parser.parse("""
        {"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}
        """)
        let input = try parser.parse("""
        {"type":"stream_event","session_id":"abc-123","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"main.swift\\"}"}}}
        """)

        guard case .stream(let textEnvelope) = text else {
            Issue.record("expected stream text")
            return
        }
        guard case .contentBlockDelta(let index, let delta) = textEnvelope.event else {
            Issue.record("expected contentBlockDelta")
            return
        }
        #expect(index == 0)
        #expect(delta == .text("Hello"))

        guard case .stream(let inputEnvelope) = input else {
            Issue.record("expected stream input")
            return
        }
        guard case .contentBlockDelta(let inputIndex, let inputDelta) = inputEnvelope.event else {
            Issue.record("expected contentBlockDelta")
            return
        }
        #expect(inputIndex == 1)
        #expect(inputDelta == .inputJSON(#"{"path":"main.swift"}"#))
    }

    @Test("parses assistant tool use content")
    func parseAssistant() throws {
        let event = try parser.parse("""
        {"type":"assistant","session_id":"abc-123","message":{"id":"msg-1","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Let me read that file."},{"type":"tool_use","id":"tu-1","name":"Read","input":{"file_path":"main.swift"}}]},"parent_tool_use_id":null}
        """)

        guard case .assistant(let message) = event else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.messageID == "msg-1")
        #expect(message.content.count == 2)
    }

    @Test("unknown types are preserved")
    func unknownType() throws {
        let event = try parser.parse("""
        {"type":"unexpected","session_id":"abc-123","payload":{"x":1}}
        """)

        guard case .unknown(let type, let payload) = event else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "unexpected")
        #expect(payload.contains(#""x":1"#))
    }

    @Test("missing type still fails fast")
    func missingType() {
        #expect(throws: RawClaudeEventParser.ParserError.self) {
            _ = try parser.parse(#"{"session_id":"abc-123"}"#)
        }
    }
}
