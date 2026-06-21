import XCTest
@testable import MonitorAgent

final class CodexSyncStateTests: XCTestCase {
    func testSyncStatePersistsCodexLastTokenTotals() {
        let database = DatabaseManager(inMemory: true)
        let state = SyncState(
            filePath: "/tmp/codex-session.jsonl",
            byteOffset: 128,
            recordCount: 4,
            sessionId: "session-1",
            model: "gpt-5.5",
            lastModified: 1_782_000_000,
            lastSyncedAt: 1_782_000_100,
            lastTotalInputTokens: 136_644,
            lastTotalOutputTokens: 2_760
        )

        database.updateSyncState(state)

        let restored = database.getSyncState(for: state.filePath)
        XCTAssertEqual(restored?.lastTotalInputTokens, 136_644)
        XCTAssertEqual(restored?.lastTotalOutputTokens, 2_760)
    }

    func testCodexContextRestoredFromSyncStateSkipsCrossBatchHeartbeat() throws {
        let state = SyncState(
            filePath: "/tmp/codex-session.jsonl",
            byteOffset: 128,
            recordCount: 4,
            sessionId: "session-1",
            model: "gpt-5.5",
            lastModified: 1_782_000_000,
            lastSyncedAt: 1_782_000_100,
            lastTotalInputTokens: 136_644,
            lastTotalOutputTokens: 2_760
        )
        var context = CodexParseContext(syncState: state)

        let heartbeat = codexTokenCountLine(
            timestamp: "2026-06-20T14:19:59.546Z",
            totalInput: 136_644,
            totalOutput: 2_760,
            lastInput: 0,
            lastOutput: 0,
            lastCacheRead: 0
        )
        let nextTurn = codexTokenCountLine(
            timestamp: "2026-06-20T14:20:14.254Z",
            totalInput: 175_245,
            totalOutput: 3_461,
            lastInput: 38_601,
            lastOutput: 701,
            lastCacheRead: 4_992
        )

        XCTAssertNil(CodexLogParser.parse(lineData: heartbeat, context: &context))
        let record = try XCTUnwrap(CodexLogParser.parse(lineData: nextTurn, context: &context))

        XCTAssertEqual(record.requestId, "codex:session-1:5")
        XCTAssertEqual(record.inputTokens, 38_601)
        XCTAssertEqual(record.outputTokens, 701)
        XCTAssertEqual(record.cacheReadTokens, 4_992)
        XCTAssertEqual(context.lastTotalIn, 175_245)
        XCTAssertEqual(context.lastTotalOut, 3_461)
    }

    private func codexTokenCountLine(
        timestamp: String,
        totalInput: Int,
        totalOutput: Int,
        lastInput: Int,
        lastOutput: Int,
        lastCacheRead: Int
    ) -> Data {
        let json: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": totalInput,
                        "output_tokens": totalOutput,
                    ],
                    "last_token_usage": [
                        "input_tokens": lastInput,
                        "output_tokens": lastOutput,
                        "cached_input_tokens": lastCacheRead,
                    ],
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}
