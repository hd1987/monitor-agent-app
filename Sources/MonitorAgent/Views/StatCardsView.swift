import SwiftUI

struct StatCardsView: View {
    @EnvironmentObject var store: AppStore
    @Binding var isTokenBreakdownPresented: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatCard(title: "Requests", value: formatCount(store.stats.totalRequests))
                .frame(width: StatCardLayout.requestsWidth)
            StatCard(title: "Sessions", value: formatCount(store.stats.totalSessions))
                .frame(width: StatCardLayout.sessionsWidth)
            TokenSummaryCard(stats: store.stats, isDetailPresented: $isTokenBreakdownPresented)
                .frame(width: StatCardLayout.tokensWidth)
            CacheHitCard(stats: store.stats)
                .frame(width: StatCardLayout.cacheHitWidth)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

enum StatCardLayout {
    static let metricWidth: CGFloat = 128
    static let requestsWidth: CGFloat = metricWidth
    static let sessionsWidth: CGFloat = metricWidth
    static let cacheHitWidth: CGFloat = metricWidth
    static let tokensWidth: CGFloat = 180
    static let titleRowHeight: CGFloat = 12
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        StatCardContainer {
            VStack(spacing: 4) {
                statCardTitle(title)
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct TokenSummaryCard: View {
    let stats: UsageStats
    @Binding var isDetailPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatCardContainer {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 4) {
                        statCardTitle("Tokens")
                        Text(formatTokenDetail(stats.totalTokens))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
        .overlay(alignment: .top) {
            if isDetailPresented {
                TokenBreakdownTip(stats: stats)
                    .offset(y: 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isDetailPresented = isHovering
            }
        }
        .zIndex(isDetailPresented ? 1 : 0)
    }
}

private struct CacheHitCard: View {
    let stats: UsageStats

    var body: some View {
        StatCard(title: "Cache Hit", value: formatPercent(stats.cacheHitRate))
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

            VStack(alignment: .leading, spacing: 6) {
                tokenRow(label: "Input", color: .blue, value: stats.inputTokens)
                tokenRow(label: "Output", color: .green, value: stats.outputTokens)
                tokenRow(label: "Cache Read", color: .orange, value: stats.cacheReadTokens)
                tokenRow(label: "Cache Creation", color: .purple, value: stats.cacheCreationTokens)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(theme.tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
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
    @EnvironmentObject var theme: ThemeManager
    @ViewBuilder let content: Content

    var body: some View {
        content
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
    }
}

private func statCardTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
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
