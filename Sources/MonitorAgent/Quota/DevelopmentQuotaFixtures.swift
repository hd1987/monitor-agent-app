import Foundation

struct QuotaFixtureSet {
    let snapshots: [QuotaProviderID: QuotaSnapshot]
    let expirationDates: [QuotaProviderID: Date]
}

enum DevelopmentQuotaFixtures {
    static func make(now: Date = Date()) -> QuotaFixtureSet {
        let hour: TimeInterval = 60 * 60
        let day: TimeInterval = 24 * hour
        return QuotaFixtureSet(
            snapshots: [
                .claude: QuotaSnapshot(
                    provider: .claude,
                    plan: "MAX",
                    fiveHour: QuotaWindow(
                        remainingPercent: 72,
                        resetsAt: now.addingTimeInterval(2 * hour),
                        durationSeconds: 5 * 60 * 60
                    ),
                    weekly: QuotaWindow(
                        remainingPercent: 34,
                        resetsAt: now.addingTimeInterval(4 * day),
                        durationSeconds: 7 * 24 * 60 * 60
                    ),
                    opusWeekly: QuotaWindow(
                        remainingPercent: 8,
                        resetsAt: now.addingTimeInterval(2 * day),
                        durationSeconds: 7 * 24 * 60 * 60
                    ),
                    resetCredits: nil,
                    resetCreditExpirations: [],
                    status: .available,
                    fetchedAt: now
                ),
                .codex: QuotaSnapshot(
                    provider: .codex,
                    plan: "PLUS",
                    fiveHour: QuotaWindow(
                        remainingPercent: 18,
                        resetsAt: now.addingTimeInterval(90 * 60),
                        durationSeconds: 5 * 60 * 60
                    ),
                    weekly: QuotaWindow(
                        remainingPercent: 64,
                        resetsAt: now.addingTimeInterval(5 * day),
                        durationSeconds: 7 * 24 * 60 * 60
                    ),
                    opusWeekly: nil,
                    resetCredits: 3,
                    resetCreditExpirations: [
                        now.addingTimeInterval(2 * day),
                        now.addingTimeInterval(5 * day),
                        now.addingTimeInterval(10 * day),
                    ],
                    status: .available,
                    fetchedAt: now
                ),
            ],
            expirationDates: [
                .claude: now.addingTimeInterval(14 * day),
                .codex: now.addingTimeInterval(6 * day),
            ]
        )
    }
}
