import SwiftUI

struct SubscriptionQuotaView: View {
    @EnvironmentObject var store: AppStore
    @State private var tipOwnership = QuotaTipOwnership()

    private var providers: [QuotaProviderID] {
        store.visibleQuotaProviders
    }

    var body: some View {
        Group {
            if !providers.isEmpty {
                VStack(spacing: 8) {
                    ForEach(providers, id: \.self) { provider in
                        SubscriptionQuotaCard(
                            provider: provider,
                            snapshot: store.quotaSnapshots[provider],
                            refreshPhase: store.quotaRefreshPhase(for: provider),
                            expirationDate: store.quotaExpirationDate(for: provider),
                            tipOwnership: $tipOwnership
                        )
                    }
                }
                .padding(.horizontal, MainPanelDesign.horizontalPadding)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: providers) { _, providers in
            tipOwnership.retainProviders(providers)
        }
    }
}

struct SubscriptionQuotaCard: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expirationTipHoverState = QuotaTipHoverState()
    @State private var resetTipHoverState = QuotaTipHoverState()
    @State private var cardWidth: CGFloat = 0
    @State private var rightRegionWidth: CGFloat = 0
    @State private var resetTipAnchorX: CGFloat = 0
    let provider: QuotaProviderID
    let snapshot: QuotaSnapshot?
    let refreshPhase: QuotaRefreshPhase
    let expirationDate: Date?
    @Binding var tipOwnership: QuotaTipOwnership

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
                            tipOwnership.claim(expirationTipOwner)
                            expirationTipHoverState.triggerHoverChanged(true)
                        }
                    case .ended:
                        expirationTipHoverState.triggerHoverChanged(false)
                        reconcileExpirationTipPresentation()
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
                        switch phase {
                        case .active(let location):
                            guard hasResetCredits(snapshot) else { return }
                            if !tipOwnership.owns(resetTipOwner) {
                                resetTipAnchorX = resetRegionOriginX + location.x
                            }
                            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                                tipOwnership.claim(resetTipOwner)
                                resetTipHoverState.triggerHoverChanged(true)
                            }
                        case .ended:
                            resetTipHoverState.triggerHoverChanged(false)
                            reconcileResetTipPresentation()
                        }
                    }
                    .onChange(of: hasResetCredits(snapshot)) { _, hasResetCredits in
                        guard !hasResetCredits else { return }
                        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                            resetTipHoverState.reset()
                            tipOwnership.release(resetTipOwner)
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
        .onChange(of: tipOwnership.owner) { _, owner in
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                if owner != expirationTipOwner {
                    expirationTipHoverState.reset()
                }
                if owner != resetTipOwner {
                    resetTipHoverState.reset()
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if tipOwnership.owns(expirationTipOwner),
               expirationTipHoverState.isPresented,
               let expirationDate {
                QuotaHoverTip(
                    width: QuotaCardLayout.expirationTipWidth,
                    onHoverChanged: expirationTipSurfaceHoverChanged
                ) {
                    SubscriptionExpirationTip(
                        expirationDate: expirationDate,
                        quotaSnapshot: snapshot?.status == .available ? snapshot : nil,
                        refreshPhase: refreshPhase
                    )
                }
                .padding(.leading, 8)
                .offset(y: -QuotaCardLayout.cardHeight)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading))
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if tipOwnership.owns(resetTipOwner),
               resetTipHoverState.isPresented,
               let snapshot,
               let credits = snapshot.resetCredits,
               credits > 0 {
                QuotaHoverTip(
                    width: QuotaCardLayout.resetTipWidth,
                    onHoverChanged: resetTipSurfaceHoverChanged
                ) {
                    ResetCreditsTip(
                        count: credits,
                        expirations: snapshot.resetCreditExpirations
                    )
                }
                .offset(x: clampedResetTipX, y: -QuotaCardLayout.cardHeight)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            }
        }
        .zIndex(tipOwnership.owner?.provider == provider ? 2 : 0)
    }

    private var clampedResetTipX: CGFloat {
        let maxX = max(0, cardWidth - QuotaCardLayout.resetTipWidth)
        return min(max(0, resetTipAnchorX - QuotaCardLayout.resetTipWidth / 2), maxX)
    }

    private var resetRegionOriginX: CGFloat {
        max(0, cardWidth - QuotaCardLayout.horizontalPadding - rightRegionWidth)
    }

    private var expirationTipOwner: QuotaTipOwner {
        QuotaTipOwner(provider: provider, kind: .expiration)
    }

    private var resetTipOwner: QuotaTipOwner {
        QuotaTipOwner(provider: provider, kind: .resetCredits)
    }

    private func expirationTipSurfaceHoverChanged(_ hovering: Bool) {
        guard tipOwnership.owns(expirationTipOwner) else { return }
        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
            expirationTipHoverState.surfaceHoverChanged(hovering)
        }
        if !hovering {
            reconcileExpirationTipPresentation()
        }
    }

    private func resetTipSurfaceHoverChanged(_ hovering: Bool) {
        guard tipOwnership.owns(resetTipOwner) else { return }
        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
            resetTipHoverState.surfaceHoverChanged(hovering)
        }
        if !hovering {
            reconcileResetTipPresentation()
        }
    }

    private func reconcileExpirationTipPresentation() {
        DispatchQueue.main.async {
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                expirationTipHoverState.reconcilePresentation()
                if !expirationTipHoverState.isPresented {
                    tipOwnership.release(expirationTipOwner)
                }
            }
        }
    }

    private func reconcileResetTipPresentation() {
        DispatchQueue.main.async {
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                resetTipHoverState.reconcilePresentation()
                if !resetTipHoverState.isPresented {
                    tipOwnership.release(resetTipOwner)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            ProviderIcon(provider: provider)
                .overlay(alignment: .topTrailing) {
                    if let color = quotaStateDotColor {
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
            Text(provider.displayName)
                .fontWeight(.semibold)

            if let plan = snapshot?.plan, !plan.isEmpty, snapshot?.status == .available {
                Text("· \(plan)")
                    .foregroundStyle(planColor)
            }
        }
        .lineLimit(1)
        .layoutPriority(2)
        .help(quotaStateHelp)
        .accessibilityElement(children: .combine)
        .accessibilityValue(quotaStateHelp)
    }

    private var quotaStateDotColor: Color? {
        guard let status = QuotaRefreshPresentation.headerStatus(
            snapshotStatus: snapshot?.status,
            phase: refreshPhase
        ) else { return nil }
        return QuotaStatusPalette.color(for: status, unknown: .clear)
    }

    private var quotaStateHelp: String {
        guard let snapshot, snapshot.status == .available else {
            return provider.displayName
        }
        guard let failure = QuotaRefreshPresentation.failure(for: refreshPhase) else {
            return provider.displayName
        }
        return "\(failure.label) \(QuotaDateFormat.updateDateTime(failure.attemptedAt))"
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
        QuotaStatusPalette.color(
            for: QuotaRemaining.status(for: percent),
            unknown: theme.panelSecondaryForeground
        )
    }

    private var planColor: Color {
        guard let expirationDate else { return theme.panelSecondaryForeground }
        switch SubscriptionExpiration.status(for: expirationDate) {
        case .healthy, .unknown: return theme.panelSecondaryForeground
        case .warning: return QuotaStatusPalette.warning
        case .critical: return QuotaStatusPalette.critical
        }
    }

    private func hasResetCredits(_ snapshot: QuotaSnapshot) -> Bool {
        provider == .codex && (snapshot.resetCredits ?? 0) > 0
    }

    private func resetCreditCountColor(expirations: [Date]) -> Color {
        QuotaStatusPalette.color(
            for: ResetCreditExpiration.status(in: expirations),
            unknown: theme.panelSecondaryForeground
        )
    }

}

struct QuotaTipOwner: Equatable {
    enum Kind: Equatable {
        case expiration
        case resetCredits
    }

    let provider: QuotaProviderID
    let kind: Kind
}

struct QuotaTipOwnership: Equatable {
    private(set) var owner: QuotaTipOwner?

    mutating func claim(_ owner: QuotaTipOwner) {
        self.owner = owner
    }

    mutating func release(_ owner: QuotaTipOwner) {
        guard self.owner == owner else { return }
        self.owner = nil
    }

    mutating func retainProviders(_ providers: [QuotaProviderID]) {
        guard let owner, !providers.contains(owner.provider) else { return }
        self.owner = nil
    }

    func owns(_ owner: QuotaTipOwner) -> Bool {
        self.owner == owner
    }
}

struct QuotaTipHoverState: Equatable {
    private(set) var isTriggerHovered = false
    private(set) var isSurfaceHovered = false
    private(set) var isPresented = false

    mutating func triggerHoverChanged(_ hovering: Bool) {
        isTriggerHovered = hovering
        if hovering {
            isPresented = true
        }
    }

    mutating func surfaceHoverChanged(_ hovering: Bool) {
        isSurfaceHovered = hovering
        if hovering {
            isPresented = true
        }
    }

    mutating func reconcilePresentation() {
        isPresented = isTriggerHovered || isSurfaceHovered
    }

    mutating func reset() {
        isTriggerHovered = false
        isSurfaceHovered = false
        isPresented = false
    }
}

private struct QuotaHoverTip<Content: View>: View {
    let width: CGFloat
    let onHoverChanged: (Bool) -> Void
    private let content: Content

    init(
        width: CGFloat,
        onHoverChanged: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.onHoverChanged = onHoverChanged
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Color.clear
                .frame(
                    width: width,
                    height: QuotaCardLayout.tipHoverBridgeHeight
                )
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
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
    let quotaSnapshot: QuotaSnapshot?
    let refreshPhase: QuotaRefreshPhase

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
            if quotaSnapshot != nil,
               let failure = QuotaRefreshPresentation.failure(for: refreshPhase) {
                Divider()
                    .overlay(theme.tooltipForeground.opacity(0.12))
                HStack(spacing: 8) {
                    Circle()
                        .fill(QuotaStatusPalette.critical)
                        .frame(width: 6, height: 6)
                    Text(failure.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                    Spacer(minLength: 8)
                    Text(QuotaDateFormat.updateDateTime(failure.attemptedAt))
                        .font(.system(size: 10))
                }
            }
        }
        .foregroundStyle(theme.tooltipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: QuotaCardLayout.expirationTipWidth)
        .mainPanelTooltipSurface()
    }

    private var statusColor: Color {
        QuotaStatusPalette.color(
            for: SubscriptionExpiration.status(for: expirationDate),
            unknown: theme.tooltipForeground.opacity(0.72)
        )
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
        .mainPanelTooltipSurface()
        .contentShape(Rectangle())
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
        guard expirations.indices.contains(index) else {
            return QuotaStatusPalette.color(
                for: .unknown,
                unknown: theme.tooltipForeground.opacity(0.72)
            )
        }
        return QuotaStatusPalette.color(
            for: ResetCreditExpiration.status(for: expirations[index]),
            unknown: theme.tooltipForeground.opacity(0.72)
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

    static func status(
        for expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QuotaStatus {
        QuotaExpiration.status(for: expirationDate, now: now, calendar: calendar)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

enum QuotaStatus: Equatable {
    case healthy
    case warning
    case critical
    case unknown
}

enum QuotaRemaining {
    static func status(for percent: Double) -> QuotaStatus {
        if percent <= 10 { return .critical }
        if percent <= 40 { return .warning }
        return .healthy
    }
}

enum QuotaExpiration {
    static func status(
        for expiration: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QuotaStatus {
        let today = calendar.startOfDay(for: now)
        let expirationDay = calendar.startOfDay(for: expiration)
        let days = calendar.dateComponents([.day], from: today, to: expirationDay).day ?? 0
        if days <= 3 { return .critical }
        if days <= 7 { return .warning }
        return .healthy
    }
}

enum QuotaStatusPalette {
    static let healthy = StatusPalette.success
    static let warning = StatusPalette.warning
    static let critical = StatusPalette.error

    static func color(for status: QuotaStatus, unknown: Color) -> Color {
        switch status {
        case .healthy: return healthy
        case .warning: return warning
        case .critical: return critical
        case .unknown: return unknown
        }
    }
}

enum QuotaRefreshPresentation {
    struct Failure: Equatable {
        let label: String
        let attemptedAt: Date
    }

    static func headerStatus(
        snapshotStatus: QuotaSnapshotStatus?,
        phase: QuotaRefreshPhase
    ) -> QuotaStatus? {
        guard snapshotStatus == .available else { return nil }
        if case .failed = phase { return .critical }
        return nil
    }

    static func failure(for phase: QuotaRefreshPhase) -> Failure? {
        guard case .failed(let status, let attemptedAt) = phase else { return nil }
        return Failure(
            label: status == .authenticationExpired ? "Sign-in expired" : "Refresh failed",
            attemptedAt: attemptedAt
        )
    }
}

enum ResetCreditExpiration {
    static func next(in expirations: [Date], after now: Date = Date()) -> Date? {
        expirations.filter { $0 > now }.min()
    }

    static func status(
        in expirations: [Date],
        after now: Date = Date(),
        calendar: Calendar = .current
    ) -> QuotaStatus {
        guard let expiration = next(in: expirations, after: now) else { return .unknown }
        return status(for: expiration, now: now, calendar: calendar)
    }

    static func status(
        for expiration: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QuotaStatus {
        QuotaExpiration.status(for: expiration, now: now, calendar: calendar)
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
    static let tipHoverBridgeHeight: CGFloat = 6
}
