import Foundation

enum QuotaProviderID: String, CaseIterable, Hashable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

struct QuotaWindow: Equatable {
    let remainingPercent: Double
    let resetsAt: Date?
    let durationSeconds: Int?

    func displayLabel(fallback: String) -> String {
        guard let durationSeconds else { return fallback }
        if durationSeconds % 604_800 == 0 {
            return "\(durationSeconds / 604_800)w"
        }
        if durationSeconds % 86_400 == 0 {
            return "\(durationSeconds / 86_400)d"
        }
        if durationSeconds % 3_600 == 0 {
            return "\(durationSeconds / 3_600)h"
        }
        return fallback
    }

    var usesDateTimeReset: Bool {
        (durationSeconds ?? 0) >= 86_400
    }
}

enum QuotaSnapshotStatus: Equatable {
    case available
    case notInstalled
    case thirdPartyConfigured
    case signedOut
    case authenticationExpired
    case unavailable(String)
}

struct QuotaSnapshot: Equatable {
    let provider: QuotaProviderID
    let plan: String?
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
    let opusWeekly: QuotaWindow?
    let resetCredits: Int?
    let resetCreditExpirations: [Date]
    let status: QuotaSnapshotStatus
    let fetchedAt: Date

    static func failure(
        provider: QuotaProviderID,
        status: QuotaSnapshotStatus,
        at date: Date = Date()
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            plan: nil,
            fiveHour: nil,
            weekly: nil,
            opusWeekly: nil,
            resetCredits: nil,
            resetCreditExpirations: [],
            status: status,
            fetchedAt: date
        )
    }
}

enum QuotaDateFormat {
    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return timeFormatter.string(from: date)
    }

    static func resetDateTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return dateTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}
