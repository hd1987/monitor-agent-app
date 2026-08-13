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
                        if let cardState = store.quotaCardState(for: provider) {
                            SubscriptionQuotaCard(
                                provider: provider,
                                snapshot: cardState.snapshot,
                                refreshPhase: store.quotaRefreshPhase(for: provider),
                                expirationDate: store.quotaExpirationDate(for: provider),
                                presentationDate: cardState.presentedAt,
                                tipOwnership: $tipOwnership
                            )
                        }
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
    @State private var tipHoverState = QuotaTipHoverState()
    @State private var cardWidth: CGFloat = 0
    @State private var tipAnchorX: CGFloat = 0
    let provider: QuotaProviderID
    let snapshot: QuotaSnapshot?
    let refreshPhase: QuotaRefreshPhase
    let expirationDate: Date?
    let presentationDate: Date
    @Binding var tipOwnership: QuotaTipOwnership

    var body: some View {
        let presentation = QuotaDetailsPresentation.make(
            provider: provider,
            snapshot: snapshot,
            refreshPhase: refreshPhase,
            expirationDate: expirationDate,
            now: presentationDate
        )

        HStack(spacing: 0) {
            header(subscriptionStatus: presentation.subscription?.status)
                .frame(maxHeight: .infinity, alignment: .leading)
            Spacer(minLength: QuotaCardLayout.contentSpacing)
            if let snapshot {
                snapshotContent(snapshot, presentation: presentation)
                    .frame(maxHeight: .infinity)
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
        .contentShape(Rectangle())
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { cardWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in cardWidth = newValue }
            }
        )
        .onChange(of: tipOwnership.owner) { _, owner in
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                if owner != tipOwner {
                    tipHoverState.reset()
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard presentation.hasContent else { return }
                if !tipOwnership.owns(tipOwner) {
                    tipAnchorX = location.x
                }
                withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                    tipOwnership.claim(tipOwner)
                    tipHoverState.triggerHoverChanged(true)
                }
            case .ended:
                tipHoverState.triggerHoverChanged(false)
                reconcileTipPresentation()
            }
        }
        .overlay(alignment: .bottomLeading) {
            if tipOwnership.owns(tipOwner),
               tipHoverState.isPresented,
               presentation.hasContent {
                QuotaHoverTip(
                    width: QuotaCardLayout.detailsTipWidth,
                    onHoverChanged: tipSurfaceHoverChanged
                ) {
                    QuotaDetailsTip(presentation: presentation)
                }
                .offset(x: clampedTipX, y: -QuotaCardLayout.cardHeight)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            }
        }
        .zIndex(tipOwnership.owner?.provider == provider ? 2 : 0)
    }

    private var clampedTipX: CGFloat {
        let maxX = max(0, cardWidth - QuotaCardLayout.detailsTipWidth)
        return min(max(0, tipAnchorX - QuotaCardLayout.detailsTipWidth / 2), maxX)
    }

    private var tipOwner: QuotaTipOwner {
        QuotaTipOwner(provider: provider)
    }

    private func tipSurfaceHoverChanged(_ hovering: Bool) {
        guard tipOwnership.owns(tipOwner) else { return }
        withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
            tipHoverState.surfaceHoverChanged(hovering)
        }
        if !hovering {
            reconcileTipPresentation()
        }
    }

    private func reconcileTipPresentation() {
        DispatchQueue.main.async {
            withAnimation(MainPanelMotion.presentation(reduceMotion: reduceMotion)) {
                tipHoverState.reconcilePresentation()
                if !tipHoverState.isPresented {
                    tipOwnership.release(tipOwner)
                }
            }
        }
    }

    private func header(subscriptionStatus: QuotaStatus?) -> some View {
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
                    .foregroundStyle(planColor(subscriptionStatus: subscriptionStatus))
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
    private func snapshotContent(
        _ snapshot: QuotaSnapshot,
        presentation: QuotaDetailsPresentation
    ) -> some View {
        switch snapshot.status {
        case .available:
            HStack(spacing: QuotaCardLayout.metricSpacing) {
                ForEach(Array(presentation.usageWindows.enumerated()), id: \.offset) { _, item in
                    quotaMetric(item)
                }
                if let resetCredits = presentation.resetCredits {
                    HStack(spacing: 5) {
                        Text("resets")
                            .fontWeight(.medium)
                            .foregroundStyle(theme.panelSecondaryForeground)
                        Text("·")
                            .foregroundStyle(theme.panelSecondaryForeground)
                        Text("\(resetCredits.count)")
                            .fontWeight(.semibold)
                            .foregroundStyle(resetCreditCountColor(status: resetCredits.status))
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

    private func quotaMetric(_ item: QuotaWindowPresentation) -> some View {
        HStack(spacing: 5) {
            Text(item.label)
                .fontWeight(.medium)
                .foregroundStyle(theme.panelSecondaryForeground)
            Text("·")
                .foregroundStyle(theme.panelSecondaryForeground)
            Text("\(Int(item.remainingPercent.rounded()))%")
                .fontWeight(.semibold)
                .foregroundStyle(quotaColor(item.remainingPercent))
            Text(item.countdownText)
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

    private func planColor(subscriptionStatus: QuotaStatus?) -> Color {
        switch subscriptionStatus {
        case .healthy, .unknown: return theme.panelSecondaryForeground
        case .warning: return QuotaStatusPalette.warning
        case .critical: return QuotaStatusPalette.critical
        case nil: return theme.panelSecondaryForeground
        }
    }

    private func resetCreditCountColor(status: QuotaStatus) -> Color {
        QuotaStatusPalette.color(
            for: status,
            unknown: theme.panelSecondaryForeground
        )
    }

}

struct QuotaTipOwner: Equatable {
    let provider: QuotaProviderID
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

struct QuotaWindowPresentation: Equatable {
    let label: String
    let remainingPercent: Double
    let countdownText: String
    let absoluteResetText: String
}

struct QuotaResetCreditPresentation: Equatable {
    let countdownText: String
    let absoluteExpirationText: String
    let status: QuotaStatus
}

struct QuotaResetCreditsPresentation: Equatable {
    let count: Int
    let items: [QuotaResetCreditPresentation]
    let status: QuotaStatus
}

struct QuotaSubscriptionPresentation: Equatable {
    let distanceText: String
    let expirationText: String
    let status: QuotaStatus
}

struct QuotaDetailsPresentation: Equatable {
    let usageWindows: [QuotaWindowPresentation]
    let resetCredits: QuotaResetCreditsPresentation?
    let subscription: QuotaSubscriptionPresentation?
    let refreshFailure: QuotaRefreshPresentation.Failure?

    var hasContent: Bool {
        !usageWindows.isEmpty
            || resetCredits != nil
            || subscription != nil
            || refreshFailure != nil
    }

    static func make(
        provider: QuotaProviderID,
        snapshot: QuotaSnapshot?,
        refreshPhase: QuotaRefreshPhase,
        expirationDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> QuotaDetailsPresentation {
        let isAvailable = snapshot?.status == .available
        var usageWindows: [QuotaWindowPresentation] = []

        if isAvailable, let window = snapshot?.fiveHour {
            usageWindows.append(windowPresentation(
                provider: provider,
                fallbackLabel: "5h",
                window: window,
                now: now
            ))
        }
        if isAvailable, let window = snapshot?.weekly {
            usageWindows.append(windowPresentation(
                provider: provider,
                fallbackLabel: "1w",
                window: window,
                now: now
            ))
        }
        if isAvailable, let window = snapshot?.opusWeekly {
            usageWindows.append(windowPresentation(
                provider: provider,
                fallbackLabel: "Opus",
                window: window,
                now: now,
                usesProviderDurationLabel: false
            ))
        }

        let resetCredits: QuotaResetCreditsPresentation?
        if isAvailable, let count = snapshot?.resetCredits, count > 0 {
            let expirations = snapshot?.resetCreditExpirations ?? []
            let items = (0..<count).map { index in
                guard expirations.indices.contains(index) else {
                    return QuotaResetCreditPresentation(
                        countdownText: ResetCreditsCopy.expirationUnavailable,
                        absoluteExpirationText: ResetCreditsCopy.expirationUnavailable,
                        status: .unknown
                    )
                }
                let expiration = expirations[index]
                return QuotaResetCreditPresentation(
                    countdownText: SubscriptionExpiration.distanceText(
                        to: expiration,
                        now: now,
                        calendar: calendar
                    ),
                    absoluteExpirationText: QuotaDateFormat.resetDateTime(expiration),
                    status: ResetCreditExpiration.status(
                        for: expiration,
                        now: now,
                        calendar: calendar
                    )
                )
            }
            resetCredits = QuotaResetCreditsPresentation(
                count: count,
                items: items,
                status: ResetCreditExpiration.status(
                    in: expirations,
                    after: now,
                    calendar: calendar
                )
            )
        } else {
            resetCredits = nil
        }

        let subscription = expirationDate.map {
            QuotaSubscriptionPresentation(
                distanceText: SubscriptionExpiration.distanceText(
                    to: $0,
                    now: now,
                    calendar: calendar
                ),
                expirationText: SubscriptionExpiration.dateText($0),
                status: SubscriptionExpiration.status(
                    for: $0,
                    now: now,
                    calendar: calendar
                )
            )
        }
        let refreshFailure = isAvailable
            ? QuotaRefreshPresentation.failure(for: refreshPhase)
            : nil

        return QuotaDetailsPresentation(
            usageWindows: usageWindows,
            resetCredits: resetCredits,
            subscription: subscription,
            refreshFailure: refreshFailure
        )
    }

    private static func windowPresentation(
        provider: QuotaProviderID,
        fallbackLabel: String,
        window: QuotaWindow,
        now: Date,
        usesProviderDurationLabel: Bool = true
    ) -> QuotaWindowPresentation {
        let label = provider == .codex && usesProviderDurationLabel
            ? window.displayLabel(fallback: fallbackLabel)
            : fallbackLabel
        return QuotaWindowPresentation(
            label: label,
            remainingPercent: window.remainingPercent,
            countdownText: QuotaResetCountdown.text(until: window.resetsAt, now: now),
            absoluteResetText: QuotaDateFormat.resetDateTime(window.resetsAt)
        )
    }
}

enum QuotaResetCountdown {
    static func text(until resetDate: Date?, now: Date) -> String {
        guard let resetDate else { return "--" }
        let remainingSeconds = resetDate.timeIntervalSince(now)
        guard remainingSeconds.isFinite else { return "--" }
        guard remainingSeconds > 0 else { return "Now" }

        let roundedMinutes = ceil(remainingSeconds / 60)
        guard roundedMinutes <= Double(Int.max) else { return "--" }
        let totalMinutes = max(1, Int(roundedMinutes))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct QuotaDetailsTip: View {
    @EnvironmentObject private var theme: ThemeManager
    let presentation: QuotaDetailsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: QuotaCardLayout.detailsTipSectionSpacing) {
            if !presentation.usageWindows.isEmpty {
                usageLimitsSection
            }
            if let resetCredits = presentation.resetCredits {
                if !presentation.usageWindows.isEmpty { sectionDivider }
                resetCreditsSection(resetCredits)
            }
            if let subscription = presentation.subscription {
                if !presentation.usageWindows.isEmpty || presentation.resetCredits != nil { sectionDivider }
                subscriptionSection(subscription)
            }
            if let failure = presentation.refreshFailure {
                if !presentation.usageWindows.isEmpty
                    || presentation.resetCredits != nil
                    || presentation.subscription != nil {
                    sectionDivider
                }
                failureSection(failure)
            }
        }
        .foregroundStyle(theme.tooltipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: QuotaCardLayout.detailsTipWidth)
        .mainPanelTooltipSurface()
    }

    private var usageLimitsSection: some View {
        VStack(alignment: .leading, spacing: QuotaCardLayout.detailsTipItemSpacing) {
            sectionHeader(QuotaDetailsCopy.usageLimitsTitle, trailing: QuotaDetailsCopy.resetsAtTitle)
            ForEach(Array(presentation.usageWindows.enumerated()), id: \.offset) { _, window in
                HStack(spacing: 8) {
                    Text("\(window.label) · \(window.countdownText)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                    Spacer(minLength: 12)
                    Text(window.absoluteResetText)
                        .font(.system(size: 10))
                }
            }
        }
    }

    private func resetCreditsSection(_ resetCredits: QuotaResetCreditsPresentation) -> some View {
        VStack(alignment: .leading, spacing: QuotaCardLayout.detailsTipItemSpacing) {
            sectionHeader(ResetCreditsCopy.title, trailing: ResetCreditsCopy.expiresTitle)
            ForEach(Array(resetCredits.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    statusDot(item.status)
                    Text(item.countdownText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                    Spacer(minLength: 12)
                    Text(item.absoluteExpirationText)
                        .font(.system(size: 10))
                }
            }
        }
    }

    private func subscriptionSection(_ subscription: QuotaSubscriptionPresentation) -> some View {
        VStack(alignment: .leading, spacing: QuotaCardLayout.detailsTipItemSpacing) {
            sectionHeader(
                SubscriptionExpirationCopy.subscriptionTitle,
                trailing: SubscriptionExpirationCopy.expiresTitle
            )
            HStack(spacing: 8) {
                statusDot(subscription.status)
                Text(subscription.distanceText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tooltipForeground.opacity(0.72))
                Spacer(minLength: 12)
                Text(subscription.expirationText)
                    .font(.system(size: 10))
            }
        }
    }

    private func failureSection(_ failure: QuotaRefreshPresentation.Failure) -> some View {
        HStack(spacing: 8) {
            statusDot(.critical)
            Text(failure.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tooltipForeground.opacity(0.72))
            Spacer(minLength: 8)
            Text(QuotaDateFormat.updateDateTime(failure.attemptedAt))
                .font(.system(size: 10))
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(trailing)
                .font(.system(size: 10))
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(theme.tooltipForeground.opacity(0.12))
    }

    private func statusDot(_ status: QuotaStatus) -> some View {
        Circle()
            .fill(QuotaStatusPalette.color(
                for: status,
                unknown: theme.tooltipForeground.opacity(0.72)
            ))
            .frame(width: 6, height: 6)
    }
}

enum QuotaDetailsCopy {
    static let usageLimitsTitle = "Usage limits"
    static let resetsAtTitle = "Resets at"
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
    static let metricSpacing: CGFloat = 28
    static let detailsTipWidth: CGFloat = 280
    static let detailsTipSectionSpacing: CGFloat = 10
    static let detailsTipItemSpacing: CGFloat = 8
    static let tipHoverBridgeHeight: CGFloat = 6
}
