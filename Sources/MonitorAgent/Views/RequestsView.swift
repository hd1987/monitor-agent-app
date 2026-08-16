import Foundation
import SwiftUI

enum RequestDetailTotalUsageResolver {
    static func totalUsageMicros(
        database: DatabaseManager,
        provider: AppFilter,
        range: TimeRange,
        enabledAgents: Set<AgentID>,
        accountIdentity: String?,
        now: Date = Date()
    ) -> Int64? {
        guard enabledAgents.contains(.cursor),
              provider == .all || provider == .cursor,
              let accountIdentity,
              let token = database.cursorDataPresentationToken(matching: accountIdentity),
              let totalCents = database.fetchCursorSpendSnapshot(
                  accountIdentity: accountIdentity,
                  range: CursorSpendRange(timeRange: range, now: now)
              )?.totalCents,
              database.isCursorDataPresentationTokenCurrent(token) else {
            return nil
        }
        let result = Int64(totalCents).multipliedReportingOverflow(by: 10_000)
        return result.overflow ? nil : result.partialValue
    }
}

final class RequestsViewModel: ObservableObject {
    static let pageSize = 100

    @Published private(set) var provider: AppFilter
    @Published private(set) var timeRange: TimeRange
    @Published private(set) var enabledAgents: Set<AgentID>
    @Published private(set) var cursorSpendAccountIdentity: String?
    @Published private(set) var items: [RequestLogItem] = []
    @Published private(set) var summary = RequestLogSummary()
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false

    private let database: DatabaseManager
    private let queryQueue = DispatchQueue(
        label: "com.hd1987.monitor-agent.requests-query",
        qos: .userInitiated
    )
    private var nextCursor: RequestPageCursor?
    private var generation = 0

    init(
        database: DatabaseManager = .shared,
        provider: AppFilter,
        timeRange: TimeRange,
        enabledAgents: Set<AgentID>,
        cursorSpendAccountIdentity: String?
    ) {
        self.database = database
        self.provider = provider
        self.timeRange = timeRange
        self.enabledAgents = enabledAgents
        self.cursorSpendAccountIdentity = cursorSpendAccountIdentity
    }

    var availableProviders: [AppFilter] {
        AppFilter.available(for: enabledAgents)
    }

    func reset(
        provider: AppFilter,
        timeRange: TimeRange,
        enabledAgents: Set<AgentID>,
        cursorSpendAccountIdentity: String?
    ) {
        self.enabledAgents = enabledAgents
        self.provider = AppFilter.available(for: enabledAgents).contains(provider) ? provider : .all
        self.timeRange = timeRange
        self.cursorSpendAccountIdentity = cursorSpendAccountIdentity
        reload()
    }

    func setProvider(_ provider: AppFilter) {
        guard availableProviders.contains(provider), self.provider != provider else { return }
        self.provider = provider
        reload()
    }

    func setTimeRange(_ timeRange: TimeRange) {
        guard self.timeRange != timeRange else { return }
        self.timeRange = timeRange
        reload()
    }

    func updateEnabledAgents(_ enabledAgents: Set<AgentID>) {
        guard self.enabledAgents != enabledAgents else { return }
        self.enabledAgents = enabledAgents
        if !availableProviders.contains(provider) {
            provider = .all
        }
        reload()
    }

    @discardableResult
    func updateCursorSpendAccountIdentity(_ accountIdentity: String?) -> Bool {
        guard cursorSpendAccountIdentity != accountIdentity else { return false }
        cursorSpendAccountIdentity = accountIdentity
        return true
    }

    func reload() {
        generation += 1
        let currentGeneration = generation
        let provider = provider
        let timeRange = timeRange
        let enabledAgents = enabledAgents
        let cursorSpendAccountIdentity = cursorSpendAccountIdentity
        nextCursor = nil
        items = []
        summary = RequestLogSummary()
        isLoading = true
        isLoadingMore = false

        queryQueue.async { [weak self, database] in
            var summary = database.fetchRequestLogSummary(
                app: provider,
                range: timeRange,
                enabledAgents: enabledAgents
            )
            summary.totalUsageMicros = RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: provider,
                range: timeRange,
                enabledAgents: enabledAgents,
                accountIdentity: cursorSpendAccountIdentity
            )
            let page = database.fetchRequestLogPage(
                app: provider,
                range: timeRange,
                enabledAgents: enabledAgents,
                limit: Self.pageSize
            )
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.summary = summary
                self.items = page.items
                self.nextCursor = page.nextCursor
                self.isLoading = false
            }
        }
    }

    func loadMoreIfNeeded(after item: RequestLogItem) {
        guard item.id == items.last?.id,
              !isLoading,
              !isLoadingMore,
              let cursor = nextCursor else { return }
        isLoadingMore = true
        let currentGeneration = generation
        let provider = provider
        let timeRange = timeRange
        let enabledAgents = enabledAgents

        queryQueue.async { [weak self, database] in
            let page = database.fetchRequestLogPage(
                app: provider,
                range: timeRange,
                enabledAgents: enabledAgents,
                after: cursor,
                limit: Self.pageSize
            )
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.items.append(contentsOf: page.items)
                self.nextCursor = page.nextCursor
                self.isLoadingMore = false
            }
        }
    }
}

struct RequestsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var model: RequestsViewModel

    @State private var isDatePopoverPresented = false
    @State private var activeStatCardTip: StatCardTip?

    var body: some View {
        VStack(spacing: 12) {
            header
            summary
            requestTable
                .allowsHitTesting(activeStatCardTip == nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(minWidth: 860, minHeight: 520)
        .utilityWindowBackground()
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            if model.items.isEmpty, !model.isLoading {
                model.reload()
            }
        }
        .onChange(of: store.enabledAgents) { _, enabledAgents in
            model.updateEnabledAgents(enabledAgents)
        }
        .onChange(of: store.isRefreshInProgress) { wasRefreshing, isRefreshing in
            if wasRefreshing, !isRefreshing {
                model.updateCursorSpendAccountIdentity(
                    store.cursorSpendPresentationAccountIdentity
                )
                model.reload()
            }
        }
        .onChange(of: store.cursorAccountPresentationState) { _, _ in
            if model.updateCursorSpendAccountIdentity(
                store.cursorSpendPresentationAccountIdentity
            ) {
                model.reload()
            }
        }
        .onChange(of: store.isRebuildingUsageData) { _, _ in
            if model.updateCursorSpendAccountIdentity(
                store.cursorSpendPresentationAccountIdentity
            ) {
                model.reload()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderFilterControl(
                filters: model.availableProviders,
                selection: model.provider,
                style: .labeledSegments(width: 400),
                cursorFailureHelp: nil,
                onSelect: model.setProvider
            )

            Spacer()

            UnifiedRefreshButton()

            TimeRangeControl(
                timeRange: model.timeRange,
                style: .utilityWindow,
                onSelect: model.setTimeRange,
                isPopoverPresented: $isDatePopoverPresented
            )
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            StatCard(
                title: "Requests",
                value: formatCount(model.summary.totalRequests),
                presentation: .detailSummary
            )
            summaryDivider
            StatCard(
                title: "Sessions",
                value: formatCount(model.summary.totalSessions),
                presentation: .detailSummary
            )
            summaryDivider
            TokenSummaryCard(
                stats: summaryStats,
                isAvailable: true,
                activeTip: $activeStatCardTip,
                presentation: .detailSummary
            )
            summaryDivider
            CacheHitCard(
                stats: summaryStats,
                isAvailable: true,
                presentation: .detailSummary
            )
            summaryDivider
            StatCard(
                title: "Total Usage",
                value: formatCurrencyMicros(model.summary.totalUsageMicros, compactZero: true),
                presentation: .detailSummary
            )
        }
        .background {
            RoundedRectangle(cornerRadius: UtilityWindowDesign.cornerRadius, style: .continuous)
                .fill(UtilityWindowDesign.groupedSurfaceFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: UtilityWindowDesign.cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 0.5)
        }
        .zIndex(StatCardTipLayer.zIndex(for: activeStatCardTip))
    }

    private var summaryDivider: some View {
        Divider()
            .frame(height: 34)
    }

    private var summaryStats: UsageStats {
        UsageStats(
            totalRequests: model.summary.totalRequests,
            totalSessions: model.summary.totalSessions,
            inputTokens: model.summary.inputTokens,
            outputTokens: model.summary.outputTokens,
            cacheReadTokens: model.summary.cacheReadTokens,
            cacheCreationTokens: model.summary.cacheCreationTokens
        )
    }

    private var requestTable: some View {
        GeometryReader { proxy in
            let columns = RequestListColumns(
                totalWidth: max(0, proxy.size.width - RequestListLayout.horizontalInsets)
            )

            VStack(spacing: 0) {
                requestListHeader(columns: columns)
                    .padding(.leading, RequestListLayout.contentInset)
                    .padding(.trailing, RequestListLayout.trailingInset)
                    .frame(height: 36)

                Divider()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            requestListRow(item, index: index, columns: columns)
                                .padding(.leading, RequestListLayout.contentInset)
                                .padding(.trailing, RequestListLayout.trailingInset)
                                .onAppear { model.loadMoreIfNeeded(after: item) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Requests",
                    systemImage: "tray",
                    description: Text("No request data matches these filters.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if model.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .utilityWindowGroupedSurface()
    }

    private func requestListHeader(columns: RequestListColumns) -> some View {
        HStack(spacing: 0) {
            requestListHeaderText("Date", width: columns.date, alignment: .leading)
            requestListHeaderText("Provider", width: columns.provider, alignment: .leading)
            requestListHeaderText("Model", width: columns.model, alignment: .leading)
            requestListHeaderText("Tokens", width: columns.tokens, alignment: .trailing)
            requestListHeaderText("Cost", width: columns.cost, alignment: .trailing)
        }
        .font(.system(size: 12))
    }

    private func requestListHeaderText(
        _ title: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func requestListRow(
        _ item: RequestLogItem,
        index: Int,
        columns: RequestListColumns
    ) -> some View {
        HStack(spacing: 0) {
            Text(Self.dateFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(item.createdAt))
            ))
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: columns.date, alignment: .leading)

            HStack(spacing: 7) {
                AppIconView(icon: item.provider.appFilter.appIcon)
                Text(item.provider.displayName)
                    .lineLimit(1)
            }
            .frame(width: columns.provider, alignment: .leading)

            Text(item.model)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columns.model, alignment: .leading)
                .help(item.model)

            Text(item.isFreeCursorRequest ? "—" : formatTokenDetail(item.totalTokens))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columns.tokens, alignment: .trailing)

            requestCost(item)
                .frame(width: columns.cost, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 7)
        .background {
            if index.isMultiple(of: 2) == false {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
            }
        }
    }

    @ViewBuilder
    private func requestCost(_ item: RequestLogItem) -> some View {
        if item.isFreeCursorRequest {
            Text("Free")
        } else {
            HStack(spacing: 6) {
                Text(formatCurrencyMicros(item.chargedCostMicros))
                    .monospacedDigit()
                if item.chargedCostMicros != nil,
                   let discountPercent = item.discountPercent,
                   discountPercent > 0 {
                    Text("\(discountPercent)% off")
                        .foregroundStyle(theme.panelTertiaryForeground)
                }
            }
            .lineLimit(1)
        }
    }

    private func formatCurrencyMicros(_ micros: Int64?, compactZero: Bool = false) -> String {
        guard let micros else { return "—" }
        if compactZero, micros == 0 { return "$0" }
        let dollars = Double(micros) / 1_000_000
        let decimals = dollars > 0 && dollars < 0.01 ? 4 : 2
        return String(format: "$%.*f", decimals, dollars)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter
    }()

}

enum RequestListLayout {
    static let contentInset: CGFloat = 8
    static let scrollbarReservation = NSScroller.scrollerWidth(
        for: .regular,
        scrollerStyle: .overlay
    ) + 4
    static let trailingInset = contentInset + scrollbarReservation
    static let horizontalInsets = contentInset + trailingInset
}

struct RequestListColumns {
    let date: CGFloat
    let provider: CGFloat
    let model: CGFloat
    let tokens: CGFloat
    let cost: CGFloat

    init(totalWidth: CGFloat) {
        date = totalWidth * 0.20
        provider = totalWidth * 0.17
        model = totalWidth * 0.29
        tokens = totalWidth * 0.14
        cost = totalWidth * 0.20
    }
}
