import AppKit
import Carbon.HIToolbox
import XCTest
@testable import MonitorAgent

final class PanelShortcutSettingsTests: XCTestCase {
    func testDefaultsMatchHistoricKeys() {
        let settings = PanelShortcutSettings(defaults: makeDefaults())

        XCTAssertEqual(settings.binding(for: .togglePin)?.keyCode, UInt32(kVK_ANSI_P))
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
            .cycleFilter: nil,
            .resetPosition: PanelShortcutAction.resetPosition.defaultBinding,
            .hidePanel: PanelShortcutAction.hidePanel.defaultBinding,
        ])

        let reloaded = PanelShortcutSettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .togglePin), custom)
        XCTAssertNil(reloaded.binding(for: .cycleFilter))
        XCTAssertEqual(reloaded.binding(for: .resetPosition)?.keyCode, UInt32(kVK_Return))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PanelShortcutSettingsTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}
