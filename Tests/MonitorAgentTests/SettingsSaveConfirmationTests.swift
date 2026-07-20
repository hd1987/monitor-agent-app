import XCTest
import AppKit
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

    func testSettingsWindowRevealsOnlyAfterRemovingPresentedSidebarToggle() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: SettingsToolbarProbe())

        SettingsWindowToolbar.prepareForPresentation(window)
        XCTAssertEqual(window.alphaValue, 0)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertFalse(window.firstResponder is NSTextView)

        SettingsWindowToolbar.revealAfterPresentation(window)

        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertFalse(
            toolbar.items.contains(where: {
                $0.itemIdentifier == SettingsWindowToolbar.sidebarToggleIdentifier
            })
        )
        XCTAssertEqual(window.alphaValue, 1)
        window.orderOut(nil)
    }

    func testUtilityGroupedSurfacesPreserveSpecifiedLightRGBValues() throws {
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

        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let grouped = UtilityWindowDesign.groupedSurfaceColor(for: lightAppearance)
        let nested = UtilityWindowDesign.nestedSurfaceColor(for: lightAppearance)
        XCTAssertEqual(grouped.redComponent, 247.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(nested.redComponent, 236.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(grouped.alphaComponent, 1, accuracy: 0.000_001)
        XCTAssertEqual(nested.alphaComponent, 1, accuracy: 0.000_001)
    }

    func testUtilityGroupedSurfacesUseDarkHierarchy() throws {
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let grouped = UtilityWindowDesign.groupedSurfaceColor(for: darkAppearance)
        let nested = UtilityWindowDesign.nestedSurfaceColor(for: darkAppearance)
        let dateControl = UtilityWindowDesign.dateControlSurfaceColor(for: darkAppearance)

        XCTAssertEqual(grouped.whiteComponent, 1, accuracy: 0.000_001)
        XCTAssertEqual(grouped.alphaComponent, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(nested.whiteComponent, 0, accuracy: 0.000_001)
        XCTAssertEqual(nested.alphaComponent, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(dateControl.whiteComponent, 0, accuracy: 0.000_001)
        XCTAssertEqual(dateControl.alphaComponent, 0.12, accuracy: 0.000_001)
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

    func testFinderPathResolverOpensDirectoriesAndRevealsFiles() {
        XCTAssertEqual(
            FinderPathResolver.action(for: "/tmp", kind: .directory),
            .open(URL(fileURLWithPath: "/tmp", isDirectory: true))
        )
        XCTAssertEqual(
            FinderPathResolver.action(for: #filePath, kind: .file),
            .reveal(URL(fileURLWithPath: #filePath))
        )
    }

    func testFinderPathResolverFallsBackToNearestExistingDirectory() {
        let missingPath = "/tmp/monitor-agent-missing-\(UUID().uuidString)/config.toml"

        XCTAssertEqual(
            FinderPathResolver.action(for: missingPath, kind: .file),
            .open(URL(fileURLWithPath: "/tmp", isDirectory: true))
        )
    }

    func testSourcePathPresentationExtractsSettingsFileNames() {
        XCTAssertEqual(
            SourcePathPresentation.fileName(for: "~/.claude/settings.json"),
            "settings.json"
        )
        XCTAssertEqual(
            SourcePathPresentation.fileName(for: "~/.codex/AGENTS.md"),
            "AGENTS.md"
        )
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
        XCTAssertEqual(ExpirationDateControlStyle.width, 140)
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
        XCTAssertEqual(UsageDataRebuildCopy.canceledTitle, "Rebuild canceled.")
    }
}

private struct SettingsToolbarProbe: View {
    @FocusState private var isSidebarFocused: Bool
    @State private var text = "Editable content"

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List {
                Text("General")
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 190)
            .focused($isSidebarFocused)
        } detail: {
            TextEditor(text: $text)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            isSidebarFocused = true
        }
    }
}
