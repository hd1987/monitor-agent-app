import Foundation

/// Mutable context carried across lines within a single Codex session file.
struct CodexParseContext {
    var sessionId: String?
    var currentModel: String = "gpt-5.5"
    var turnCount: Int = 0
    var lastTotalIn: Int = 0
    var lastTotalOut: Int = 0

    init(
        sessionId: String? = nil,
        currentModel: String = "gpt-5.5",
        turnCount: Int = 0,
        lastTotalIn: Int = 0,
        lastTotalOut: Int = 0
    ) {
        self.sessionId = sessionId
        self.currentModel = currentModel
        self.turnCount = turnCount
        self.lastTotalIn = lastTotalIn
        self.lastTotalOut = lastTotalOut
    }

    init(syncState: SyncState?) {
        self.init(
            sessionId: syncState?.sessionId,
            currentModel: syncState?.model ?? "gpt-5.5",
            turnCount: syncState?.recordCount ?? 0,
            lastTotalIn: syncState?.lastTotalInputTokens ?? 0,
            lastTotalOut: syncState?.lastTotalOutputTokens ?? 0
        )
    }
}

/// Parse Codex JSONL session logs.
/// Token usage lives in `event_msg` records where `payload.type == "token_count"`.
enum CodexLogParser {

    static func parse(lineData: Data, context: inout CodexParseContext) -> ParsedRecord? {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        guard let type = json["type"] as? String,
              let payload = json["payload"] as? [String: Any] else {
            return nil
        }

        switch type {
        case "session_meta":
            context.sessionId = payload["id"] as? String
            return nil

        case "turn_context":
            if let model = payload["model"] as? String {
                context.currentModel = model
            }
            return nil

        case "event_msg":
            guard let payloadType = payload["type"] as? String,
                  payloadType == "token_count" else {
                return nil
            }

            guard let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any] else {
                return nil
            }

            let totalIn = totalUsage["input_tokens"] as? Int ?? 0
            let totalOut = totalUsage["output_tokens"] as? Int ?? 0

            // Skip duplicate heartbeat emissions
            if totalIn == context.lastTotalIn && totalOut == context.lastTotalOut {
                return nil
            }
            context.lastTotalIn = totalIn
            context.lastTotalOut = totalOut
            context.turnCount += 1

            // Extract per-turn usage from last_token_usage if available, else derive delta
            let inputTokens: Int
            let outputTokens: Int
            let cacheRead: Int

            if let lastUsage = info["last_token_usage"] as? [String: Any] {
                inputTokens = lastUsage["input_tokens"] as? Int ?? 0
                outputTokens = lastUsage["output_tokens"] as? Int ?? 0
                cacheRead = lastUsage["cached_input_tokens"] as? Int ?? 0
            } else {
                inputTokens = totalIn
                outputTokens = totalOut
                cacheRead = totalUsage["cached_input_tokens"] as? Int ?? 0
            }

            guard let timestamp = json["timestamp"] as? String,
                  let createdAt = unixSeconds(from: timestamp) else {
                return nil
            }

            let sid = context.sessionId ?? "unknown"
            return ParsedRecord(
                requestId: "codex:\(sid):\(context.turnCount)",
                appType: "codex",
                model: context.currentModel,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: 0,
                sessionId: sid,
                createdAt: createdAt
            )

        default:
            return nil
        }
    }
}
