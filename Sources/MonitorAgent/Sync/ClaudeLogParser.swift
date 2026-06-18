import Foundation

/// Parse Claude Code JSONL session logs.
/// Each assistant message contains token usage in `message.usage`.
enum ClaudeLogParser {

    static func parse(lineData: Data) -> ParsedRecord? {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        // Only assistant messages carry usage data
        guard let type = json["type"] as? String, type == "assistant" else {
            return nil
        }

        guard let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let msgId = message["id"] as? String else {
            return nil
        }

        guard let sessionId = json["sessionId"] as? String,
              let timestamp = json["timestamp"] as? String,
              let createdAt = unixSeconds(from: timestamp) else {
            return nil
        }

        let model = message["model"] as? String ?? "unknown"

        // Skip synthetic messages (internal placeholder, zero tokens)
        if model.hasPrefix("<") && model.hasSuffix(">") { return nil }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0

        return ParsedRecord(
            requestId: "session:\(msgId)",
            appType: "claude",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            sessionId: sessionId,
            createdAt: createdAt
        )
    }
}
