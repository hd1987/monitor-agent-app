import AppKit
import SwiftUI

enum UtilityWindowDesign {
    static let cornerRadius: CGFloat = 10
    static let compactCornerRadius: CGFloat = 7
    static let groupedSurfaceComponent = 247.0 / 255.0
    static let nestedSurfaceComponent = 236.0 / 255.0
    static let darkGroupedSurfaceOpacity = 0.08
    static let darkNestedSurfaceOpacity = 0.12
    static let selectedControlText = Color(nsColor: .alternateSelectedControlTextColor)
    static let groupedSurfaceFill = Color(nsColor: NSColor(name: nil) { appearance in
        groupedSurfaceColor(for: appearance)
    })
    static let nestedSurfaceFill = Color(nsColor: NSColor(name: nil) { appearance in
        nestedSurfaceColor(for: appearance)
    })
    static let dateControlSurfaceFill = Color(nsColor: NSColor(name: nil) { appearance in
        dateControlSurfaceColor(for: appearance)
    })

    static func groupedSurfaceColor(for appearance: NSAppearance) -> NSColor {
        adaptiveSurfaceColor(
            appearance: appearance,
            lightComponent: groupedSurfaceComponent,
            darkColor: .white,
            darkOpacity: darkGroupedSurfaceOpacity
        )
    }

    static func nestedSurfaceColor(for appearance: NSAppearance) -> NSColor {
        adaptiveSurfaceColor(
            appearance: appearance,
            lightComponent: nestedSurfaceComponent,
            darkColor: .black,
            darkOpacity: darkNestedSurfaceOpacity
        )
    }

    static func dateControlSurfaceColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.black.withAlphaComponent(darkNestedSurfaceOpacity)
            : .controlBackgroundColor
    }

    private static func adaptiveSurfaceColor(
        appearance: NSAppearance,
        lightComponent: CGFloat,
        darkColor: NSColor,
        darkOpacity: CGFloat
    ) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? darkColor.withAlphaComponent(darkOpacity)
            : NSColor(srgbRed: lightComponent, green: lightComponent, blue: lightComponent, alpha: 1)
    }

    static func feedback(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.08)
            : .spring(response: 0.24, dampingFraction: 1)
    }

    static func presentation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.32, dampingFraction: 1)
    }
}

struct UtilityWindowPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(
                UtilityWindowDesign.feedback(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct UtilityWindowGroupedSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(UtilityWindowDesign.groupedSurfaceFill)
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 0.5)
            )
    }
}

struct UtilityWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        )
    }
}

extension View {
    func utilityWindowBackground() -> some View {
        modifier(UtilityWindowBackground())
    }

    func utilityWindowGroupedSurface(
        cornerRadius: CGFloat = UtilityWindowDesign.cornerRadius
    ) -> some View {
        modifier(UtilityWindowGroupedSurface(cornerRadius: cornerRadius))
    }
}
