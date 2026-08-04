import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MonitorAgent

final class PanelShortcutSettingsTests: XCTestCase {
    func testDefaultsMatchHistoricKeys() {
        let settings = PanelShortcutSettings(defaults: makeDefaults())

        XCTAssertEqual(settings.binding(for: .togglePin)?.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(settings.binding(for: .toggleActivityChart)?.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(settings.binding(for: .refreshData)?.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(settings.binding(for: .cycleFilter)?.keyCode, UInt32(kVK_Tab))
        XCTAssertEqual(settings.binding(for: .resetPosition)?.keyCode, UInt32(kVK_Return))
        XCTAssertEqual(settings.binding(for: .hidePanel)?.keyCode, UInt32(kVK_Escape))
    }

    func testUpdatePersistsAssignmentsAndClears() {
        let defaults = makeDefaults()
        let settings = PanelShortcutSettings(defaults: defaults)
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifierFlags: 0, keyLabel: "K")

        settings.update([
            .togglePin: custom,
            .toggleActivityChart: PanelShortcutAction.toggleActivityChart.defaultBinding,
            .refreshData: PanelShortcutAction.refreshData.defaultBinding,
            .cycleFilter: nil,
            .resetPosition: PanelShortcutAction.resetPosition.defaultBinding,
            .hidePanel: PanelShortcutAction.hidePanel.defaultBinding,
        ])

        let reloaded = PanelShortcutSettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .togglePin), custom)
        XCTAssertEqual(reloaded.binding(for: .toggleActivityChart)?.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertEqual(reloaded.binding(for: .refreshData)?.keyCode, UInt32(kVK_ANSI_R))
        XCTAssertNil(reloaded.binding(for: .cycleFilter))
        XCTAssertEqual(reloaded.binding(for: .resetPosition)?.keyCode, UInt32(kVK_Return))
    }

    func testNewActivityShortcutDefaultsWhenMissingFromStoredAssignments() {
        let defaults = makeDefaults()
        let storedAssignments = """
        [{"action":"togglePin","binding":{"keyCode":40,"modifierFlags":0,"keyLabel":"K"}}]
        """.data(using: .utf8)!
        defaults.set(storedAssignments, forKey: PanelShortcutSettings.defaultsKey)

        let settings = PanelShortcutSettings(defaults: defaults)

        XCTAssertEqual(settings.binding(for: .togglePin)?.keyCode, 40)
        XCTAssertEqual(settings.binding(for: .toggleActivityChart)?.keyCode, UInt32(kVK_ANSI_C))
    }

    func testNewActivityShortcutDoesNotConflictWithStoredCustomBinding() {
        let defaults = makeDefaults()
        let storedAssignments = """
        [{"action":"togglePin","binding":{"keyCode":8,"modifierFlags":0,"keyLabel":"Localized C"}}]
        """.data(using: .utf8)!
        defaults.set(storedAssignments, forKey: PanelShortcutSettings.defaultsKey)

        let settings = PanelShortcutSettings(defaults: defaults)

        XCTAssertEqual(settings.binding(for: .togglePin)?.keyCode, UInt32(kVK_ANSI_C))
        XCTAssertNil(settings.binding(for: .toggleActivityChart))
    }

    func testDefaultPanelShortcutsAreUnique() {
        let bindings = PanelShortcutAction.allCases.map(\.defaultBinding)
        let identities = bindings.map { "\($0.keyCode)-\($0.modifierFlags)" }

        XCTAssertEqual(Set(identities).count, PanelShortcutAction.allCases.count)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}
