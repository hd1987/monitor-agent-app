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
                    if let status = quotaStateDotStatus {
                        QuotaStatusDot(
                            status: status,
                            diameter: 4,
                            unknownColor: .clear
                        )
                            .offset(x: 2, y: -2)
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

    private var quotaStateDotStatus: QuotaStatus? {
        QuotaRefreshPresentation.headerStatus(
            snapshotStatus: snapshot?.status,
            phase: refreshPhase
        )
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
                        Text(ResetCreditsCopy.cardTitle)
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
            Text(item.remainingPercentText)
                .fontWeight(.semibold)
                .foregroundStyle(quotaColor(item.remainingPercent))
            Text(item.countdownText)
                .font(.system(size: 11))
                .foregroundStyle(quotaStatusColor(item.status))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityValue(QuotaAccessibility.resetStatus(for: item.status))
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
        quotaStatusColor(QuotaRemaining.status(for: percent))
    }

    private func quotaStatusColor(_ status: QuotaStatus) -> Color {
        QuotaStatusPalette.color(for: status, unknown: theme.panelSecondaryForeground)
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
    let status: QuotaStatus

    var remainingPercentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    var detailsItemText: String {
        "\(label) • \(remainingPercentText)"
    }

    var accessibilityItemText: String {
        "\(label) limit, \(remainingPercentText) remaining"
    }
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
        !sections.isEmpty
    }

    var sections: [QuotaDetailsSection] {
        var sections: [QuotaDetailsSection] = []
        if !usageWindows.isEmpty { sections.append(.usageLimits) }
        if resetCredits != nil { sections.append(.resetCredits) }
        if subscription != nil { sections.append(.subscription) }
        if refreshFailure != nil { sections.append(.refreshFailure) }
        return sections
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
                    countdownText: QuotaExpirationCountdown.text(
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
                distanceText: QuotaExpirationCountdown.text(
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
            absoluteResetText: QuotaDateFormat.resetDateTime(window.resetsAt),
            status: QuotaWindowResetStatus.status(
                for: window,
                fallbackLabel: fallbackLabel,
                now: now
            )
        )
    }
}

enum QuotaDetailsSection: Equatable {
    case usageLimits
    case resetCredits
    case subscription
    case refreshFailure
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

struct QuotaDetailsTip: View {
    @EnvironmentObject private var theme: ThemeManager
    let presentation: QuotaDetailsPresentation

    var body: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: QuotaCardLayout.detailsTipColumnSpacing,
            verticalSpacing: QuotaCardLayout.detailsTipItemSpacing
        ) {
            QuotaDetailHeaderRow(
                primaryText: QuotaDetailsCopy.itemTitle,
                secondaryText: QuotaDetailsCopy.remainingTitle,
                tertiaryText: QuotaDetailsCopy.dateTitle
            )
            ForEach(Array(presentation.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { sectionDivider }
                sectionRows(section)
            }
        }
        .foregroundStyle(theme.tooltipForeground)
        .padding(.horizontal, QuotaCardLayout.detailsTipHorizontalPadding)
        .padding(.vertical, 9)
        .frame(width: QuotaCardLayout.detailsTipWidth)
        .mainPanelTooltipSurface()
    }

    @ViewBuilder
    private var usageLimitRows: some View {
        ForEach(Array(presentation.usageWindows.enumerated()), id: \.offset) { _, window in
            QuotaDetailRow(
                status: window.status,
                primaryText: window.detailsItemText,
                secondaryText: window.countdownText,
                tertiaryText: window.absoluteResetText,
                accessibilityPrimaryText: window.accessibilityItemText
            )
        }
    }

    @ViewBuilder
    private func resetCreditsRows(_ resetCredits: QuotaResetCreditsPresentation) -> some View {
        ForEach(Array(resetCredits.items.enumerated()), id: \.offset) { index, item in
            QuotaDetailRow(
                status: item.status,
                primaryText: ResetCreditsCopy.itemTitle(number: index + 1),
                secondaryText: item.countdownText,
                tertiaryText: item.absoluteExpirationText,
                accessibilityPrimaryText: ResetCreditsCopy.accessibilityItemTitle(number: index + 1)
            )
        }
    }

    @ViewBuilder
    private func subscriptionRows(_ subscription: QuotaSubscriptionPresentation) -> some View {
        QuotaDetailRow(
            status: subscription.status,
            primaryText: SubscriptionExpirationCopy.subscriptionTitle,
            secondaryText: subscription.distanceText,
            tertiaryText: subscription.expirationText
        )
    }

    @ViewBuilder
    private func sectionRows(_ section: QuotaDetailsSection) -> some View {
        switch section {
        case .usageLimits:
            usageLimitRows
        case .resetCredits:
            if let resetCredits = presentation.resetCredits {
                resetCreditsRows(resetCredits)
            }
        case .subscription:
            if let subscription = presentation.subscription {
                subscriptionRows(subscription)
            }
        case .refreshFailure:
            if let failure = presentation.refreshFailure {
                QuotaDetailRow(
                    status: .critical,
                    primaryText: failure.label,
                    secondaryText: "",
                    tertiaryText: QuotaDateFormat.updateDateTime(failure.attemptedAt)
                )
            }
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(theme.tooltipForeground.opacity(0.12))
            .gridCellColumns(3)
            .padding(.vertical, max(
                0,
                (QuotaCardLayout.detailsTipSectionSpacing
                    - QuotaCardLayout.detailsTipItemSpacing) / 2
            ))
    }
}

private struct QuotaDetailHeaderRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let primaryText: String
    let secondaryText: String
    let tertiaryText: String

    var body: some View {
        GridRow {
            Text(primaryText)
                .font(.system(size: 10, weight: .medium))
                .frame(
                    width: QuotaCardLayout.detailsTipPrimaryColumnWidth,
                    alignment: .leading
                )
            Text(secondaryText)
                .font(.system(size: 10))
                .frame(
                    width: QuotaCardLayout.detailsTipSecondaryColumnWidth,
                    alignment: .leading
                )
            Text(tertiaryText)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .foregroundStyle(theme.tooltipForeground.opacity(0.62))
    }
}

private struct QuotaDetailRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let status: QuotaStatus
    let primaryText: String
    let secondaryText: String
    let tertiaryText: String
    var accessibilityPrimaryText: String? = nil

    var body: some View {
        GridRow {
            HStack(spacing: 8) {
                QuotaStatusDot(
                    status: status,
                    diameter: 6,
                    unknownColor: theme.tooltipForeground.opacity(0.72)
                )
                Text(primaryText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tooltipForeground.opacity(0.72))
            }
            .frame(
                width: QuotaCardLayout.detailsTipPrimaryColumnWidth,
                alignment: .leading
            )
            Text(secondaryText)
                .font(.system(size: 10, weight: .medium))
                .frame(
                    width: QuotaCardLayout.detailsTipSecondaryColumnWidth,
                    alignment: .leading
                )
            Text(tertiaryText)
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([accessibilityPrimaryText ?? primaryText, secondaryText, tertiaryText]
            .filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityValue("\(status.accessibilityLabel) status")
    }
}

private struct QuotaStatusDot: View {
    let status: QuotaStatus
    let diameter: CGFloat
    let unknownColor: Color

    var body: some View {
        Circle()
            .fill(QuotaStatusPalette.color(for: status, unknown: unknownColor))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

enum QuotaDetailsCopy {
    static let itemTitle = "Item"
    static let remainingTitle = "Remaining"
    static let dateTitle = "Date"
}

enum ResetCreditsCopy {
    static let cardTitle = "Resets"
    static let expirationUnavailable = "Expiration unavailable"

    static func itemTitle(number: Int) -> String {
        "Reset \(number)"
    }

    static func accessibilityItemTitle(number: Int) -> String {
        "Reset credit \(number)"
    }
}

enum SubscriptionExpirationCopy {
    static let subscriptionTitle = "Subscription"
}

enum QuotaExpirationCountdown {
    static func text(
        to expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let expirationDay = calendar.startOfDay(for: expirationDate)
        let days = calendar.dateComponents([.day], from: today, to: expirationDay).day ?? 0
        if days > 0 { return "\(days)d" }
        if days < 0 { return "Expired \(abs(days))d" }
        return "Today"
    }
}

enum SubscriptionExpiration {
    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
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

    var accessibilityLabel: String {
        switch self {
        case .healthy: return "Healthy"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

enum QuotaAccessibility {
    static func resetStatus(for status: QuotaStatus) -> String {
        "\(status.accessibilityLabel) reset status"
    }
}

enum QuotaRemaining {
    static func status(for percent: Double) -> QuotaStatus {
        if percent <= 10 { return .critical }
        if percent <= 40 { return .warning }
        return .healthy
    }
}

enum QuotaWindowResetStatus {
    private static let shortCriticalThreshold: TimeInterval = 60 * 60
    private static let shortWarningThreshold: TimeInterval = 3 * 60 * 60
    private static let weeklyCriticalThreshold: TimeInterval = 24 * 60 * 60
    private static let weeklyWarningThreshold: TimeInterval = 3 * 24 * 60 * 60

    static func status(
        for window: QuotaWindow,
        fallbackLabel: String,
        now: Date
    ) -> QuotaStatus {
        guard let resetsAt = window.resetsAt else { return .unknown }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return .unknown }

        let usesWeeklyThresholds = window.usesDateTimeReset
            || fallbackLabel == "1w"
            || fallbackLabel == "Opus"
        let criticalThreshold = usesWeeklyThresholds
            ? weeklyCriticalThreshold
            : shortCriticalThreshold
        let warningThreshold = usesWeeklyThresholds
            ? weeklyWarningThreshold
            : shortWarningThreshold

        if remaining <= criticalThreshold { return .critical }
        if remaining <= warningThreshold { return .warning }
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
    static let detailsTipWidth: CGFloat = 320
    static let detailsTipHorizontalPadding: CGFloat = 10
    static let detailsTipPrimaryColumnWidth: CGFloat = 112
    static let detailsTipSecondaryColumnWidth: CGFloat = 58
    static let detailsTipColumnSpacing: CGFloat = 8
    static let detailsTipSectionSpacing: CGFloat = 10
    static let detailsTipItemSpacing: CGFloat = 8
    static let tipHoverBridgeHeight: CGFloat = 6
}
