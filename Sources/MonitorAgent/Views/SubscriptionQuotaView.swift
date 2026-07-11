import SwiftUI

struct SubscriptionQuotaView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager

    private var providers: [QuotaProviderID] {
        store.visibleQuotaProviders.filter(QuotaSettings.shared.isEnabled)
    }

    var body: some View {
        if !providers.isEmpty {
            VStack(spacing: 8) {
                Divider().opacity(theme.dividerOpacity)
                ForEach(providers, id: \.self) { provider in
                    SubscriptionQuotaCard(
                        provider: provider,
                        snapshot: store.quotaSnapshots[provider]
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

private struct SubscriptionQuotaCard: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var isResetTipPresented = false
    let provider: QuotaProviderID
    let snapshot: QuotaSnapshot?

    var body: some View {
        HStack(spacing: QuotaCardLayout.contentSpacing) {
            header

            if let snapshot {
                snapshotContent(snapshot)
            } else {
                loadingContent
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: QuotaCardLayout.cardHeight)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if isResetTipPresented,
               let snapshot,
               let credits = snapshot.resetCredits,
               credits > 0 {
                ResetCreditsTip(
                    count: credits,
                    expirations: snapshot.resetCreditExpirations
                )
                .offset(y: -(QuotaCardLayout.cardHeight + 6))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .zIndex(isResetTipPresented ? 2 : 0)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: provider == .claude ? "sparkles" : "terminal")
                .foregroundStyle(provider == .claude ? .orange : .blue)
            Text(provider.displayName)
                .fontWeight(.semibold)

            if let plan = snapshot?.plan, !plan.isEmpty, snapshot?.status == .available {
                Text("· \(plan)")
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .layoutPriority(2)
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: QuotaSnapshot) -> some View {
        switch snapshot.status {
        case .available:
            HStack(spacing: QuotaCardLayout.metricSpacing) {
                if let window = snapshot.fiveHour {
                    quotaMetric(
                        label: "5h",
                        window: window,
                        reset: QuotaDateFormat.resetTime(window.resetsAt)
                    )
                }
                if let window = snapshot.weekly {
                    quotaMetric(
                        label: "1w",
                        window: window,
                        reset: QuotaDateFormat.resetDateTime(window.resetsAt)
                    )
                }
                if provider == .claude, let window = snapshot.opusWeekly {
                    quotaMetric(
                        label: "Opus",
                        window: window,
                        reset: QuotaDateFormat.resetDateTime(window.resetsAt)
                    )
                }
                if provider == .codex, let credits = snapshot.resetCredits, credits > 0 {
                    Text(ResetCreditsCopy.resetCount(credits))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.06))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isResetTipPresented = hovering
                            }
                        }
                }
            }
        case .notInstalled:
            statusText("\(provider.displayName) not detected")
        case .thirdPartyConfigured:
            statusText("Third-party API configured · Subscription quota unavailable")
        case .signedOut:
            statusText("Subscription sign-in not found")
        case .authenticationExpired:
            statusText("Subscription sign-in expired")
        case .unavailable(let message):
            statusText(message)
        }
    }

    private func quotaMetric(label: String, window: QuotaWindow, reset: String) -> some View {
        VStack(spacing: QuotaCardLayout.progressSpacing) {
            HStack(spacing: 5) {
                Text(label)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(quotaColor(window.remainingPercent))
                    .frame(minWidth: QuotaCardLayout.percentageWidth, alignment: .trailing)
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(quotaColor(window.remainingPercent))
                        .frame(width: proxy.size.width * normalizedProgress(window.remainingPercent))
                }
            }
            .frame(height: QuotaCardLayout.progressHeight)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(maxWidth: .infinity)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: QuotaCardLayout.metricHeight)
    }

    private var loadingContent: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading quota")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: QuotaCardLayout.metricHeight)
    }

    private func quotaColor(_ percent: Double) -> Color {
        if percent < 20 { return .red }
        if percent < 50 { return .orange }
        return .green
    }

    private func normalizedProgress(_ percent: Double) -> CGFloat {
        CGFloat(min(100, max(0, percent)) / 100)
    }

}

private struct ResetCreditsTip: View {
    @EnvironmentObject var theme: ThemeManager
    let count: Int
    let expirations: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(ResetCreditsCopy.title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(ResetCreditsCopy.availableCount(count))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green)
            }

            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 {
                        Divider().overlay(theme.tooltipForeground.opacity(0.12))
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(ResetCreditsCopy.fullReset)
                            .font(.system(size: 10, weight: .medium))
                        Spacer(minLength: 12)
                        Text(expirationText(at: index))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                    }
                    .padding(.vertical, 7)
                }
            }
        }
        .foregroundStyle(theme.tooltipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: QuotaCardLayout.resetTipWidth)
        .background(theme.tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
        .contentShape(Rectangle())
        .onHover { _ in }
    }

    private func expirationText(at index: Int) -> String {
        guard expirations.indices.contains(index) else { return ResetCreditsCopy.expirationUnavailable }
        return ResetCreditsCopy.expires(QuotaDateFormat.resetDateTime(expirations[index]))
    }
}

enum ResetCreditsCopy {
    static let title = "Usage limit resets"
    static let fullReset = "Full reset (1w + 5h)"
    static let expirationUnavailable = "Expiration unavailable"

    static func availableCount(_ count: Int) -> String {
        "\(count) available"
    }

    static func resetCount(_ count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s")"
    }

    static func expires(_ date: String) -> String {
        "Expires \(date)"
    }
}

enum QuotaCardLayout {
    static let cardHeight: CGFloat = 50
    static let metricHeight: CGFloat = 28
    static let progressHeight: CGFloat = 4
    static let progressSpacing: CGFloat = 5
    static let percentageWidth: CGFloat = 28
    static let contentSpacing: CGFloat = 12
    static let metricSpacing: CGFloat = 12
    static let resetTipWidth: CGFloat = 280
}
