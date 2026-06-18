import SwiftUI

struct StatCardsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            StatCard(title: "Requests", value: formatCount(store.stats.totalRequests))
            StatCard(title: "Sessions", value: formatCount(store.stats.totalSessions))
            StatCard(title: "Input Tokens", value: formatTokens(store.stats.inputTokens))
            StatCard(title: "Output Tokens", value: formatTokens(store.stats.outputTokens))
            StatCard(title: "Cache Read", value: formatTokens(store.stats.cacheReadTokens))
            StatCard(title: "Cache Hit", value: formatPercent(store.stats.cacheHitRate))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct StatCard: View {
    @EnvironmentObject var theme: ThemeManager
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Formatting

func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func formatTokens(_ n: Int64) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func formatPercent(_ rate: Double) -> String {
    String(format: "%.1f%%", rate * 100)
}
