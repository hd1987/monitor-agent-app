import AppKit
import XCTest
@testable import MonitorAgent

final class GlobalShortcutTests: XCTestCase {
    func testDisplayNameUsesMacModifierOrder() {
        let shortcut = GlobalShortcut(
            keyCode: 1,
            modifierFlags: NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue,
            keyLabel: "S"
        )

        XCTAssertEqual(shortcut.displayName, "⌃⌥⇧⌘S")
    }

    func testControllerPersistsShortcutAfterSuccessfulRegistration() throws {
        let defaults = makeDefaults()
        let registrar = ShortcutRegistrarStub()
        let controller = GlobalShortcutController(defaults: defaults, registrar: registrar)
        let shortcut = GlobalShortcut(
            keyCode: 49,
            modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            keyLabel: "Space"
        )

        try controller.updateShortcut(shortcut)

        XCTAssertEqual(controller.shortcut, shortcut)
        XCTAssertEqual(
            GlobalShortcutController(defaults: defaults, registrar: ShortcutRegistrarStub()).shortcut,
            shortcut
        )
    }

    func testControllerKeepsPreviousShortcutWhenRegistrationFails() throws {
        let defaults = makeDefaults()
        let registrar = ShortcutRegistrarStub()
        let controller = GlobalShortcutController(defaults: defaults, registrar: registrar)
        let original = GlobalShortcut(keyCode: 1, modifierFlags: NSEvent.ModifierFlags.command.rawValue, keyLabel: "S")
        let replacement = GlobalShortcut(keyCode: 2, modifierFlags: NSEvent.ModifierFlags.command.rawValue, keyLabel: "D")
        try controller.updateShortcut(original)
        registrar.shouldFail = true

        XCTAssertThrowsError(try controller.updateShortcut(replacement))
        XCTAssertEqual(controller.shortcut, original)
        XCTAssertEqual(
            GlobalShortcutController(defaults: defaults, registrar: ShortcutRegistrarStub()).shortcut,
            original
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "GlobalShortcutTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}

private final class ShortcutRegistrarStub: GlobalShortcutRegistering {
    var shouldFail = false

    func replaceShortcut(_ shortcut: GlobalShortcut?, handler: @escaping () -> Void) throws {
        if shouldFail {
            throw GlobalShortcutRegistrationError.unavailable
        }
    }
}
