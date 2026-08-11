import SwiftUI

struct StatCardsView: View {
    @EnvironmentObject var store: AppStore
    @Binding var activeTip: StatCardTip?

    var body: some View {
        HStack(spacing: StatCardLayout.spacing) {
            StatCard(
                title: "Requests",
                value: isCursorUnavailable ? "—" : formatCount(store.stats.totalRequests)
            )
                .frame(width: cardWidth)
            StatCard(
                title: "Sessions",
                value: isCursorUnavailable ? "—" : formatCount(store.stats.totalSessions)
            )
                .frame(width: cardWidth)
            TokenSummaryCard(
                stats: store.stats,
                isAvailable: !isCursorUnavailable,
                activeTip: $activeTip
            )
                .frame(width: cardWidth)
            CacheHitCard(stats: store.stats, isAvailable: !isCursorUnavailable)
                .frame(width: cardWidth)
            if store.appFilter == .cursor {
                CursorSpendSummaryCard(snapshot: store.cursorSpendSnapshot)
                    .frame(width: cardWidth)
            }
        }
        .padding(.horizontal, MainPanelDesign.horizontalPadding)
        .padding(.vertical, MainPanelDesign.sectionVerticalPadding)
    }

    private var cardWidth: CGFloat {
        StatCardLayout.equalCardWidth(cardCount: store.appFilter == .cursor ? 5 : 4)
    }

    private var isCursorUnavailable: Bool {
        store.appFilter == .cursor && !store.isCursorDataPresentationAvailable
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

struct StatCard: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let value: String

    var body: some View {
        StatCardContainer {
            VStack(spacing: 4) {
                statCardTitle(title, color: theme.panelSecondaryForeground)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct TokenSummaryCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stats: UsageStats
    let isAvailable: Bool
    @Binding var activeTip: StatCardTip?

    private var isDetailPresented: Bool {
        isAvailable && activeTip == .tokenBreakdown
    }

    var body: some View {
        VStack(spacing: 0) {
            StatCardContainer {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 4) {
                        statCardTitle("Tokens", color: theme.panelSecondaryForeground)
                        Text(isAvailable ? formatTokenDetail(stats.totalTokens) : "—")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

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
                    .offset(y: 56)
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

private struct CacheHitCard: View {
    let stats: UsageStats
    let isAvailable: Bool

    var body: some View {
        StatCard(
            title: "Cache Hit",
            value: isAvailable ? formatPercent(stats.cacheHitRate) : "—"
        )
            .help(cacheHitHelp())
    }
}

private struct CursorSpendSummaryCard: View {
    @EnvironmentObject private var theme: ThemeManager
    let snapshot: CursorSpendSnapshot?

    var body: some View {
        StatCardContainer {
            VStack(spacing: 4) {
                spendRow(label: "Total", cents: snapshot?.totalCents, emphasized: true)
                spendRow(label: "On-Demand", cents: snapshot?.onDemandCents, emphasized: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func spendRow(label: String, cents: Int?, emphasized: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.panelSecondaryForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            Text(formatCursorSpend(cents))
                .font(.system(
                    size: emphasized ? 12 : 10,
                    weight: emphasized ? .semibold : .medium,
                    design: .rounded
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.primary)
        }
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
    @ViewBuilder let content: Content

    var body: some View {
        content
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .mainPanelGroupedSurface()
    }
}

private func statCardTitle(_ title: String, color: Color) -> some View {
    Text(title)
        .font(.system(size: 10, weight: .medium))
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
    String(format: "%.1f%%", rate * 100)
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
