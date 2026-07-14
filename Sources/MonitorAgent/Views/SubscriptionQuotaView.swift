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
    @State private var cardWidth: CGFloat = 0
    @State private var tipAnchorX: CGFloat = 0
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { cardWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in cardWidth = newValue }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .bottomLeading) {
            if isResetTipPresented,
               let snapshot,
               let credits = snapshot.resetCredits,
               credits > 0 {
                ResetCreditsTip(
                    count: credits,
                    expirations: snapshot.resetCreditExpirations
                )
                .offset(x: clampedTipX, y: -(QuotaCardLayout.cardHeight + 6))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
        .zIndex(isResetTipPresented ? 2 : 0)
        .onContinuousHover { phase in
            guard hasResetCredits else { return }
            switch phase {
            case .active(let location):
                if !isResetTipPresented { tipAnchorX = location.x }
                withAnimation(.easeOut(duration: 0.12)) { isResetTipPresented = true }
            case .ended:
                withAnimation(.easeOut(duration: 0.12)) { isResetTipPresented = false }
            }
        }
    }

    private var hasResetCredits: Bool {
        (snapshot?.resetCredits ?? 0) > 0
    }

    /// Center the tip on the initial hover x while keeping it inside the card bounds.
    private var clampedTipX: CGFloat {
        let maxX = max(0, cardWidth - QuotaCardLayout.resetTipWidth)
        return min(max(0, tipAnchorX - QuotaCardLayout.resetTipWidth / 2), maxX)
    }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderIcon(provider: provider)
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
                ForEach(Array(metricItems(snapshot).enumerated()), id: \.offset) { _, item in
                    quotaMetric(label: item.label, window: item.window, reset: item.reset)
                }
                if provider == .codex, let credits = snapshot.resetCredits, credits > 0 {
                    HStack(spacing: 5) {
                        Text("resets")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(credits)")
                            .fontWeight(.semibold)
                            .foregroundStyle(resetCreditCountColor(
                                expirations: snapshot.resetCreditExpirations
                            ))
                        if let expiration = ResetCreditExpiration.next(
                            in: snapshot.resetCreditExpirations
                        ) {
                            Text(QuotaDateFormat.resetDateTime(expiration))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
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

    private func metricItems(_ snapshot: QuotaSnapshot) -> [QuotaMetricItem] {
        var items: [QuotaMetricItem] = []
        if let window = snapshot.fiveHour {
            items.append(metricItem(fallbackLabel: "5h", window: window))
        }
        if let window = snapshot.weekly {
            items.append(metricItem(fallbackLabel: "1w", window: window))
        }
        if provider == .claude, let window = snapshot.opusWeekly {
            items.append(.init(label: "Opus", window: window, reset: QuotaDateFormat.resetDateTime(window.resetsAt)))
        }
        return items
    }

    private func metricItem(fallbackLabel: String, window: QuotaWindow) -> QuotaMetricItem {
        let label = provider == .codex ? window.displayLabel(fallback: fallbackLabel) : fallbackLabel
        let reset = window.usesDateTimeReset || fallbackLabel == "1w"
            ? QuotaDateFormat.resetDateTime(window.resetsAt)
            : QuotaDateFormat.resetTime(window.resetsAt)
        return QuotaMetricItem(label: label, window: window, reset: reset)
    }

    private func quotaMetric(label: String, window: QuotaWindow, reset: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .fontWeight(.semibold)
                .foregroundStyle(quotaColor(window.remainingPercent))
            Text(reset)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
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

    private func resetCreditCountColor(expirations: [Date]) -> Color {
        switch ResetCreditExpiration.urgency(in: expirations) {
        case nil, .standard: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

}

private struct QuotaMetricItem {
    let label: String
    let window: QuotaWindow
    let reset: String
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
                    .padding(.vertical, 5)
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
    static let fullReset = "Full reset"
    static let expirationUnavailable = "Expiration unavailable"

    static func availableCount(_ count: Int) -> String {
        "\(count) available"
    }

    static func expires(_ date: String) -> String {
        "Expires \(date)"
    }
}

enum ResetCreditExpirationUrgency: Equatable {
    case standard
    case warning
    case critical
}

enum ResetCreditExpiration {
    static let warningInterval: TimeInterval = 7 * 24 * 60 * 60
    static let criticalInterval: TimeInterval = 3 * 24 * 60 * 60

    static func next(in expirations: [Date], after now: Date = Date()) -> Date? {
        expirations.filter { $0 > now }.min()
    }

    static func urgency(
        in expirations: [Date],
        after now: Date = Date()
    ) -> ResetCreditExpirationUrgency? {
        guard let expiration = next(in: expirations, after: now) else { return nil }
        return urgency(for: expiration, now: now)
    }

    static func urgency(for expiration: Date, now: Date = Date()) -> ResetCreditExpirationUrgency {
        let remaining = expiration.timeIntervalSince(now)
        if remaining < criticalInterval { return .critical }
        if remaining < warningInterval { return .warning }
        return .standard
    }
}

enum QuotaCardLayout {
    static let cardHeight: CGFloat = 34
    static let metricHeight: CGFloat = 20
    static let contentSpacing: CGFloat = 16
    static let metricSpacing: CGFloat = 28
    static let resetTipWidth: CGFloat = 280
}
