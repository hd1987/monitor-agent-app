import XCTest
@testable import MonitorAgent

final class QuotaFeatureTests: XCTestCase {
    func testQuotaCardUsesCompactSingleLineLayout() {
        XCTAssertEqual(QuotaCardLayout.cardHeight, 34)
        XCTAssertEqual(QuotaCardLayout.metricHeight, 20)
        XCTAssertEqual(QuotaCardLayout.contentSpacing, 16)
        XCTAssertEqual(QuotaCardLayout.metricSpacing, 28)
        XCTAssertLessThan(QuotaCardLayout.metricHeight, QuotaCardLayout.cardHeight)
        XCTAssertEqual(QuotaCardLayout.resetTipWidth, 280)
    }

    func testResetCreditsCopyDescribesAvailabilityWithoutAnAction() {
        XCTAssertEqual(ResetCreditsCopy.availableCount(3), "3 available")
        XCTAssertEqual(ResetCreditsCopy.fullReset, "Full reset (1w + 5h)")
        XCTAssertEqual(ResetCreditsCopy.expires("Jul 18, 08:00"), "Expires Jul 18, 08:00")
    }

    func testCodexDetectionIncludesBundledMacAppExecutables() {
        let paths = QuotaEnvironmentDetector.fixedExecutablePaths(.codex, home: "/Users/test")

        XCTAssertTrue(paths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/Applications/Codex.app/Contents/Resources/codex"))
    }

    func testQuotaSettingsDefaultToEnabledAndPersistIndependently() throws {
        let suiteName = "QuotaFeatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = QuotaSettings(defaults: defaults)
        XCTAssertTrue(settings.claudeEnabled)
        XCTAssertTrue(settings.codexEnabled)
        XCTAssertEqual(settings.refreshInterval, .twoMinutes)

        settings.claudeEnabled = false
        settings.refreshInterval = .fiveMinutes
        XCTAssertFalse(QuotaSettings(defaults: defaults).claudeEnabled)
        XCTAssertTrue(QuotaSettings(defaults: defaults).codexEnabled)
        XCTAssertEqual(QuotaSettings(defaults: defaults).refreshInterval, .fiveMinutes)
    }

    func testQuotaRefreshIntervalOptionsAndFallback() throws {
        XCTAssertEqual(
            QuotaRefreshInterval.allCases.map(\.displayName),
            ["1 min", "2 min", "5 min", "Never"]
        )
        XCTAssertEqual(QuotaRefreshInterval.never.minimumRequestInterval, 120)

        let suiteName = "QuotaFeatureTests.invalidInterval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(999, forKey: "quotaRefreshInterval")

        XCTAssertEqual(QuotaSettings(defaults: defaults).refreshInterval, .twoMinutes)
    }

    func testNeverQuotaRefreshIntervalPersistsAsAValidChoice() throws {
        let suiteName = "QuotaFeatureTests.neverInterval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = QuotaSettings(defaults: defaults)
        settings.refreshInterval = .never

        XCTAssertEqual(QuotaSettings(defaults: defaults).refreshInterval, .never)
    }

    func testQuotaRefreshThrottleUsesDynamicIntervalPerProvider() {
        var throttle = QuotaRefreshThrottle()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(throttle.allowsRefresh(
            provider: .claude,
            minimumInterval: 120,
            force: false,
            now: start
        ))
        XCTAssertFalse(throttle.allowsRefresh(
            provider: .claude,
            minimumInterval: 120,
            force: false,
            now: start.addingTimeInterval(119)
        ))
        XCTAssertTrue(throttle.allowsRefresh(
            provider: .claude,
            minimumInterval: 120,
            force: false,
            now: start.addingTimeInterval(120)
        ))
        XCTAssertTrue(throttle.allowsRefresh(
            provider: .codex,
            minimumInterval: 120,
            force: false,
            now: start.addingTimeInterval(1)
        ))
    }

    func testVisibleQuotaProvidersFollowAppFilter() {
        let store = AppStore(observeSyncIntervalChanges: false)

        store.appFilter = .all
        XCTAssertEqual(store.visibleQuotaProviders, [.claude, .codex])

        store.appFilter = .claude
        XCTAssertEqual(store.visibleQuotaProviders, [.claude])

        store.appFilter = .codex
        XCTAssertEqual(store.visibleQuotaProviders, [.codex])
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
