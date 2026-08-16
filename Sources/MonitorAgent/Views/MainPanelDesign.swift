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
    static let refreshIndicatorHeight: CGFloat = 2
    static let refreshIndicatorHorizontalInset: CGFloat = 16
    static let horizontalPadding: CGFloat = 16
    static let sectionVerticalPadding: CGFloat = 10
}

struct MainPanelRefreshProgressOverlay: ViewModifier {
    let isRefreshing: Bool
    let tint: Color

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isRefreshing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(tint)
                    .frame(maxWidth: .infinity)
                    .frame(height: MainPanelDesign.refreshIndicatorHeight)
                    .clipped()
                    .padding(.horizontal, MainPanelDesign.refreshIndicatorHorizontalInset)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Refreshing panel data")
            }
        }
    }
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

struct MainPanelHeaderToolButton<Label: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let helpText: String
    let accessibilityText: String
    let isSelected: Bool
    let action: () -> Void
    let label: (Color) -> Label
    @State private var isHovered = false

    init(
        helpText: String,
        accessibilityText: String,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping (Color) -> Label
    ) {
        self.helpText = helpText
        self.accessibilityText = accessibilityText
        self.isSelected = isSelected
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label(foreground)
                .frame(
                    width: MainPanelDesign.headerControlItemHeight,
                    height: MainPanelDesign.headerControlItemHeight
                )
                .background {
                    Circle()
                        .fill(isEnabled && isHovered ? theme.controlSurface : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(MainPanelPressButtonStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering in
            isHovered = isEnabled && hovering
        }
        .animation(
            MainPanelMotion.feedback(reduceMotion: reduceMotion),
            value: isHovered
        )
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var foreground: Color {
        if isSelected {
            return theme.selectedControlAccent
        }
        return theme.panelTertiaryForeground.opacity(MainPanelDesign.headerToolOpacity)
    }
}

struct UnifiedRefreshButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let cooldownRemaining = store.manualRefreshCooldownRemaining(at: context.date)
            let isCoolingDown = cooldownRemaining > 0 && !store.isRefreshInProgress

            MainPanelHeaderToolButton(
                helpText: store.isRefreshInProgress
                    ? "Refreshing Data"
                    : (isCoolingDown ? "Refresh unavailable during cooldown" : "Refresh Data"),
                accessibilityText: "Refresh data",
                action: store.refreshNow
            ) { foreground in
                RefreshStatusIcon(
                    isRefreshing: store.isManualRefreshInProgress,
                    foreground: foreground,
                    reduceMotion: reduceMotion
                )
            }
            .disabled(
                store.isRebuildingUsageData
                    || !store.hasEnabledAgents
                    || cooldownRemaining > 0
            )
        }
    }
}

private struct RefreshStatusIcon: View {
    let isRefreshing: Bool
    let foreground: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !isRefreshing || reduceMotion
            )
        ) { context in
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .rotationEffect(.degrees(rotation(at: context.date)))
        }
    }

    private func rotation(at date: Date) -> Double {
        guard isRefreshing, !reduceMotion else { return 0 }
        let cycleDuration = 0.8
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * 360
    }
}

struct MainPanelChartButton: View {
    let chartStyle: ActivityChartStyle
    let helpText: String
    let accessibilityText: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        MainPanelHeaderToolButton(
            helpText: helpText,
            accessibilityText: accessibilityText,
            isSelected: isSelected,
            action: action
        ) { foreground in
            Image(nsImage: chartStyle == .line
                ? MainPanelIconAsset.lineChartImage
                : MainPanelIconAsset.barChartImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(foreground)
                .frame(width: 11, height: 11)
        }
    }
}

struct MainPanelChartStyleSwitchButton: View {
    let currentStyle: ActivityChartStyle
    let action: () -> Void

    private var targetStyle: ActivityChartStyle { currentStyle.toggled }

    var body: some View {
        MainPanelHeaderToolButton(
            helpText: "Switch to \(targetStyle.displayName)",
            accessibilityText: "Switch Activity detail to \(targetStyle.displayName.lowercased())",
            action: action
        ) { foreground in
            Image(nsImage: currentStyle == .line
                ? MainPanelIconAsset.lineChartImage
                : MainPanelIconAsset.barChartImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(foreground)
                .frame(width: 11, height: 11)
        }
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
    func mainPanelRefreshProgress(isRefreshing: Bool, tint: Color) -> some View {
        modifier(
            MainPanelRefreshProgressOverlay(
                isRefreshing: isRefreshing,
                tint: tint
            )
        )
    }

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
