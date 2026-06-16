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
        case .claude: return ["claude", "claude-desktop"]
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

// MARK: - Data

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
