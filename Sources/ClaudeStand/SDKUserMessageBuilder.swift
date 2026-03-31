import Foundation

/// Builds SDKUserMessage JSON for the Claude Code CLI's `--input-format stream-json`.
///
/// The output is a single JSON line (with trailing newline) conforming to the
/// `SDKUserMessage` type from the Agent SDK:
///
///     {"type":"user","session_id":"...","message":{"role":"user","content":...},"parent_tool_use_id":null}
///
/// Text-only prompts use a string for `content`. Prompts with images use
/// an array of content blocks.
struct SDKUserMessageBuilder {

    /// Build an NDJSON line for a text-only prompt.
    func build(prompt: String, sessionID: String?) throws -> Data {
        try build(prompt: prompt, images: [], sessionID: sessionID)
    }

    /// Build an NDJSON line for a prompt with optional images.
    func build(prompt: String, images: [ImageAttachment], sessionID: String?) throws -> Data {
        let sid = sessionID ?? UUID().uuidString

        let content: Any
        if images.isEmpty {
            content = prompt
        } else {
            var blocks: [[String: Any]] = [
                ["type": "text", "text": prompt]
            ]
            for image in images {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.mediaType.rawValue,
                        "data": image.data.base64EncodedString(),
                    ] as [String: Any]
                ])
            }
            content = blocks
        }

        let message: [String: Any] = [
            "type": "user",
            "session_id": sid,
            "message": [
                "role": "user",
                "content": content,
            ] as [String: Any],
            "parent_tool_use_id": NSNull(),
        ]

        let data = try JSONSerialization.data(withJSONObject: message)
        return data + Data([0x0A])  // Newline for NDJSON framing
    }
}
