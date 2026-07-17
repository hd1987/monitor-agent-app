import SwiftUI

enum UtilityWindowDesign {
    static let cornerRadius: CGFloat = 10
    static let compactCornerRadius: CGFloat = 7

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
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 0.5)
            )
    }
}

extension View {
    func utilityWindowGroupedSurface(
        cornerRadius: CGFloat = UtilityWindowDesign.cornerRadius
    ) -> some View {
        modifier(UtilityWindowGroupedSurface(cornerRadius: cornerRadius))
    }
}
