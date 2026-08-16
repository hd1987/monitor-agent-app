import SwiftUI

struct StatCardsView: View {
    @EnvironmentObject var store: AppStore
    @Binding var activeTip: StatCardTip?
    let onOpenRequests: () -> Void

    var body: some View {
        HStack(spacing: StatCardLayout.spacing) {
            detailButton {
                StatCard(
                    title: "Requests",
                    value: isCursorUnavailable ? "—" : formatCount(store.stats.totalRequests)
                )
            }
                .frame(width: cardWidth)

            detailButton {
                StatCard(
                    title: "Sessions",
                    value: isCursorUnavailable ? "—" : formatCount(store.stats.totalSessions)
                )
            }
                .frame(width: cardWidth)

            detailButton {
                TokenSummaryCard(
                    stats: store.stats,
                    isAvailable: !isCursorUnavailable,
                    activeTip: $activeTip
                )
            }
                .frame(width: cardWidth)

            detailButton {
                CacheHitCard(stats: store.stats, isAvailable: !isCursorUnavailable)
            }
                .frame(width: cardWidth)

            detailButton {
                StatCard(
                    title: "Total Usage",
                    value: totalUsageValue
                )
            }
                .frame(width: cardWidth)
        }
        .padding(.horizontal, MainPanelDesign.horizontalPadding)
        .padding(.vertical, MainPanelDesign.sectionVerticalPadding)
    }

    private var cardWidth: CGFloat {
        StatCardLayout.equalCardWidth(cardCount: StatCardLayout.visibleCardCount)
    }

    private var isCursorUnavailable: Bool {
        store.appFilter == .cursor && !store.isCursorDataPresentationAvailable
    }

    private var totalUsageValue: String {
        formatTotalUsage(
            store.cursorSpendSnapshot?.totalCents,
            for: store.appFilter
        )
    }

    private func detailButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onOpenRequests) {
            content()
        }
        .buttonStyle(MainPanelPressButtonStyle())
        .help("Open request details")
        .accessibilityHint("Open request details")
    }
}

enum StatCardTip: Hashable {
    case tokenBreakdown
}

enum StatCardTipLayer {
    static func zIndex(for activeTip: StatCardTip?) -> Double {
        activeTip == nil ? 0 : 1
    }
}

enum StatCardLayout {
    static let spacing: CGFloat = 8
    static let visibleCardCount = 5
    static let availableWidth = MainPanelDesign.width - 2 * MainPanelDesign.horizontalPadding
    static let titleRowHeight: CGFloat = 12

    static func equalCardWidth(cardCount: Int) -> CGFloat {
        guard cardCount > 0 else { return 0 }
        return (availableWidth - spacing * CGFloat(cardCount - 1)) / CGFloat(cardCount)
    }
}

enum TokenBreakdownTipLayout {
    static let itemSpacing: CGFloat = 8
}

enum StatCardPresentation: Equatable {
    case mainPanel
    case detailSummary

    var height: CGFloat {
        switch self {
        case .mainPanel: 54
        case .detailSummary: 64
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .mainPanel: 10
        case .detailSummary: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .mainPanel: 8
        case .detailSummary: 11
        }
    }

    var titleFont: Font {
        .system(size: 10, weight: .medium)
    }

    var valueFont: Font {
        .system(size: 17, weight: .semibold, design: .rounded)
    }

    var alignment: Alignment {
        .center
    }

    var usesIndividualSurface: Bool { self == .mainPanel }
}

struct StatCard: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let value: String
    var presentation: StatCardPresentation = .mainPanel

    var body: some View {
        StatCardContainer(presentation: presentation) {
            VStack(spacing: 4) {
                statCardTitle(
                    title,
                    color: theme.panelSecondaryForeground,
                    presentation: presentation
                )
                Text(value)
                    .font(presentation.valueFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: presentation.alignment)
        }
    }
}

struct TokenSummaryCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stats: UsageStats
    let isAvailable: Bool
    @Binding var activeTip: StatCardTip?
    var presentation: StatCardPresentation = .mainPanel

    private var isDetailPresented: Bool {
        isAvailable && activeTip == .tokenBreakdown
    }

    var body: some View {
        VStack(spacing: 0) {
            StatCardContainer(presentation: presentation) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 4) {
                        statCardTitle(
                            "Tokens",
                            color: theme.panelSecondaryForeground,
                            presentation: presentation
                        )
                        Text(isAvailable ? formatTokenDetail(stats.totalTokens) : "—")
                            .font(presentation.valueFont)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(.primary)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: presentation.alignment
                    )

                    if isAvailable {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.panelTertiaryForeground)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if isDetailPresented {
                TokenBreakdownTip(stats: stats)
                    .frame(width: 180)
                    .offset(y: presentation.height + 2)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
            }
        }
        .onHover { isHovering in
            guard isAvailable else {
                activeTip = nil
                return
            }
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                if isHovering {
                    activeTip = .tokenBreakdown
                } else if activeTip == .tokenBreakdown {
                    activeTip = nil
                }
            }
        }
        .onChange(of: isAvailable) { _, isAvailable in
            if !isAvailable, activeTip == .tokenBreakdown {
                activeTip = nil
            }
        }
        .zIndex(isDetailPresented ? 1 : 0)
    }
}

struct CacheHitCard: View {
    let stats: UsageStats
    let isAvailable: Bool
    var presentation: StatCardPresentation = .mainPanel

    var body: some View {
        StatCard(
            title: "Cache Hit",
            value: isAvailable ? formatPercent(stats.cacheHitRate) : "—",
            presentation: presentation
        )
            .help(cacheHitHelp())
    }
}

private struct TokenBreakdownTip: View {
    @EnvironmentObject var theme: ThemeManager
    let stats: UsageStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tokens")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tooltipForeground)
                Spacer()
                Text(formatTokens(stats.totalTokens))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(theme.tooltipForeground)
            }

            VStack(alignment: .leading, spacing: TokenBreakdownTipLayout.itemSpacing) {
                tokenRow(label: "Input", color: ActivityTokenPalette.input, value: stats.inputTokens)
                tokenRow(label: "Output", color: ActivityTokenPalette.output, value: stats.outputTokens)
                tokenRow(label: "Cache Read", color: ActivityTokenPalette.cacheRead, value: stats.cacheReadTokens)
                tokenRow(label: "Cache Creation", color: ActivityTokenPalette.cacheCreation, value: stats.cacheCreationTokens)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .mainPanelTooltipSurface()
        .contentShape(Rectangle())
    }

    private func tokenRow(label: String, color: Color, value: Int64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(theme.tooltipForeground.opacity(0.78))
            Spacer(minLength: 12)
            Text(formatTokens(value))
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(theme.tooltipForeground)
        }
        .font(.system(size: 10))
    }
}

private struct StatCardContainer<Content: View>: View {
    let presentation: StatCardPresentation
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, presentation.horizontalPadding)
            .padding(.vertical, presentation.verticalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: presentation.height)
            .modifier(StatCardSurfaceModifier(isEnabled: presentation.usesIndividualSurface))
    }
}

private struct StatCardSurfaceModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.mainPanelGroupedSurface()
        } else {
            content
        }
    }
}

private func statCardTitle(
    _ title: String,
    color: Color,
    presentation: StatCardPresentation
) -> some View {
    Text(title)
        .font(presentation.titleFont)
        .foregroundStyle(color)
        .frame(height: StatCardLayout.titleRowHeight, alignment: .center)
}

private func cacheHitHelp() -> String {
    "Cache Read / (Input + Cache Read + Cache Creation)"
}

// MARK: - Formatting

func formatCount(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func formatTokens(_ n: Int64) -> String {
    if n >= 999_995_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
    if n >= 999_995 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.2fK", Double(n) / 1_000) }
    return "\(n)"
}

func formatTokenDetail(_ n: Int64) -> String {
    formatTokens(n)
}

func formatPercent(_ rate: Double) -> String {
    guard rate != 0 else { return "0%" }
    return String(format: "%.1f%%", rate * 100)
}

func formatCursorSpend(_ cents: Int?) -> String {
    guard let cents, cents >= 0 else { return "—" }
    guard cents != 0 else { return "$0" }
    return String(
        format: "$%.2f",
        locale: Locale(identifier: "en_US_POSIX"),
        arguments: [Double(cents) / 100]
    )
}

func formatTotalUsage(_ cents: Int?, for filter: AppFilter) -> String {
    guard filter == .all || filter == .cursor else { return "—" }
    return formatCursorSpend(cents)
}
