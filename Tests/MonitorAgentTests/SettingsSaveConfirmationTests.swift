import XCTest
import SwiftUI
@testable import MonitorAgent

final class SettingsSaveConfirmationTests: XCTestCase {
    func testSettingsWindowUsesCompactNativeSize() {
        XCTAssertEqual(SettingsWindowLayout.defaultWidth, 820)
        XCTAssertEqual(SettingsWindowLayout.defaultHeight, 600)
        XCTAssertEqual(SettingsWindowLayout.minimumWidth, 760)
        XCTAssertEqual(SettingsWindowLayout.minimumHeight, 520)
        XCTAssertEqual(SettingsWindowLayout.sidebarVisibility, .all)
        XCTAssertEqual(SettingsWindowLayout.contentTopPadding, 0)
        XCTAssertEqual(SettingsWindowLayout.groupedFormTopPadding, -20)
        XCTAssertEqual(
            SettingsWindowToolbar.sidebarToggleIdentifier.rawValue,
            "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        )
    }

    func testUtilityGroupedSurfacesUseSpecifiedRGBValues() {
        XCTAssertEqual(
            UtilityWindowDesign.groupedSurfaceComponent,
            247.0 / 255.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            UtilityWindowDesign.nestedSurfaceComponent,
            236.0 / 255.0,
            accuracy: 0.000_001
        )
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

    func testSaveSuccessUsesInlineCheckmarkIndicator() {
        XCTAssertEqual(SaveSuccessIndicatorStyle.systemImage, "checkmark.circle.fill")
    }

    func testExtensionsIsACombinedReadOnlyCategory() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.rawValue),
            ["General", "Extensions", "Config", "Prompt"]
        )
        XCTAssertTrue(SettingsCategory.extensions.isReadOnly)
        XCTAssertFalse(SettingsCategory.general.isReadOnly)
        XCTAssertFalse(SettingsCategory.config.isReadOnly)
        XCTAssertFalse(SettingsCategory.prompt.isReadOnly)
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
        XCTAssertEqual(QuotaSettingsCopy.expirationNotSet, "Not set")
        XCTAssertEqual(QuotaSettingsCopy.expirationPickerTitle, "Subscription Expiration")
        XCTAssertEqual(QuotaSettingsCopy.today, "Today")
        XCTAssertEqual(QuotaSettingsCopy.clearExpiration, "Clear")
        XCTAssertEqual(QuotaSettingsCopy.refreshIntervalTitle, "Refresh Interval")
        XCTAssertEqual(QuotaSettingsCopy.refreshIntervalDescription, "Refresh while the panel is open. \"Never\" refreshes once when opened.")
        XCTAssertEqual(QuotaRefreshInterval.allCases.map(\.displayName), ["1 min", "2 min", "5 min", "Never"])
    }

    func testExpirationDateControlUsesCompactInputGeometry() {
        XCTAssertEqual(ExpirationDateControlStyle.width, 120)
        XCTAssertEqual(ExpirationDateControlStyle.height, 28)
        XCTAssertEqual(ExpirationDateControlStyle.cornerRadius, 7)
        XCTAssertEqual(ExpirationDateControlStyle.borderWidth, 0.5)
    }

    func testAppSourceTabsAlignWithEditorContent() {
        XCTAssertEqual(AppSourceTabBarLayout.horizontalPadding, 20)
        XCTAssertEqual(AppSourceTabBarLayout.height, 28)
        XCTAssertEqual(AppSourceTabBarLayout.segmentSpacing, 2)
        XCTAssertEqual(AppSourceTabBarLayout.containerInset, 2)
        XCTAssertEqual(AppSourceTabBarLayout.cornerRadius, 7)
    }

    func testUsageDataRebuildCopyMatchesSettingsDataSection() {
        XCTAssertEqual(UsageDataRebuildCopy.buttonTitle, "Rebuild Local Usage Data")
        XCTAssertEqual(UsageDataRebuildCopy.confirmationTitle, "Rebuild Local Usage Data?")
        XCTAssertEqual(UsageDataRebuildCopy.runningMessage, "Rebuilding local usage data...")
        XCTAssertEqual(UsageDataRebuildCopy.successTitle, "Local usage data rebuilt successfully.")
        XCTAssertEqual(UsageDataRebuildCopy.failureTitle, "Rebuild failed. Your existing usage data was not changed.")
    }
}
