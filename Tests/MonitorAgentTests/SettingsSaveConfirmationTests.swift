import XCTest
import SwiftUI
@testable import MonitorAgent

final class SettingsSaveConfirmationTests: XCTestCase {
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
}
