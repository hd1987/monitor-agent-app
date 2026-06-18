import SwiftUI
import AppKit
import Combine

enum Theme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
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

    var panelBackground: NSColor {
        isDark
            ? NSColor(white: 0.15, alpha: 0.98)
            : NSColor.white.withAlphaComponent(0.98)
    }

    var panelBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.01)
    }

    // MARK: - View Colors (SwiftUI)

    var cardBackground: Color {
        isDark ? .white.opacity(0.08) : .black.opacity(0.04)
    }

    var cellEmpty: Color {
        isDark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    var tooltipBackground: Color {
        isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.75)
    }

    var tooltipForeground: Color {
        isDark ? .black : .white
    }

    var dividerOpacity: Double {
        isDark ? 0.15 : 0.2
    }
}
