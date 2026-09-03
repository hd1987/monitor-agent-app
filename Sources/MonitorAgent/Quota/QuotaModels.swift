import Foundation

enum QuotaProviderID: String, CaseIterable, Hashable {
    case claude
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

struct QuotaUsageAmount: Equatable {
    let usedCents: Int
    let limitCents: Int
}

struct QuotaWindow: Equatable {
    let remainingPercent: Double
    let resetsAt: Date?
    let durationSeconds: Int?
    let usageAmount: QuotaUsageAmount?

    init(
        remainingPercent: Double,
        resetsAt: Date?,
        durationSeconds: Int?,
        usageAmount: QuotaUsageAmount? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
        self.usageAmount = usageAmount
    }

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

enum QuotaRefreshPhase: Equatable {
    case idle
    case refreshing
    case failed(status: QuotaSnapshotStatus, attemptedAt: Date)
}

struct QuotaRefreshResult: Equatable {
    let snapshot: QuotaSnapshot
    let identityDigest: String?
    let resetCreditsUpdate: ResetCreditsUpdate

    init(
        snapshot: QuotaSnapshot,
        identityDigest: String?,
        resetCreditsUpdate: ResetCreditsUpdate = .notApplicable
    ) {
        self.snapshot = snapshot
        self.identityDigest = identityDigest
        self.resetCreditsUpdate = resetCreditsUpdate
    }
}

enum ResetCreditsUpdate: Equatable {
    case notApplicable
    case notUpdated
    case authoritative(ResetCreditsState)
}

struct ResetCreditsState: Equatable {
    let count: Int
    let expirations: [Date]

    static func authoritative(
        count: Int?,
        expirations: [Date],
        now: Date
    ) -> ResetCreditsState? {
        guard let count, count >= 0 else { return nil }
        if count == 0 {
            guard expirations.isEmpty else { return nil }
            return ResetCreditsState(count: 0, expirations: [])
        }
        let sortedExpirations = expirations.sorted()
        guard sortedExpirations.count == count,
              sortedExpirations.allSatisfy({ $0 > now }) else { return nil }
        return ResetCreditsState(count: count, expirations: sortedExpirations)
    }

    static func restored(
        count: Int?,
        expirations: [Date],
        now: Date
    ) -> ResetCreditsState? {
        guard let count, count >= 0 else { return nil }
        if count == 0 {
            guard expirations.isEmpty else { return nil }
            return ResetCreditsState(count: 0, expirations: [])
        }
        guard expirations.count == count else { return nil }
        let futureExpirations = expirations.filter { $0 > now }.sorted()
        return ResetCreditsState(
            count: futureExpirations.count,
            expirations: futureExpirations
        )
    }
}

struct QuotaSnapshot: Equatable {
    let provider: QuotaProviderID
    let plan: String?
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
    let opusWeekly: QuotaWindow?
    let monthly: QuotaWindow?
    let resetCredits: Int?
    let resetCreditExpirations: [Date]
    let status: QuotaSnapshotStatus
    let fetchedAt: Date

    init(
        provider: QuotaProviderID,
        plan: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        opusWeekly: QuotaWindow?,
        monthly: QuotaWindow? = nil,
        resetCredits: Int?,
        resetCreditExpirations: [Date],
        status: QuotaSnapshotStatus,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.plan = plan
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.opusWeekly = opusWeekly
        self.monthly = monthly
        self.resetCredits = resetCredits
        self.resetCreditExpirations = resetCreditExpirations
        self.status = status
        self.fetchedAt = fetchedAt
    }

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
            monthly: nil,
            resetCredits: nil,
            resetCreditExpirations: [],
            status: status,
            fetchedAt: date
        )
    }

    func replacingResetCredits(with state: ResetCreditsState?) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            plan: plan,
            fiveHour: fiveHour,
            weekly: weekly,
            opusWeekly: opusWeekly,
            monthly: monthly,
            resetCredits: state?.count,
            resetCreditExpirations: state?.expirations ?? [],
            status: status,
            fetchedAt: fetchedAt
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

    static func updateDateTime(_ date: Date) -> String {
        updateDateTimeFormatter.string(from: date)
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

    private static let updateDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()
}
