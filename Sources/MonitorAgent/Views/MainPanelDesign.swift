import SwiftUI

enum MainPanelDesign {
    static let width: CGFloat = 620
    static let cornerRadius: CGFloat = 16
    static let groupedCornerRadius: CGFloat = 10
    static let controlCornerRadius: CGFloat = 8
    static let headerControlHeight: CGFloat = 28
    static let headerControlItemHeight: CGFloat = 24
    static let headerToolSpacing: CGFloat = 4
    static let headerToolOpacity = 0.46
    static let lightGroupedSurfaceOpacity = 0.032
    static let darkGroupedSurfaceOpacity = 0.075
    static let horizontalPadding: CGFloat = 16
    static let sectionVerticalPadding: CGFloat = 10
}

enum MainPanelSelectionPalette {
    static let accent = ActivityTokenPalette.input
    static let tabBackgroundOpacity = 0.38
}

enum MainPanelTooltipDesign {
    static let cornerRadius: CGFloat = 6
    static let borderOpacity = 0.12
    static let shadowOpacity = 0.10
    static let shadowRadius: CGFloat = 5
    static let shadowYOffset: CGFloat = 2
}

enum MainPanelMotion {
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

struct MainPanelPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                MainPanelMotion.feedback(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct MainPanelGroupedSurface: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(theme.groupedSurface)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
    }
}

struct MainPanelTooltipSurface: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager

    func body(content: Content) -> some View {
        content
            .background(theme.tooltipBackground)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MainPanelTooltipDesign.cornerRadius,
                    style: .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: MainPanelTooltipDesign.cornerRadius,
                    style: .continuous
                )
                .stroke(
                    Color.white.opacity(MainPanelTooltipDesign.borderOpacity),
                    lineWidth: 0.5
                )
            )
            .shadow(
                color: Color.black.opacity(MainPanelTooltipDesign.shadowOpacity),
                radius: MainPanelTooltipDesign.shadowRadius,
                x: 0,
                y: MainPanelTooltipDesign.shadowYOffset
            )
    }
}

extension View {
    func mainPanelGroupedSurface(
        cornerRadius: CGFloat = MainPanelDesign.groupedCornerRadius
    ) -> some View {
        modifier(MainPanelGroupedSurface(cornerRadius: cornerRadius))
    }

    func mainPanelTooltipSurface() -> some View {
        modifier(MainPanelTooltipSurface())
    }

    func mainPanelSectionTitle() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.82))
    }
}
