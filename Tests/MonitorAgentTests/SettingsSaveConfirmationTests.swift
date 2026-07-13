import XCTest
import SwiftUI
@testable import MonitorAgent

final class SettingsSaveConfirmationTests: XCTestCase {
    func testSettingsWindowUsesExpandedMinimumSize() {
        XCTAssertEqual(SettingsWindowLayout.minimumWidth, 960)
        XCTAssertEqual(SettingsWindowLayout.minimumHeight, 680)
    }

    func testSaveConfirmationContentMatchesEachSettingsCategory() {
        XCTAssertEqual(SettingsCategory.general.saveConfirmationTitle, "Save General settings?")
        XCTAssertEqual(SettingsCategory.config.saveConfirmationTitle, "Save Config settings?")
        XCTAssertEqual(SettingsCategory.prompt.saveConfirmationTitle, "Save Prompt settings?")

        XCTAssertEqual(SettingsCategory.general.saveConfirmationMessage, "Apply changes to General settings.")
        XCTAssertEqual(SettingsCategory.config.saveConfirmationMessage, "Apply changes to Config settings.")
        XCTAssertEqual(SettingsCategory.prompt.saveConfirmationMessage, "Apply changes to Prompt settings.")
    }

    func testSaveSuccessMessageMatchesEachSettingsCategory() {
        XCTAssertEqual(SettingsCategory.general.saveSuccessMessage, "General settings saved.")
        XCTAssertEqual(SettingsCategory.config.saveSuccessMessage, "Config settings saved.")
        XCTAssertEqual(SettingsCategory.prompt.saveSuccessMessage, "Prompt settings saved.")
    }

    func testSaveSuccessToastUsesTopPlacement() {
        XCTAssertEqual(SaveSuccessToastPlacement.edge, .top)
    }

    func testSaveSuccessToastUsesGreenBackground() {
        XCTAssertEqual(SaveSuccessToastStyle.backgroundColorName, "green")
    }

    func testSyncIntervalOptionsMatchGeneralSettingsMenu() {
        XCTAssertEqual(SyncInterval.allCases.map(\.displayName), ["10s", "30s", "60s", "Never"])
    }

    func testSubscriptionQuotaSettingsArePresentedAsOneGroup() {
        XCTAssertEqual(QuotaSettingsCopy.title, "Subscription Quota")
        XCTAssertEqual(QuotaSettingsCopy.claudeTitle, "Claude Code")
        XCTAssertEqual(QuotaSettingsCopy.claudeDescription, "Show Claude Code subscription quota in the main panel.")
        XCTAssertEqual(QuotaSettingsCopy.codexTitle, "Codex")
        XCTAssertEqual(QuotaSettingsCopy.codexDescription, "Show Codex subscription quota in the main panel.")
        XCTAssertEqual(QuotaSettingsCopy.refreshIntervalTitle, "Refresh Interval")
        XCTAssertEqual(QuotaSettingsCopy.refreshIntervalDescription, "Refresh while the panel is open. \"Never\" refreshes once when opened.")
        XCTAssertEqual(QuotaRefreshInterval.allCases.map(\.displayName), ["1 min", "2 min", "5 min", "Never"])
    }

    func testUsageDataRebuildCopyMatchesSettingsDataSection() {
        XCTAssertEqual(UsageDataRebuildCopy.buttonTitle, "Rebuild Local Usage Data")
        XCTAssertEqual(UsageDataRebuildCopy.confirmationTitle, "Rebuild Local Usage Data?")
        XCTAssertEqual(UsageDataRebuildCopy.runningMessage, "Rebuilding local usage data...")
        XCTAssertEqual(UsageDataRebuildCopy.successTitle, "Local usage data rebuilt successfully.")
        XCTAssertEqual(UsageDataRebuildCopy.failureTitle, "Rebuild failed. Your existing usage data was not changed.")
    }
}
