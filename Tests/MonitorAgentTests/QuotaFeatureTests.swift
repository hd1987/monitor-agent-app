import XCTest
@testable import MonitorAgent

final class QuotaFeatureTests: XCTestCase {
    func testQuotaProviderIconsUseSuppliedSVGAssets() throws {
        XCTAssertEqual(ProviderIconAsset.claudeSourceFileName, "claude.svg")
        XCTAssertEqual(ProviderIconAsset.codexSourceFileName, "chatgpt.svg")
        XCTAssertFalse(try XCTUnwrap(ProviderIconAsset.data(for: .claude)).isEmpty)
        XCTAssertFalse(try XCTUnwrap(ProviderIconAsset.data(for: .codex)).isEmpty)
        XCTAssertFalse(ProviderIconAsset.image(for: .claude).isTemplate)
        XCTAssertTrue(ProviderIconAsset.image(for: .codex).isTemplate)
    }

    func testQuotaCardUsesCompactSingleLineLayout() {
        XCTAssertEqual(QuotaCardLayout.cardHeight, 34)
        XCTAssertEqual(QuotaCardLayout.metricHeight, 20)
        XCTAssertEqual(QuotaCardLayout.horizontalPadding, 12)
        XCTAssertEqual(QuotaCardLayout.contentSpacing, 16)
        XCTAssertEqual(QuotaCardLayout.expirationHoverInset, 8)
        XCTAssertEqual(QuotaCardLayout.metricSpacing, 28)
        XCTAssertLessThan(QuotaCardLayout.metricHeight, QuotaCardLayout.cardHeight)
        XCTAssertEqual(QuotaCardLayout.expirationTipWidth, 200)
        XCTAssertEqual(QuotaCardLayout.resetTipWidth, 220)
        XCTAssertEqual(QuotaCardLayout.resetTipSectionSpacing, 10)
        XCTAssertEqual(QuotaCardLayout.resetTipItemSpacing, 8)
    }

    func testQuotaRemainingStatusThresholds() {
        XCTAssertEqual(QuotaRemaining.status(for: 40.01), .healthy)
        XCTAssertEqual(QuotaRemaining.status(for: 40), .warning)
        XCTAssertEqual(QuotaRemaining.status(for: 10.01), .warning)
        XCTAssertEqual(QuotaRemaining.status(for: 10), .critical)
        XCTAssertEqual(QuotaRemaining.status(for: 9.99), .critical)
    }

    func testResetCreditsCopyUsesExpirationColumnHeading() {
        XCTAssertEqual(ResetCreditsCopy.expiresTitle, "Expires")
    }

    func testSubscriptionExpirationTipUsesCompactColumnHeadings() {
        XCTAssertEqual(SubscriptionExpirationCopy.subscriptionTitle, "Subscription")
        XCTAssertEqual(SubscriptionExpirationCopy.expiresTitle, "Expires")
    }

    func testResetCreditExpirationUsesNearestFutureDate() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nearest = now.addingTimeInterval(2 * 24 * 60 * 60)
        let later = now.addingTimeInterval(5 * 24 * 60 * 60)
        let expired = now.addingTimeInterval(-60)

        XCTAssertEqual(
            ResetCreditExpiration.next(in: [later, expired, nearest], after: now),
            nearest
        )
        XCTAssertNil(ResetCreditExpiration.next(in: [expired], after: now))
    }

    func testResetCreditExpirationStatusUsesCalendarDayThresholds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            ResetCreditExpiration.status(
                for: now.addingTimeInterval(8 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .healthy
        )
        XCTAssertEqual(
            ResetCreditExpiration.status(
                for: now.addingTimeInterval(7 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            ResetCreditExpiration.status(
                for: now.addingTimeInterval(6 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            ResetCreditExpiration.status(
                for: now.addingTimeInterval(4 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            ResetCreditExpiration.status(
                for: now.addingTimeInterval(3 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .critical
        )
    }

    func testResetCreditExpirationStatusIgnoresTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 20,
            hour: 0,
            minute: 1
        )))
        let expiration = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 23,
            hour: 23,
            minute: 59
        )))

        XCTAssertEqual(
            ResetCreditExpiration.status(for: expiration, now: now, calendar: calendar),
            .critical
        )
    }

    func testResetCreditCountStatusUsesNearestFutureExpiration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = now.addingTimeInterval(-60)
        let warning = now.addingTimeInterval(6 * 24 * 60 * 60)
        let standard = now.addingTimeInterval(8 * 24 * 60 * 60)

        XCTAssertEqual(
            ResetCreditExpiration.status(in: [standard, warning, expired], after: now),
            .warning
        )
        XCTAssertEqual(ResetCreditExpiration.status(in: [expired], after: now), .unknown)
    }

    func testCodexDetectionIncludesBundledMacAppExecutables() {
        let paths = QuotaEnvironmentDetector.fixedExecutablePaths(.codex, home: "/Users/test")

        XCTAssertTrue(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Applications/Codex.app/Contents/Resources/codex"))
    }

    func testQuotaEnablementDerivesFromExpirationDate() throws {
        let suiteName = "QuotaFeatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = QuotaSettings(defaults: defaults)
        // No expiration date means the provider is disabled and hidden.
        XCTAssertFalse(settings.isEnabled(.claude))
        XCTAssertFalse(settings.isEnabled(.codex))
        XCTAssertNil(settings.claudeExpirationDate)
        XCTAssertNil(settings.codexExpirationDate)

        let claudeExpiration = Date(timeIntervalSince1970: 1_800_000_000)
        let codexExpiration = Date(timeIntervalSince1970: 1_900_000_000)
        settings.claudeExpirationDate = claudeExpiration
        settings.codexExpirationDate = codexExpiration
        // Setting a date enables the provider.
        XCTAssertTrue(QuotaSettings(defaults: defaults).isEnabled(.claude))
        XCTAssertTrue(QuotaSettings(defaults: defaults).isEnabled(.codex))
        XCTAssertEqual(QuotaSettings(defaults: defaults).claudeExpirationDate, claudeExpiration)
        XCTAssertEqual(QuotaSettings(defaults: defaults).codexExpirationDate, codexExpiration)
        XCTAssertEqual(QuotaSettings(defaults: defaults).expirationDate(for: .claude), claudeExpiration)
        XCTAssertEqual(QuotaSettings(defaults: defaults).expirationDate(for: .codex), codexExpiration)

        // Clearing the date disables the provider again.
        settings.claudeExpirationDate = nil
        XCTAssertNil(QuotaSettings(defaults: defaults).claudeExpirationDate)
        XCTAssertFalse(QuotaSettings(defaults: defaults).isEnabled(.claude))
    }

    func testSubscriptionExpirationUsesCalendarDayDistance() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_783_756_800)

        XCTAssertEqual(
            SubscriptionExpiration.distanceText(
                to: now.addingTimeInterval(3 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            "3 days"
        )
        XCTAssertEqual(
            SubscriptionExpiration.distanceText(to: now, now: now, calendar: calendar),
            "Today"
        )
        XCTAssertEqual(
            SubscriptionExpiration.distanceText(
                to: now.addingTimeInterval(-24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            "1 day ago"
        )
        XCTAssertFalse(SubscriptionExpiration.isExpired(now, now: now, calendar: calendar))
        XCTAssertTrue(SubscriptionExpiration.isExpired(
            now.addingTimeInterval(-24 * 60 * 60),
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(
            SubscriptionExpiration.status(
                for: now.addingTimeInterval(8 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .healthy
        )
        XCTAssertEqual(
            SubscriptionExpiration.status(
                for: now.addingTimeInterval(7 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            SubscriptionExpiration.status(
                for: now.addingTimeInterval(6 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            SubscriptionExpiration.status(
                for: now.addingTimeInterval(4 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .warning
        )
        XCTAssertEqual(
            SubscriptionExpiration.status(
                for: now.addingTimeInterval(3 * 24 * 60 * 60),
                now: now,
                calendar: calendar
            ),
            .critical
        )
    }

    func testRefreshIntervalOptionsAndFallback() throws {
        XCTAssertEqual(
            RefreshInterval.allCases.map(\.displayName),
            ["1 min", "2 min", "5 min", "Never"]
        )
        XCTAssertEqual(RefreshInterval.defaultValue, .oneMinute)
        XCTAssertEqual(RefreshInterval.never.effectiveInterval, 60)

        let suiteName = "QuotaFeatureTests.invalidInterval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(999, forKey: "refreshInterval")

        XCTAssertEqual(RefreshSettings(defaults: defaults).interval, .oneMinute)
    }

    func testNeverRefreshIntervalPersistsAsAValidChoice() throws {
        let suiteName = "QuotaFeatureTests.neverInterval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RefreshSettings(defaults: defaults)
        settings.interval = .never

        XCTAssertEqual(RefreshSettings(defaults: defaults).interval, .never)
    }

    func testRefreshIntervalMigratesLegacySettings() throws {
        let quotaSuiteName = "QuotaFeatureTests.quotaMigration.\(UUID().uuidString)"
        let quotaDefaults = try XCTUnwrap(UserDefaults(suiteName: quotaSuiteName))
        defer { quotaDefaults.removePersistentDomain(forName: quotaSuiteName) }
        quotaDefaults.set(RefreshInterval.fiveMinutes.rawValue, forKey: "quotaRefreshInterval")

        XCTAssertEqual(RefreshSettings(defaults: quotaDefaults).interval, .fiveMinutes)

        let syncSuiteName = "QuotaFeatureTests.syncMigration.\(UUID().uuidString)"
        let syncDefaults = try XCTUnwrap(UserDefaults(suiteName: syncSuiteName))
        defer { syncDefaults.removePersistentDomain(forName: syncSuiteName) }
        syncDefaults.set(30, forKey: "syncInterval")

        XCTAssertEqual(RefreshSettings(defaults: syncDefaults).interval, .oneMinute)
    }

    func testVisibleQuotaProvidersFollowAppFilter() {
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            observeRefreshIntervalChanges: false
        )

        store.appFilter = .all
        XCTAssertEqual(store.visibleQuotaProviders, [.claude, .codex])

        store.appFilter = .claude
        XCTAssertEqual(store.visibleQuotaProviders, [.claude])

        store.appFilter = .codex
        XCTAssertEqual(store.visibleQuotaProviders, [.codex])

        store.appFilter = .cursor
        XCTAssertEqual(store.visibleQuotaProviders, [])
    }

    func testQuotaResetFormatsStayCompactAndSingleLine() {
        let date = Date(timeIntervalSince1970: 1_783_757_400)
        let time = QuotaDateFormat.resetTime(date)
        let dateTime = QuotaDateFormat.resetDateTime(date)

        XCTAssertNotNil(time.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression))
        XCTAssertNotNil(dateTime.range(of: #"^[A-Z][a-z]{2} \d{1,2}, \d{2}:\d{2}$"#, options: .regularExpression))
        XCTAssertFalse(time.contains("\n"))
        XCTAssertFalse(dateTime.contains("\n"))
    }

    func testCodexWindowUsesServerDurationForItsLabel() {
        let weekly = QuotaWindow(
            remainingPercent: 100,
            resetsAt: Date(timeIntervalSince1970: 1_784_510_557),
            durationSeconds: 604_800
        )

        XCTAssertEqual(weekly.remainingPercent, 100)
        XCTAssertEqual(weekly.durationSeconds, 604_800)
        XCTAssertEqual(weekly.displayLabel(fallback: "5h"), "1w")
        XCTAssertTrue(weekly.usesDateTimeReset)
    }
}
