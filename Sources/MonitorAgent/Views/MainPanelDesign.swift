import SwiftUI

enum MainPanelDesign {
    static let width: CGFloat = 620
    static let cornerRadius: CGFloat = 16
    static let groupedCornerRadius: CGFloat = 10
    static let controlCornerRadius: CGFloat = 8
    static let headerControlHeight: CGFloat = 28
    static let headerControlItemHeight: CGFloat = 24
    static let headerToolOpacity = 0.62
    static let highlightedHeaderToolOpacity = 0.48
    static let lightGroupedSurfaceOpacity = 0.032
    static let darkGroupedSurfaceOpacity = 0.075
    static let horizontalPadding: CGFloat = 16
    static let sectionVerticalPadding: CGFloat = 10
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

extension View {
    func mainPanelGroupedSurface(
        cornerRadius: CGFloat = MainPanelDesign.groupedCornerRadius
    ) -> some View {
        modifier(MainPanelGroupedSurface(cornerRadius: cornerRadius))
    }

    func mainPanelSectionTitle() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.82))
    }
}
