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

struct TimeBounds: Equatable {
    let start: Int?
    let end: Int?
}

struct CalendarRangeSelection: Equatable {
    var start: Date?
    var end: Date?
    private var isComplete = false

    init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
        self.isComplete = start != nil && end != nil
    }

    mutating func select(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)

        if start == nil || isComplete {
            start = day
            end = day
            isComplete = false
            return
        }

        guard let currentStart = start else { return }
        start = min(currentStart, day)
        end = max(currentStart, day)
        isComplete = true
    }
}

enum TimeRange: Equatable, Identifiable {
    case today
    case last7
    case last30
    case allTime
    case custom(start: Date, end: Date)

    static let presets: [TimeRange] = [.today, .last7, .last30, .allTime]

    static func activityDay(_ dateString: String, calendar: Calendar = .current) -> TimeRange? {
        let parts = dateString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        guard let date = calendar.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2]
        )) else {
            return nil
        }

        let day = calendar.startOfDay(for: date)
        return .custom(start: day, end: day)
    }

    var id: String {
        switch self {
        case .today: return "today"
        case .last7: return "last7"
        case .last30: return "last30"
        case .allTime: return "allTime"
        case .custom(let start, let end):
            return "custom-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))"
        }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .last7: return "7 Days"
        case .last30: return "30 Days"
        case .allTime: return "All Time"
        case .custom: return "Custom"
        }
    }

    func bounds(now: Date = Date(), calendar: Calendar = .current) -> TimeBounds {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        switch self {
        case .today:
            return TimeBounds(
                start: Int(today.timeIntervalSince1970),
                end: Int(tomorrow.timeIntervalSince1970)
            )
        case .last7:
            let start = calendar.date(byAdding: .day, value: -6, to: today)!
            return TimeBounds(
                start: Int(start.timeIntervalSince1970),
                end: Int(tomorrow.timeIntervalSince1970)
            )
        case .last30:
            let start = calendar.date(byAdding: .day, value: -29, to: today)!
            return TimeBounds(
                start: Int(start.timeIntervalSince1970),
                end: Int(tomorrow.timeIntervalSince1970)
            )
        case .allTime:
            return TimeBounds(start: nil, end: nil)
        case .custom(let start, let end):
            let normalizedStart = calendar.startOfDay(for: min(start, end))
            let normalizedEnd = calendar.startOfDay(for: max(start, end))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: normalizedEnd)!
            return TimeBounds(
                start: Int(normalizedStart.timeIntervalSince1970),
                end: Int(exclusiveEnd.timeIntervalSince1970)
            )
        }
    }

    func displayTitle(now: Date = Date(), formatter: DateFormatter, calendar: Calendar = .current) -> String {
        switch self {
        case .today:
            return title
        case .last7, .last30:
            let bounds = bounds(now: now, calendar: calendar)
            guard
                let start = bounds.start,
                let end = bounds.end,
                let endDate = calendar.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: TimeInterval(end)))
            else {
                return title
            }
            return "\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(start)))) - \(formatter.string(from: endDate))"
        case .allTime:
            return title
        case .custom(let start, let end):
            let normalizedStart = min(start, end)
            let normalizedEnd = max(start, end)
            if calendar.isDate(normalizedStart, inSameDayAs: normalizedEnd) {
                return formatter.string(from: normalizedStart)
            }
            return "\(formatter.string(from: normalizedStart)) - \(formatter.string(from: normalizedEnd))"
        }
    }
}

// MARK: - Heatmap Mode

enum HeatmapMode: Hashable {
    case trailing
    case year(Int)
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

struct HourlyTokenUsage: Identifiable, Equatable {
    let hour: Int
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    var id: Int { hour }

    var hasTokenUsage: Bool {
        inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0
    }
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
    var lastTotalInputTokens: Int = 0
    var lastTotalOutputTokens: Int = 0
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
