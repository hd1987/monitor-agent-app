import AppKit
import SwiftUI
import XCTest
@testable import MonitorAgent

final class QuotaFeatureTests: XCTestCase {
    func testQuotaProviderIconsUseSuppliedSVGAssets() throws {
        XCTAssertFalse(try XCTUnwrap(ProviderIconAsset.data(for: .claude)).isEmpty)
        XCTAssertFalse(try XCTUnwrap(ProviderIconAsset.data(for: .codex)).isEmpty)
        XCTAssertTrue(ProviderIconAsset.image(for: .claude).isTemplate)
        XCTAssertTrue(ProviderIconAsset.image(for: .codex).isTemplate)
    }

    func testQuotaCardUsesCompactSingleLineLayout() {
        XCTAssertEqual(QuotaCardLayout.cardHeight, 34)
        XCTAssertEqual(QuotaCardLayout.metricHeight, 20)
        XCTAssertEqual(QuotaCardLayout.horizontalPadding, 12)
        XCTAssertEqual(QuotaCardLayout.contentSpacing, 16)
        XCTAssertEqual(QuotaCardLayout.metricSpacing, 28)
        XCTAssertLessThan(QuotaCardLayout.metricHeight, QuotaCardLayout.cardHeight)
        XCTAssertEqual(QuotaCardLayout.detailsTipWidth, 280)
        XCTAssertEqual(QuotaCardLayout.detailsTipSectionSpacing, 10)
        XCTAssertEqual(QuotaCardLayout.detailsTipItemSpacing, 8)
        XCTAssertEqual(QuotaCardLayout.tipHoverBridgeHeight, 6)
    }

    func testQuotaRefreshStatesDoNotChangeCardLayout() {
        let snapshot = QuotaSnapshot(
            provider: .codex,
            plan: "PLUS",
            fiveHour: QuotaWindow(
                remainingPercent: 80,
                resetsAt: Date(timeIntervalSince1970: 1_800_003_600),
                durationSeconds: 18_000
            ),
            weekly: QuotaWindow(
                remainingPercent: 60,
                resetsAt: Date(timeIntervalSince1970: 1_800_086_400),
                durationSeconds: 604_800
            ),
            opusWeekly: nil,
            resetCredits: nil,
            resetCreditExpirations: [],
            status: .available,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let idle = quotaCardSize(snapshot: snapshot, phase: .idle)
        let refreshing = quotaCardSize(snapshot: snapshot, phase: .refreshing)
        let failed = quotaCardSize(
            snapshot: snapshot,
            phase: .failed(
                status: .unavailable("Quota service unavailable"),
                attemptedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
        )

        XCTAssertEqual(idle, refreshing)
        XCTAssertEqual(idle, failed)
        XCTAssertEqual(idle.height, QuotaCardLayout.cardHeight)
    }

    func testQuotaRefreshPresentationMapsEveryPhaseToItsStatusContract() {
        let failed = QuotaRefreshPhase.failed(
            status: .unavailable("Quota service unavailable"),
            attemptedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let authenticationExpired = QuotaRefreshPhase.failed(
            status: .authenticationExpired,
            attemptedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )

        XCTAssertNil(QuotaRefreshPresentation.headerStatus(
            snapshotStatus: .available,
            phase: .idle
        ))
        XCTAssertNil(QuotaRefreshPresentation.headerStatus(
            snapshotStatus: .available,
            phase: .refreshing
        ))
        XCTAssertEqual(QuotaRefreshPresentation.headerStatus(
            snapshotStatus: .available,
            phase: failed
        ), .critical)
        XCTAssertNil(QuotaRefreshPresentation.headerStatus(
            snapshotStatus: .unavailable("Quota service unavailable"),
            phase: failed
        ))

        XCTAssertNil(QuotaRefreshPresentation.failure(for: .idle))
        XCTAssertNil(QuotaRefreshPresentation.failure(for: .refreshing))
        XCTAssertEqual(
            QuotaRefreshPresentation.failure(for: failed),
            QuotaRefreshPresentation.Failure(
                label: "Refresh failed",
                attemptedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
        )
        XCTAssertEqual(
            QuotaRefreshPresentation.failure(for: authenticationExpired),
            QuotaRefreshPresentation.Failure(
                label: "Sign-in expired",
                attemptedAt: Date(timeIntervalSince1970: 1_800_000_200)
            )
        )
    }

    func testQuotaTipHoverStateKeepsTipPresentedDuringTriggerToSurfaceHandoff() {
        var state = QuotaTipHoverState()

        state.triggerHoverChanged(true)
        XCTAssertTrue(state.isPresented)

        state.triggerHoverChanged(false)
        XCTAssertTrue(state.isPresented)

        state.surfaceHoverChanged(true)
        state.reconcilePresentation()
        XCTAssertTrue(state.isPresented)

        state.surfaceHoverChanged(false)
        state.reconcilePresentation()
        XCTAssertFalse(state.isPresented)
    }

    func testQuotaTipHoverStateDismissesAfterLeavingTriggerWithoutEnteringSurface() {
        var state = QuotaTipHoverState()

        state.triggerHoverChanged(true)
        state.triggerHoverChanged(false)
        state.reconcilePresentation()

        XCTAssertFalse(state.isPresented)
    }

    func testQuotaTipHoverStateResetClearsEveryRegion() {
        var state = QuotaTipHoverState()
        state.triggerHoverChanged(true)
        state.surfaceHoverChanged(true)

        state.reset()

        XCTAssertFalse(state.isTriggerHovered)
        XCTAssertFalse(state.isSurfaceHovered)
        XCTAssertFalse(state.isPresented)
    }

    func testQuotaTipOwnershipAllowsOnlyOneProvider() {
        var ownership = QuotaTipOwnership()
        let codex = QuotaTipOwner(provider: .codex)
        let claude = QuotaTipOwner(provider: .claude)

        ownership.claim(codex)
        XCTAssertTrue(ownership.owns(codex))

        ownership.claim(claude)
        XCTAssertFalse(ownership.owns(codex))
        XCTAssertTrue(ownership.owns(claude))
    }

    func testQuotaTipOwnershipIgnoresReleaseFromOutgoingTip() {
        var ownership = QuotaTipOwnership()
        let codex = QuotaTipOwner(provider: .codex)
        let claude = QuotaTipOwner(provider: .claude)

        ownership.claim(codex)
        ownership.claim(claude)
        ownership.release(codex)

        XCTAssertTrue(ownership.owns(claude))

        ownership.release(claude)
        XCTAssertNil(ownership.owner)
    }

    func testQuotaTipOwnershipClearsOwnerWhenVisibleProvidersBecomeEmpty() {
        var ownership = QuotaTipOwnership()
        let codex = QuotaTipOwner(provider: .codex)
        ownership.claim(codex)

        ownership.retainProviders([])

        XCTAssertNil(ownership.owner)
    }

    func testQuotaTipOwnershipKeepsOwnerWhileProviderRemainsVisible() {
        var ownership = QuotaTipOwnership()
        let codex = QuotaTipOwner(provider: .codex)
        ownership.claim(codex)

        ownership.retainProviders([.claude, .codex])

        XCTAssertTrue(ownership.owns(codex))
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

    func testQuotaDetailsTipUsesCompactColumnHeadings() {
        XCTAssertEqual(SubscriptionExpirationCopy.subscriptionTitle, "Subscription")
        XCTAssertEqual(SubscriptionExpirationCopy.expiresTitle, "Expires")
        XCTAssertEqual(QuotaDetailsCopy.usageLimitsTitle, "Usage limits")
        XCTAssertEqual(QuotaDetailsCopy.resetsAtTitle, "Resets at")
    }

    func testQuotaResetCountdownUsesCompactRoundedUnits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(QuotaResetCountdown.text(until: nil, now: now), "--")
        XCTAssertEqual(
            QuotaResetCountdown.text(
                until: Date(timeIntervalSince1970: .infinity),
                now: now
            ),
            "--"
        )
        XCTAssertEqual(
            QuotaResetCountdown.text(
                until: Date(timeIntervalSince1970: Double(Int.max) * 120),
                now: now
            ),
            "--"
        )
        XCTAssertEqual(QuotaResetCountdown.text(until: now, now: now), "Now")
        XCTAssertEqual(
            QuotaResetCountdown.text(until: now.addingTimeInterval(-1), now: now),
            "Now"
        )
        XCTAssertEqual(
            QuotaResetCountdown.text(until: now.addingTimeInterval(1), now: now),
            "1m"
        )
        XCTAssertEqual(
            QuotaResetCountdown.text(until: now.addingTimeInterval(42 * 60), now: now),
            "42m"
        )
        XCTAssertEqual(
            QuotaResetCountdown.text(until: now.addingTimeInterval((2 * 60 + 18) * 60), now: now),
            "2h 18m"
        )
        XCTAssertEqual(
            QuotaResetCountdown.text(
                until: now.addingTimeInterval((3 * 24 + 6) * 60 * 60),
                now: now
            ),
            "3d 6h"
        )
    }

    func testQuotaDetailsPresentationIncludesEveryClaudeWindowInOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = QuotaSnapshot(
            provider: .claude,
            plan: "MAX",
            fiveHour: QuotaWindow(
                remainingPercent: 80,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                durationSeconds: nil
            ),
            weekly: QuotaWindow(
                remainingPercent: 60,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                durationSeconds: nil
            ),
            opusWeekly: QuotaWindow(
                remainingPercent: 40,
                resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
                durationSeconds: nil
            ),
            resetCredits: nil,
            resetCreditExpirations: [],
            status: .available,
            fetchedAt: now.addingTimeInterval(-6 * 60 * 60)
        )

        let presentation = QuotaDetailsPresentation.make(
            provider: .claude,
            snapshot: snapshot,
            refreshPhase: .idle,
            expirationDate: nil,
            now: now
        )

        XCTAssertEqual(presentation.usageWindows.map(\.label), ["5h", "1w", "Opus"])
        XCTAssertEqual(presentation.usageWindows.map(\.countdownText), ["2h", "3d", "4d"])
        XCTAssertEqual(
            presentation.usageWindows.map(\.absoluteResetText),
            [snapshot.fiveHour, snapshot.weekly, snapshot.opusWeekly].map {
                QuotaDateFormat.resetDateTime($0?.resetsAt)
            }
        )
        XCTAssertNil(presentation.resetCredits)
    }

    func testQuotaDetailsPresentationUsesDataDrivenOptionalSections() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let creditExpiration = now.addingTimeInterval(2 * 24 * 60 * 60)
        let subscriptionExpiration = now.addingTimeInterval(10 * 24 * 60 * 60)
        let failure = QuotaRefreshPhase.failed(
            status: .unavailable("Quota service unavailable"),
            attemptedAt: now
        )
        let snapshot = QuotaSnapshot(
            provider: .claude,
            plan: "MAX",
            fiveHour: QuotaWindow(
                remainingPercent: 80,
                resetsAt: now.addingTimeInterval(3 * 60 * 60),
                durationSeconds: 10_800
            ),
            weekly: nil,
            opusWeekly: nil,
            resetCredits: 1,
            resetCreditExpirations: [creditExpiration],
            status: .available,
            fetchedAt: now
        )

        let presentation = QuotaDetailsPresentation.make(
            provider: .claude,
            snapshot: snapshot,
            refreshPhase: failure,
            expirationDate: subscriptionExpiration,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(presentation.usageWindows.map(\.label), ["5h"])
        XCTAssertEqual(presentation.resetCredits?.count, 1)
        XCTAssertEqual(presentation.resetCredits?.items.first?.countdownText, "2 days")
        XCTAssertEqual(presentation.subscription?.distanceText, "10 days")
        XCTAssertEqual(presentation.refreshFailure?.label, "Refresh failed")
        XCTAssertTrue(presentation.hasContent)
    }

    func testQuotaDetailsPresentationOmitsFailureWithoutRetainedSnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = QuotaRefreshPhase.failed(
            status: .unavailable("Quota service unavailable"),
            attemptedAt: now
        )

        let presentation = QuotaDetailsPresentation.make(
            provider: .codex,
            snapshot: .failure(
                provider: .codex,
                status: .unavailable("Quota service unavailable"),
                at: now
            ),
            refreshPhase: failed,
            expirationDate: now.addingTimeInterval(10 * 24 * 60 * 60),
            now: now
        )

        XCTAssertTrue(presentation.usageWindows.isEmpty)
        XCTAssertNil(presentation.resetCredits)
        XCTAssertNotNil(presentation.subscription)
        XCTAssertNil(presentation.refreshFailure)
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
        let suiteName = "QuotaFeatureTests.visibleProviders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quotaSettings = QuotaSettings(defaults: defaults)
        quotaSettings.claudeExpirationDate = Date(timeIntervalSince1970: 1_900_000_000)
        quotaSettings.codexExpirationDate = Date(timeIntervalSince1970: 1_900_000_000)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            quotaSettings: quotaSettings,
            observeRefreshIntervalChanges: false,
            currentDateProvider: { now }
        )
        let initialClaudeState = store.quotaCardState(for: .claude)
        let initialCodexState = store.quotaCardState(for: .codex)

        store.appFilter = .all
        XCTAssertEqual(store.visibleQuotaProviders, [.claude, .codex])

        store.appFilter = .claude
        XCTAssertEqual(store.visibleQuotaProviders, [.claude])

        store.appFilter = .codex
        XCTAssertEqual(store.visibleQuotaProviders, [.codex])

        store.appFilter = .cursor
        XCTAssertEqual(store.visibleQuotaProviders, [])
        XCTAssertEqual(store.quotaCardState(for: .claude), initialClaudeState)
        XCTAssertEqual(store.quotaCardState(for: .codex), initialCodexState)

        quotaSettings.codexExpirationDate = nil
        store.quotaProviderSettingsDidChange()
        store.appFilter = .all
        XCTAssertEqual(store.visibleQuotaProviders, [.claude])
        XCTAssertEqual(
            store.quotaExpirationDate(for: .claude),
            quotaSettings.claudeExpirationDate
        )
        store.appFilter = .codex
        XCTAssertEqual(store.visibleQuotaProviders, [])
        XCTAssertNil(store.quotaCardState(for: .codex))

        now = now.addingTimeInterval(60)
        quotaSettings.codexExpirationDate = Date(timeIntervalSince1970: 1_900_000_000)
        store.quotaProviderSettingsDidChange()
        XCTAssertEqual(store.quotaCardState(for: .codex)?.presentedAt, now)
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

    func testCodexResetCreditsResponseTreats429AsNotUpdated() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONSerialization.data(withJSONObject: ["detail": "rate limited"])

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(
                data: data,
                response: response,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            .notUpdated
        )
    }

    func testCodexResetCreditsResponseRequiresCompleteExpirations() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let incomplete = try JSONSerialization.data(withJSONObject: [
            "available_count": 1,
            "credits": []
        ])
        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(data: incomplete, response: response, now: now),
            .notUpdated
        )

        let expiration = now.addingTimeInterval(86_400)
        let complete = try JSONSerialization.data(withJSONObject: [
            "available_count": 1,
            "credits": [["status": "available", "expires_at": expiration.timeIntervalSince1970]]
        ])
        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(data: complete, response: response, now: now),
            .authoritative(ResetCreditsState(count: 1, expirations: [expiration]))
        )
    }

    func testCodexResetCreditsResponseAcceptsExplicitZero() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONSerialization.data(withJSONObject: [
            "available_count": 0,
            "credits": []
        ])

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(
                data: data,
                response: response,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            .authoritative(ResetCreditsState(count: 0, expirations: []))
        )
    }

    func testCodexResetCreditsResponseRejectsOutOfRangeCount() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = Data("{\"available_count\":1e100,\"credits\":[]}".utf8)

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(
                data: data,
                response: response,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            .notUpdated
        )
    }

    func testCodexResetCreditsResponseRejectsBooleanCount() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONSerialization.data(withJSONObject: [
            "available_count": true,
            "credits": []
        ])

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(
                data: data,
                response: response,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            .notUpdated
        )
    }

    func testCodexResetCreditsResponseRejectsContradictoryZero() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONSerialization.data(withJSONObject: [
            "available_count": 0,
            "credits": [["status": "available", "expires_at": now.addingTimeInterval(86_400).timeIntervalSince1970]]
        ])

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(data: data, response: response, now: now),
            .notUpdated
        )
    }

    func testCodexResetCreditsResponseRejectsUnrecognizedExpirationShape() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = try JSONSerialization.data(withJSONObject: [
            "available_count": 1,
            "credits": "invalid",
            "subscription_expires_at": now.addingTimeInterval(86_400).timeIntervalSince1970
        ])

        XCTAssertEqual(
            QuotaService.codexResetCreditsUpdate(data: data, response: response, now: now),
            .notUpdated
        )
    }

    private func quotaCardSize(
        snapshot: QuotaSnapshot,
        phase: QuotaRefreshPhase
    ) -> NSSize {
        let hostingView = NSHostingView(rootView: QuotaCardRenderHarness(
            snapshot: snapshot,
            phase: phase
        ))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }
}

private struct QuotaCardRenderHarness: View {
    @State private var ownership = QuotaTipOwnership()
    let snapshot: QuotaSnapshot
    let phase: QuotaRefreshPhase

    var body: some View {
        SubscriptionQuotaCard(
            provider: .codex,
            snapshot: snapshot,
            refreshPhase: phase,
            expirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            presentationDate: Date(timeIntervalSince1970: 1_800_000_000),
            tipOwnership: $ownership
        )
        .frame(width: 580)
        .environmentObject(ThemeManager.shared)
    }
}
