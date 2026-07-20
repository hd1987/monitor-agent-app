import AppKit
import Carbon.HIToolbox
import Combine

struct GlobalShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    let keyCode: UInt32
    let modifierFlags: UInt
    let keyLabel: String

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.supportedModifiers)
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    static func make(from event: NSEvent) -> GlobalShortcut? {
        let modifiers = event.modifierFlags.intersection(supportedModifiers)
        guard !modifiers.isEmpty else { return nil }

        return GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifierFlags: modifiers.rawValue,
            keyLabel: keyLabel(for: event)
        )
    }

    static func isRecordingCancellation(_ event: NSEvent) -> Bool {
        Int(event.keyCode) == kVK_Escape
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
             kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return functionKeyLabel(for: Int(event.keyCode))
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "Key (event.keyCode)"
        }
    }

    private static func functionKeyLabel(for keyCode: Int) -> String {
        let functionKeys = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        return functionKeys[keyCode] ?? "Key (keyCode)"
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

enum GlobalShortcutRegistrationError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This shortcut is already in use. Choose a different shortcut."
    }
}

protocol GlobalShortcutRegistering: AnyObject {
    func replaceShortcut(_ shortcut: GlobalShortcut?, handler: @escaping () -> Void) throws
}

final class DisabledGlobalShortcutRegistrar: GlobalShortcutRegistering {
    func replaceShortcut(_ shortcut: GlobalShortcut?, handler: @escaping () -> Void) throws {}
}

final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var registeredShortcut: GlobalShortcut?
    private var nextHotKeyID: UInt32 = 1

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonGlobalShortcutRegistrar>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                registrar.handleHotKeyPress()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    func replaceShortcut(_ shortcut: GlobalShortcut?, handler: @escaping () -> Void) throws {
        self.handler = handler
        guard shortcut != registeredShortcut else { return }

        guard let shortcut else {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            hotKeyRef = nil
            registeredShortcut = nil
            return
        }

        var replacementRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x4D_41_47_54, id: nextHotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &replacementRef
        )
        guard status == noErr, let replacementRef else {
            throw GlobalShortcutRegistrationError.unavailable
        }

        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = replacementRef
        registeredShortcut = shortcut
        nextHotKeyID &+= 1
    }

    private func handleHotKeyPress() {
        DispatchQueue.main.async { [weak self] in
            self?.handler?()
        }
    }
}

final class GlobalShortcutController: ObservableObject {
    static let shared = GlobalShortcutController(
        defaults: RuntimeEnvironment.current.preferences,
        registrar: RuntimeEnvironment.current.featurePolicy.allowsGlobalShortcutRegistration
            ? CarbonGlobalShortcutRegistrar()
            : DisabledGlobalShortcutRegistrar()
    )
    static let defaultsKey = "globalPanelShortcut"

    @Published private(set) var shortcut: GlobalShortcut?

    private let defaults: PreferencesStoring
    private let registrar: GlobalShortcutRegistering
    private var handler: () -> Void = {}

    init(
        defaults: PreferencesStoring = UserDefaults.standard,
        registrar: GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar()
    ) {
        self.defaults = defaults
        self.registrar = registrar
        if let data = defaults.data(forKey: Self.defaultsKey) {
            self.shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        }
    }

    func configure(handler: @escaping () -> Void) {
        self.handler = handler
        try? registrar.replaceShortcut(shortcut, handler: handler)
    }

    func updateShortcut(_ shortcut: GlobalShortcut?) throws {
        try registrar.replaceShortcut(shortcut, handler: handler)
        self.shortcut = shortcut

        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
