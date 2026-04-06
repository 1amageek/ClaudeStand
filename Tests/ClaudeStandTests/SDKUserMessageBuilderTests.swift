import Testing
import Foundation
@testable import ClaudeStand

@Suite("SDKUserMessageBuilder")
struct SDKUserMessageBuilderTests {

    let builder = SDKUserMessageBuilder()

    @Test("Text-only prompt produces string content")
    func textOnly() throws {
        let data = try builder.build(prompt: "Hello", sessionID: "test-session")
        let json = try parse(data)

        #expect(json["type"] as? String == "user")
        #expect(json["session_id"] as? String == "test-session")

        let message = json["message"] as? [String: Any]
        #expect(message?["role"] as? String == "user")
        #expect(message?["content"] as? String == "Hello")
    }

    @Test("Text-only prompt generates session ID when nil")
    func textOnlyNilSession() throws {
        let data = try builder.build(prompt: "Hi", sessionID: nil)
        let json = try parse(data)

        let sid = json["session_id"] as? String
        #expect(sid != nil)
        #expect(!sid!.isEmpty)
    }

    @Test("Prompt with images produces content block array")
    func withImages() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])  // JPEG magic bytes
        let attachment = ImageAttachment(data: imageData, mediaType: .jpeg)

        let data = try builder.build(prompt: "Describe this", images: [attachment], sessionID: "s1")
        let json = try parse(data)

        let message = json["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        #expect(content != nil)
        #expect(content?.count == 2)

        // First block: text
        #expect(content?[0]["type"] as? String == "text")
        #expect(content?[0]["text"] as? String == "Describe this")

        // Second block: image
        #expect(content?[1]["type"] as? String == "image")
        let source = content?[1]["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/jpeg")
        #expect(source?["data"] as? String == imageData.base64EncodedString())
    }

    @Test("Multiple images produce multiple content blocks")
    func multipleImages() throws {
        let png = ImageAttachment(data: Data([0x89, 0x50]), mediaType: .png)
        let gif = ImageAttachment(data: Data([0x47, 0x49]), mediaType: .gif)

        let data = try builder.build(prompt: "Compare", images: [png, gif], sessionID: "s2")
        let json = try parse(data)

        let message = json["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        #expect(content?.count == 3)  // 1 text + 2 images

        #expect(content?[0]["type"] as? String == "text")
        #expect(content?[1]["type"] as? String == "image")
        #expect(content?[2]["type"] as? String == "image")

        let source1 = content?[1]["source"] as? [String: Any]
        let source2 = content?[2]["source"] as? [String: Any]
        #expect(source1?["media_type"] as? String == "image/png")
        #expect(source2?["media_type"] as? String == "image/gif")
    }

    @Test("parent_tool_use_id is null")
    func parentToolUseIDIsNull() throws {
        let data = try builder.build(prompt: "test", sessionID: "s")
        let json = try parse(data)
        #expect(json["parent_tool_use_id"] is NSNull)
    }

    @Test("Output ends with newline for NDJSON framing")
    func endsWithNewline() throws {
        let data = try builder.build(prompt: "test", sessionID: "s")
        #expect(data.last == 0x0A)
    }

    @Test("Output is valid JSON without trailing newline")
    func validJSON() throws {
        let data = try builder.build(prompt: "test", sessionID: "s")
        // Remove trailing newline and verify valid JSON
        let jsonData = data.dropLast()
        let obj = try JSONSerialization.jsonObject(with: Data(jsonData))
        #expect(obj is [String: Any])
    }

    // MARK: - Round-trip: Builder output → Parser can process the response

    @Test("Built message is compatible with the raw parser")
    func roundTripWithParser() throws {
        let data = try builder.build(prompt: "Hello", sessionID: "rt-session")
        let json = try parse(data)
        #expect(json["type"] as? String == "user")
        let message = json["message"] as? [String: Any]
        #expect(message?["role"] as? String == "user")
        let parser = RawClaudeEventParser()

        let systemLine = """
        {"type":"system","session_id":"rt-session","cwd":"/tmp","model":"test","tools":[],"mcp_servers":[],"permissionMode":"default"}
        """
        let systemEvent = try parser.parse(systemLine)
        guard case .system(let session) = systemEvent else {
            Issue.record("Expected system event")
            return
        }
        #expect(session.sessionID == "rt-session")

        let textLine = """
        {"type":"stream_event","session_id":"rt-session","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi!"}}}
        """
        let textEvent = try parser.parse(textLine)
        guard case .stream(let stream) = textEvent else {
            Issue.record("Expected stream event")
            return
        }
        guard case .contentBlockDelta(_, let delta) = stream.event else {
            Issue.record("Expected text delta")
            return
        }
        #expect(delta == .text("Hi!"))

        let resultLine = """
        {"type":"result","session_id":"rt-session","result":"Hi!","is_error":false,"stop_reason":"end_turn","total_cost_usd":0.001,"duration_ms":50,"num_turns":1}
        """
        let resultEvent = try parser.parse(resultLine)
        guard case .result(let result) = resultEvent else {
            Issue.record("Expected result event")
            return
        }
        #expect(result.sessionID == "rt-session")
        #expect(result.result == "Hi!")
        #expect(result.numTurns == 1)
    }

    @Test("Built image message has valid Anthropic API structure")
    func imageMessageAPIStructure() throws {
        let imageData = Data(repeating: 0xFF, count: 100)
        let attachment = ImageAttachment(data: imageData, mediaType: .png)
        let data = try builder.build(prompt: "Describe", images: [attachment], sessionID: "img-session")
        let json = try parse(data)

        let message = json["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]

        // Verify structure matches Anthropic Messages API content block format
        let imageBlock = content?.first(where: { $0["type"] as? String == "image" })
        #expect(imageBlock != nil)

        let source = imageBlock?["source"] as? [String: Any]
        #expect(source?["type"] as? String == "base64")
        #expect(source?["media_type"] as? String == "image/png")

        let b64 = source?["data"] as? String
        #expect(b64 == imageData.base64EncodedString())

        // Verify round-trip: decode base64 back to original data
        guard let decoded = Data(base64Encoded: b64 ?? "") else {
            Issue.record("Failed to decode base64")
            return
        }
        #expect(decoded == imageData)
    }

    // MARK: - Helpers

    private func parse(_ data: Data) throws -> [String: Any] {
        let jsonData = data.dropLast()  // Remove trailing newline
        let obj = try JSONSerialization.jsonObject(with: Data(jsonData))
        guard let dict = obj as? [String: Any] else {
            Issue.record("Expected dictionary")
            return [:]
        }
        return dict
    }
}
