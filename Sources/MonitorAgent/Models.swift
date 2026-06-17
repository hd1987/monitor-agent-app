import Foundation

// MARK: - Filter

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case claude = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    /// Map to db `app_type` values; nil means no filter
    var dbValues: [String]? {
        switch self {
        case .all: return nil
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        }
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7 = "7 Days"
    case last30 = "30 Days"
    case allTime = "All Time"

    var id: String { rawValue }
}

// MARK: - Display Data

struct UsageStats {
    var totalRequests: Int = 0
    var totalSessions: Int = 0
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheCreationTokens: Int64 = 0

    var cacheHitRate: Double {
        let denominator = Double(inputTokens + cacheReadTokens + cacheCreationTokens)
        guard denominator > 0 else { return 0 }
        return Double(cacheReadTokens) / denominator
    }
}

struct DayActivity: Identifiable {
    let date: String   // "yyyy-MM-dd"
    let count: Int     // request count for that day
    var id: String { date }
}

struct ModelShare: Identifiable {
    let model: String
    let requests: Int
    let inputTokens: Int64
    let outputTokens: Int64
    var id: String { model }
}

// MARK: - Sync Data

struct ParsedRecord {
    let requestId: String       // unique key, e.g. "session:msg_01xxx" or "codex:sid:3"
    let appType: String         // "claude" or "codex"
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let sessionId: String
    let createdAt: Int          // Unix seconds
}

struct SyncState {
    let filePath: String
    var byteOffset: Int64
    var recordCount: Int
    var sessionId: String?
    var model: String?
    var lastModified: Int       // file mtime, Unix seconds
    var lastSyncedAt: Int       // Unix seconds
}

// MARK: - Utilities

/// Shared ISO-8601 formatter supporting fractional seconds
private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Parse ISO-8601 timestamp to Unix seconds
func unixSeconds(from iso8601: String) -> Int? {
    guard let date = iso8601Formatter.date(from: iso8601) else { return nil }
    return Int(date.timeIntervalSince1970)
}
