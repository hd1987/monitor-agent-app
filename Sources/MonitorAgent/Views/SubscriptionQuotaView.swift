import SwiftUI

struct SubscriptionQuotaView: View {
    @EnvironmentObject var store: AppStore

    private var providers: [QuotaProviderID] {
        store.visibleQuotaProviders.filter(QuotaSettings.shared.isEnabled)
    }

    var body: some View {
        if !providers.isEmpty {
            VStack(spacing: 8) {
                ForEach(providers, id: \.self) { provider in
                    SubscriptionQuotaCard(
                        provider: provider,
                        snapshot: store.quotaSnapshots[provider],
                        expirationDate: QuotaSettings.shared.expirationDate(for: provider)
                    )
                }
            }
            .padding(.horizontal, MainPanelDesign.horizontalPadding)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
    }
}

private struct SubscriptionQuotaCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpirationTipPresented = false
    @State private var isResetTipPresented = false
    @State private var cardWidth: CGFloat = 0
    @State private var rightRegionWidth: CGFloat = 0
    @State private var resetTipAnchorX: CGFloat = 0
    let provider: QuotaProviderID
    let snapshot: QuotaSnapshot?
    let expirationDate: Date?

    var body: some View {
        HStack(spacing: 0) {
            header
                .padding(.trailing, QuotaCardLayout.expirationHoverInset)
                .frame(maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        guard expirationDate != nil else { return }
                        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                            isExpirationTipPresented = true
                        }
                    case .ended:
                        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                            isExpirationTipPresented = false
                        }
                    }
                }
            Spacer(minLength: QuotaCardLayout.contentSpacing)
            if let snapshot {
                snapshotContent(snapshot)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { rightRegionWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, newValue in
                                    rightRegionWidth = newValue
                                }
                        }
                    )
                    .onContinuousHover { phase in
                        guard hasResetCredits(snapshot) else { return }
                        switch phase {
                        case .active(let location):
                            if !isResetTipPresented {
                                resetTipAnchorX = max(
                                    0,
                                    cardWidth - QuotaCardLayout.horizontalPadding - rightRegionWidth
                                ) + location.x
                            }
                            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                                isResetTipPresented = true
                            }
                        case .ended:
                            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                                isResetTipPresented = false
                            }
                        }
                    }
            } else {
                loadingContent
                    .frame(maxHeight: .infinity)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, QuotaCardLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: QuotaCardLayout.cardHeight)
        .mainPanelGroupedSurface()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { cardWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in cardWidth = newValue }
            }
        )
        .overlay(alignment: .bottomLeading) {
            if isExpirationTipPresented, let expirationDate {
                SubscriptionExpirationTip(expirationDate: expirationDate)
                    .padding(.leading, 8)
                    .offset(y: -(QuotaCardLayout.cardHeight + 6))
                    .allowsHitTesting(false)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading))
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isResetTipPresented,
               let snapshot,
               let credits = snapshot.resetCredits,
               credits > 0 {
                ResetCreditsTip(
                    count: credits,
                    expirations: snapshot.resetCreditExpirations
                )
                .offset(x: clampedResetTipX, y: -(QuotaCardLayout.cardHeight + 6))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            }
        }
        .zIndex(isExpirationTipPresented || isResetTipPresented ? 2 : 0)
    }

    private var clampedResetTipX: CGFloat {
        let maxX = max(0, cardWidth - QuotaCardLayout.resetTipWidth)
        return min(max(0, resetTipAnchorX - QuotaCardLayout.resetTipWidth / 2), maxX)
    }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderIcon(provider: provider)
            Text(provider.displayName)
                .fontWeight(.semibold)

            if let plan = snapshot?.plan, !plan.isEmpty, snapshot?.status == .available {
                Text("· \(plan)")
                    .foregroundStyle(planColor)
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
                            .foregroundStyle(theme.panelSecondaryForeground)
                        Text("·")
                            .foregroundStyle(theme.panelSecondaryForeground)
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
                                .foregroundStyle(theme.panelSecondaryForeground)
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
                .foregroundStyle(theme.panelSecondaryForeground)
            Text("·")
                .foregroundStyle(theme.panelSecondaryForeground)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .fontWeight(.semibold)
                .foregroundStyle(quotaColor(window.remainingPercent))
            Text(reset)
                .font(.system(size: 10))
                .foregroundStyle(theme.panelSecondaryForeground)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(theme.panelSecondaryForeground)
            .lineLimit(1)
            .frame(height: QuotaCardLayout.metricHeight)
    }

    private var loadingContent: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Loading quota")
                .foregroundStyle(theme.panelSecondaryForeground)
        }
        .frame(height: QuotaCardLayout.metricHeight)
    }

    private func quotaColor(_ percent: Double) -> Color {
        QuotaStatusPalette.color(for: QuotaRemainingUrgency.level(for: percent))
    }

    private var planColor: Color {
        guard let expirationDate else { return theme.panelSecondaryForeground }
        switch SubscriptionExpiration.urgency(for: expirationDate) {
        case .standard: return theme.panelSecondaryForeground
        case .warning: return QuotaStatusPalette.warning
        case .critical: return QuotaStatusPalette.critical
        }
    }

    private func hasResetCredits(_ snapshot: QuotaSnapshot) -> Bool {
        provider == .codex && (snapshot.resetCredits ?? 0) > 0
    }

    private func resetCreditCountColor(expirations: [Date]) -> Color {
        QuotaStatusPalette.color(
            for: ResetCreditExpiration.urgency(in: expirations) ?? .standard
        )
    }

}

private struct QuotaMetricItem {
    let label: String
    let window: QuotaWindow
    let reset: String
}

private struct SubscriptionExpirationTip: View {
    @EnvironmentObject var theme: ThemeManager
    let expirationDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(SubscriptionExpirationCopy.subscriptionTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(SubscriptionExpirationCopy.expiresTitle)
                    .font(.system(size: 10))
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(SubscriptionExpiration.distanceText(to: expirationDate))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                }
                Spacer()
                Text(SubscriptionExpiration.dateText(expirationDate))
                    .font(.system(size: 10))
            }
        }
        .foregroundStyle(theme.tooltipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: QuotaCardLayout.expirationTipWidth)
        .background(theme.tooltipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
    }

    private var statusColor: Color {
        QuotaStatusPalette.color(for: SubscriptionExpiration.urgency(for: expirationDate))
    }
}

private struct ResetCreditsTip: View {
    @EnvironmentObject var theme: ThemeManager
    let count: Int
    let expirations: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: QuotaCardLayout.resetTipSectionSpacing) {
            HStack {
                Text(ResetCreditsCopy.title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(ResetCreditsCopy.expiresTitle)
                    .font(.system(size: 10))
            }

            VStack(spacing: QuotaCardLayout.resetTipItemSpacing) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(expirationColor(at: index))
                            .frame(width: 6, height: 6)
                        Text(countdownText(at: index))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                        Spacer(minLength: 12)
                        Text(expirationText(at: index))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tooltipForeground)
                    }
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
        return QuotaDateFormat.resetDateTime(expirations[index])
    }

    private func countdownText(at index: Int) -> String {
        guard expirations.indices.contains(index) else { return ResetCreditsCopy.expirationUnavailable }
        return SubscriptionExpiration.distanceText(to: expirations[index])
    }

    private func expirationColor(at index: Int) -> Color {
        guard expirations.indices.contains(index) else { return QuotaStatusPalette.healthy }
        return QuotaStatusPalette.color(
            for: ResetCreditExpiration.urgency(for: expirations[index])
        )
    }
}

enum ResetCreditsCopy {
    static let title = "Usage limit resets"
    static let expiresTitle = "Expires"
    static let expirationUnavailable = "Expiration unavailable"
}

enum SubscriptionExpirationCopy {
    static let subscriptionTitle = "Subscription"
    static let expiresTitle = "Expires"
    static let today = "Today"

    static func days(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days")"
    }

    static func daysExpired(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

enum SubscriptionExpiration {
    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func distanceText(
        to expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let expirationDay = calendar.startOfDay(for: expirationDate)
        let days = calendar.dateComponents([.day], from: today, to: expirationDay).day ?? 0
        if days > 0 { return SubscriptionExpirationCopy.days(days) }
        if days < 0 { return SubscriptionExpirationCopy.daysExpired(abs(days)) }
        return SubscriptionExpirationCopy.today
    }

    static func isExpired(
        _ expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        calendar.startOfDay(for: expirationDate) < calendar.startOfDay(for: now)
    }

    static func urgency(
        for expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ResetCreditExpirationUrgency {
        let today = calendar.startOfDay(for: now)
        let expirationDay = calendar.startOfDay(for: expirationDate)
        let days = calendar.dateComponents([.day], from: today, to: expirationDay).day ?? 0
        if days < 3 { return .critical }
        if days < 7 { return .warning }
        return .standard
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

enum ResetCreditExpirationUrgency: Equatable {
    case standard
    case warning
    case critical
}

enum QuotaRemainingUrgency: Equatable {
    case standard
    case warning
    case critical

    static func level(for percent: Double) -> QuotaRemainingUrgency {
        if percent < 10 { return .critical }
        if percent < 40 { return .warning }
        return .standard
    }
}

enum QuotaStatusPalette {
    static let healthy: Color = .green
    static let warning: Color = .orange
    static let critical: Color = .red

    static func color(for urgency: QuotaRemainingUrgency) -> Color {
        switch urgency {
        case .standard: return healthy
        case .warning: return warning
        case .critical: return critical
        }
    }

    static func color(for urgency: ResetCreditExpirationUrgency) -> Color {
        switch urgency {
        case .standard: return healthy
        case .warning: return warning
        case .critical: return critical
        }
    }
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
    static let horizontalPadding: CGFloat = 12
    static let contentSpacing: CGFloat = 16
    static let expirationHoverInset: CGFloat = 8
    static let metricSpacing: CGFloat = 28
    static let expirationTipWidth: CGFloat = 200
    static let resetTipWidth: CGFloat = 220
    static let resetTipSectionSpacing: CGFloat = 10
    static let resetTipItemSpacing: CGFloat = 8
}
