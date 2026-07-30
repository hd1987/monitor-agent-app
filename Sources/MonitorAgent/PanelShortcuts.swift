import AppKit
import Carbon.HIToolbox
import Combine

/// In-panel keyboard actions that fire only while the main panel has focus.
/// Each action is customizable; single keys (no modifier) are allowed because
/// these bindings apply only to the focused panel and cannot collide with global input.
enum PanelShortcutAction: String, CaseIterable, Identifiable {
    case togglePin
    case refreshData
    case cycleFilter
    case resetPosition
    case hidePanel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePin: return "Toggle Pin"
        case .refreshData: return "Refresh Data"
        case .cycleFilter: return "Cycle App Filter"
        case .resetPosition: return "Reset Panel Position"
        case .hidePanel: return "Hide Panel"
        }
    }

    var description: String {
        switch self {
        case .togglePin:
            return "Pin or unpin the panel so it stays open when focus moves away."
        case .refreshData:
            return "Refresh all data and restart the automatic refresh interval."
        case .cycleFilter:
            return "Switch All / Claude Code / Codex / Cursor. Hold Shift to cycle backward."
        case .resetPosition:
            return "Move the panel back below the menu bar icon."
        case .hidePanel:
            return "Hide the panel even while it is pinned."
        }
    }

    /// Default binding, matching the app's historic hardcoded keys.
    var defaultBinding: GlobalShortcut {
        switch self {
        case .togglePin:
            return GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifierFlags: 0, keyLabel: "P")
        case .refreshData:
            return GlobalShortcut(keyCode: UInt32(kVK_ANSI_R), modifierFlags: 0, keyLabel: "R")
        case .cycleFilter:
            return GlobalShortcut(keyCode: UInt32(kVK_Tab), modifierFlags: 0, keyLabel: "Tab")
        case .resetPosition:
            return GlobalShortcut(keyCode: UInt32(kVK_Return), modifierFlags: 0, keyLabel: "Return")
        case .hidePanel:
            return GlobalShortcut(keyCode: UInt32(kVK_Escape), modifierFlags: 0, keyLabel: "Esc")
        }
    }
}

/// One persisted assignment. A `nil` binding means the user explicitly cleared the action;
/// an action absent from storage falls back to its default (forward-compatible with new actions).
private struct PanelShortcutEntry: Codable {
    let action: String
    let binding: GlobalShortcut?
}

/// Stores and resolves the panel shortcut bindings.
final class PanelShortcutSettings: ObservableObject {
    static let shared = PanelShortcutSettings()
    static let defaultsKey = "panelShortcuts"

    private let defaults: UserDefaults
    @Published private(set) var entries: [String: GlobalShortcut?]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([PanelShortcutEntry].self, from: data) {
            self.entries = Dictionary(
                decoded.map { ($0.action, $0.binding) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            self.entries = [:]
        }
    }

    /// Resolves the effective binding for an action (stored value, including an explicit clear,
    /// otherwise the default).
    func binding(for action: PanelShortcutAction) -> GlobalShortcut? {
        if let stored = entries[action.rawValue] {
            return stored
        }
        return action.defaultBinding
    }

    /// Persists a full snapshot of every action's binding.
    func update(_ bindings: [PanelShortcutAction: GlobalShortcut?]) {
        var snapshot: [String: GlobalShortcut?] = [:]
        for action in PanelShortcutAction.allCases {
            snapshot[action.rawValue] = bindings[action] ?? action.defaultBinding
        }
        entries = snapshot

        let encodable = snapshot.map { PanelShortcutEntry(action: $0.key, binding: $0.value) }
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
