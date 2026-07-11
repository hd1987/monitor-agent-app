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

/// Manages app-wide theme, persisted to UserDefaults.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
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

    /// Dark: #1c1c1e (macOS native dark background)
    var panelBackground: NSColor {
        isDark
            ? NSColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 0.98)
            : NSColor.white.withAlphaComponent(0.98)
    }

    var panelBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.20)
    }

    // MARK: - View Colors (SwiftUI)

    /// Dark: #2c2c2e — slightly lighter than panel background
    var cardBackground: Color {
        isDark
            ? Color(red: 0.17, green: 0.17, blue: 0.18)
            : .white
    }

    /// Light: thin gray border for cards; Dark: subtle edge
    var cardBorder: Color {
        isDark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.12)
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

    var dividerOpacity: Double {
        isDark ? 0.1 : 0.2
    }

    /// NSAppearance matching the current theme — use on NSWindow.appearance
    var nsAppearance: NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}
