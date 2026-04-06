import Foundation

struct RawClaudeEventParser {
    func parse(_ line: String) throws -> RawClaudeEvent {
        guard let data = line.data(using: .utf8) else {
            throw ParserError.invalidEncoding
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            throw ParserError.invalidTopLevelObject
        }
        guard let type = json["type"] as? String else {
            throw ParserError.missingType
        }

        switch type {
        case "system":
            return .system(try parseSystem(json))
        case "assistant":
            return .assistant(try parseAssistant(json))
        case "result":
            return .result(try parseResult(json))
        case "stream_event":
            return .stream(try parseStreamEnvelope(json))
        case "user", "rate_limit_event":
            return .ignored(type: type)
        default:
            return .unknown(type: type, payload: serializeJSON(json))
        }
    }

    private func parseSystem(_ json: [String: Any]) throws -> ClaudeSessionDescriptor {
        ClaudeSessionDescriptor(
            sessionID: try string(json, key: "session_id"),
            cwd: json["cwd"] as? String ?? "",
            model: json["model"] as? String ?? "",
            tools: json["tools"] as? [String] ?? [],
            mcpServers: (json["mcp_servers"] as? [[String: Any]] ?? []).map {
                ClaudeMCPServerStatus(name: $0["name"] as? String ?? "", status: $0["status"] as? String ?? "")
            },
            permissionMode: json["permissionMode"] as? String ?? ""
        )
    }

    private func parseAssistant(_ json: [String: Any]) throws -> ClaudeAssistantMessage {
        let message = try dictionary(json, key: "message")
        let rawContent = message["content"] as? [[String: Any]] ?? []
        return ClaudeAssistantMessage(
            sessionID: try string(json, key: "session_id"),
            messageID: message["id"] as? String ?? "",
            model: message["model"] as? String ?? "",
            content: rawContent.map(parseAssistantContent),
            parentToolUseID: json["parent_tool_use_id"] as? String
        )
    }

    private func parseAssistantContent(_ content: [String: Any]) -> ClaudeAssistantContent {
        let type = content["type"] as? String ?? "unknown"
        switch type {
        case "text":
            return .text(content["text"] as? String ?? "")
        case "tool_use":
            return .toolUse(
                id: content["id"] as? String ?? "",
                name: content["name"] as? String ?? "",
                inputJSON: serializeJSON(content["input"])
            )
        default:
            return .unknown(type: type, payload: serializeJSON(content))
        }
    }

    private func parseResult(_ json: [String: Any]) throws -> ClaudeResultSummary {
        ClaudeResultSummary(
            sessionID: try string(json, key: "session_id"),
            result: json["result"] as? String ?? "",
            isError: json["is_error"] as? Bool ?? false,
            stopReason: json["stop_reason"] as? String ?? "",
            totalCostUSD: json["total_cost_usd"] as? Double ?? 0,
            durationMS: json["duration_ms"] as? Int ?? 0,
            numTurns: json["num_turns"] as? Int ?? 0
        )
    }

    private func parseStreamEnvelope(_ json: [String: Any]) throws -> RawClaudeStreamEnvelope {
        let eventJSON = try dictionary(json, key: "event")
        let eventType = eventJSON["type"] as? String ?? "unknown"
        return RawClaudeStreamEnvelope(
            sessionID: json["session_id"] as? String,
            parentToolUseID: json["parent_tool_use_id"] as? String,
            event: parseStreamEvent(type: eventType, eventJSON: eventJSON)
        )
    }

    private func parseStreamEvent(type: String, eventJSON: [String: Any]) -> RawClaudeStreamEvent {
        switch type {
        case "message_start":
            return .messageStart
        case "content_block_start":
            let block = (eventJSON["content_block"] as? [String: Any]).map(parseContentBlock)
            return .contentBlockStart(index: eventJSON["index"] as? Int ?? 0, block: block)
        case "content_block_delta":
            let deltaJSON = eventJSON["delta"] as? [String: Any] ?? [:]
            let deltaType = deltaJSON["type"] as? String ?? "unknown"
            return .contentBlockDelta(
                index: eventJSON["index"] as? Int ?? 0,
                delta: parseContentDelta(type: deltaType, deltaJSON: deltaJSON)
            )
        case "content_block_stop":
            return .contentBlockStop(index: eventJSON["index"] as? Int ?? 0)
        case "message_delta":
            let deltaJSON = eventJSON["delta"] as? [String: Any] ?? [:]
            return .messageDelta(stopReason: deltaJSON["stop_reason"] as? String)
        case "message_stop":
            return .messageStop
        default:
            return .unknown(type: type, payload: serializeJSON(eventJSON))
        }
    }

    private func parseContentBlock(_ json: [String: Any]) -> RawClaudeContentBlock {
        let type = json["type"] as? String ?? "unknown"
        switch type {
        case "text":
            return .text(json["text"] as? String ?? "")
        case "tool_use":
            return .toolUse(
                id: json["id"] as? String ?? "",
                name: json["name"] as? String ?? "",
                inputJSON: serializeJSON(json["input"])
            )
        default:
            return .unknown(type: type, payload: serializeJSON(json))
        }
    }

    private func parseContentDelta(type: String, deltaJSON: [String: Any]) -> RawClaudeContentDelta {
        switch type {
        case "text_delta":
            return .text(deltaJSON["text"] as? String ?? "")
        case "input_json_delta":
            return .inputJSON(deltaJSON["partial_json"] as? String ?? "")
        default:
            return .unknown(type: type, payload: serializeJSON(deltaJSON))
        }
    }

    private func string(_ json: [String: Any], key: String) throws -> String {
        guard let value = json[key] as? String else {
            throw ParserError.missingField(key)
        }
        return value
    }

    private func dictionary(_ json: [String: Any], key: String) throws -> [String: Any] {
        guard let value = json[key] as? [String: Any] else {
            throw ParserError.missingField(key)
        }
        return value
    }

    private func serializeJSON(_ value: Any?) -> String {
        guard let value else { return "null" }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "\"<unserializable>\""
        }
    }

    enum ParserError: Error, Equatable {
        case invalidEncoding
        case invalidTopLevelObject
        case missingType
        case missingField(String)
    }
}
