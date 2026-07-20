import SwiftUI
import AppKit
import Combine

enum Theme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

enum StatusPalette {
    static let success: Color = .green
    static let warning: Color = .orange
    static let error: Color = .red
}

/// Manages app-wide theme, persisted to UserDefaults.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager(defaults: RuntimeEnvironment.current.preferences)

    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: "appTheme") }
    }

    private let defaults: PreferencesStoring
    private var cancellables = Set<AnyCancellable>()

    init(defaults: PreferencesStoring = UserDefaults.standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: "appTheme") ?? "system"
        self.theme = Theme(rawValue: raw) ?? .system
    }

    /// Resolved effective appearance based on theme setting
    var isDark: Bool {
        switch theme {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    // MARK: - SwiftUI Color Scheme

    var colorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // MARK: - Panel Colors (AppKit)

    /// Opaque semantic window background matching the General detail page.
    var panelBackground: NSColor {
        resolvedSemanticColor(.windowBackgroundColor)
    }

    // MARK: - View Colors (SwiftUI)

    /// Theme-aware inset fill matching native General form groups.
    var groupedSurface: Color {
        isDark
            ? Color.white.opacity(MainPanelDesign.darkGroupedSurfaceOpacity)
            : Color.black.opacity(MainPanelDesign.lightGroupedSurfaceOpacity)
    }

    /// Quiet control chrome placed directly on the panel material.
    var controlSurface: Color {
        isDark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.035)
    }

    /// Activity Input Tokens blue used by selected main-panel header controls.
    var selectedControlAccent: Color {
        MainPanelSelectionPalette.accent
    }

    /// Solid selected fill for the main-panel app filter.
    var selectedControlSurface: Color {
        selectedControlAccent.opacity(MainPanelSelectionPalette.tabBackgroundOpacity)
    }

    /// Stable label contrast that does not fade when the panel loses focus.
    var panelSecondaryForeground: Color {
        isDark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.62)
    }

    /// Lower-emphasis panel text that remains legible over material.
    var panelTertiaryForeground: Color {
        isDark
            ? Color.white.opacity(0.54)
            : Color.black.opacity(0.48)
    }

    /// Dark: subtle light squares on dark grid
    var cellEmpty: Color {
        isDark
            ? Color.white.opacity(0.06)
            : .black.opacity(0.06)
    }

    /// Heatmap active cell base color
    var cellActive: Color {
        isDark ? Color(red: 0.4, green: 0.6, blue: 1.0) : Color.accentColor
    }

    var tooltipBackground: Color {
        isDark
            ? Color(red: 0.22, green: 0.22, blue: 0.24).opacity(0.75)
            : Color.black.opacity(0.75)
    }

    var tooltipForeground: Color {
        isDark ? .white.opacity(0.9) : .white
    }

    /// NSAppearance matching the current theme — use on NSWindow.appearance
    var nsAppearance: NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    private func resolvedSemanticColor(_ color: NSColor) -> NSColor {
        let appearance = nsAppearance ?? NSApp.effectiveAppearance
        var resolvedColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolvedColor
    }
}
