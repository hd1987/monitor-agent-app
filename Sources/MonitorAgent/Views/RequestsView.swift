import Foundation
import SwiftUI

struct RequestPresentationContext: Equatable {
    let enabledAgents: Set<AgentID>
    let cursorDataPresentationToken: CursorDataPresentationToken?
    let cursorSpendAccountIdentity: String?

    @discardableResult
    func performIfCurrent(
        in database: DatabaseManager,
        operation: () -> Void
    ) -> Bool {
        guard let cursorDataPresentationToken else {
            operation()
            return true
        }
        return database.performIfCursorDataPresentationTokenCurrent(
            cursorDataPresentationToken,
            operation: operation
        )
    }
}

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

final class RequestQueryCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class LatestRequestQueryScheduler {
    typealias Operation = (RequestQueryCancellation) -> Void

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var currentCancellation: RequestQueryCancellation?

    init(
        label: String = "com.hd1987.monitor-agent.requests-query",
        qos: DispatchQoS = .userInitiated
    ) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func submit(_ operation: @escaping Operation) {
        let cancellation = RequestQueryCancellation()
        lock.lock()
        currentCancellation?.cancel()
        currentCancellation = cancellation
        lock.unlock()

        queue.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            operation(cancellation)
            self?.finish(cancellation)
        }
    }

    func cancel() {
        lock.lock()
        currentCancellation?.cancel()
        currentCancellation = nil
        lock.unlock()
    }

    private func finish(_ cancellation: RequestQueryCancellation) {
        lock.lock()
        if currentCancellation === cancellation {
            currentCancellation = nil
        }
        lock.unlock()
    }
}

final class RequestsViewModel: ObservableObject {
    static let pageSize = 100

    @Published private(set) var provider: AppFilter
    @Published private(set) var timeRange: TimeRange
    @Published private(set) var enabledAgents: Set<AgentID>
    @Published private(set) var items: [RequestLogItem] = []
    @Published private(set) var summary = RequestLogSummary()
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false

    private let database: DatabaseManager
    private let queryScheduler = LatestRequestQueryScheduler()
    private var presentationContext: RequestPresentationContext
    private var nextCursor: RequestPageCursor?
    private var generation = 0

    init(
        database: DatabaseManager = .shared,
        provider: AppFilter,
        timeRange: TimeRange,
        enabledAgents: Set<AgentID>,
        presentationContext: RequestPresentationContext
    ) {
        self.database = database
        self.provider = provider
        self.timeRange = timeRange
        self.enabledAgents = enabledAgents
        self.presentationContext = presentationContext
    }

    deinit {
        queryScheduler.cancel()
    }

    var availableProviders: [AppFilter] {
        AppFilter.available(for: enabledAgents)
    }

    var isSummaryAvailable: Bool {
        provider != .cursor || presentationContext.enabledAgents.contains(.cursor)
    }

    func reset(
        provider: AppFilter,
        timeRange: TimeRange,
        enabledAgents: Set<AgentID>,
        presentationContext: RequestPresentationContext
    ) {
        self.enabledAgents = enabledAgents
        self.provider = AppFilter.available(for: enabledAgents).contains(provider) ? provider : .all
        self.timeRange = timeRange
        self.presentationContext = presentationContext
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

    func updateEnabledAgents(
        _ enabledAgents: Set<AgentID>,
        presentationContext: RequestPresentationContext
    ) {
        guard self.enabledAgents != enabledAgents
                || self.presentationContext != presentationContext else { return }
        self.enabledAgents = enabledAgents
        self.presentationContext = presentationContext
        if !availableProviders.contains(provider) {
            provider = .all
        }
        reload()
    }

    @discardableResult
    func updatePresentationContext(_ presentationContext: RequestPresentationContext) -> Bool {
        guard self.presentationContext != presentationContext else { return false }
        self.presentationContext = presentationContext
        return true
    }

    func reload() {
        generation += 1
        let currentGeneration = generation
        let provider = provider
        let timeRange = timeRange
        let presentationContext = presentationContext
        nextCursor = nil
        items = []
        summary = RequestLogSummary()
        isLoading = true
        isLoadingMore = false

        queryScheduler.submit { [weak self, database] cancellation in
            var summary = database.fetchRequestLogSummary(
                app: provider,
                range: timeRange,
                enabledAgents: presentationContext.enabledAgents
            )
            guard !cancellation.isCancelled else { return }
            summary.totalUsageMicros = RequestDetailTotalUsageResolver.totalUsageMicros(
                database: database,
                provider: provider,
                range: timeRange,
                enabledAgents: presentationContext.enabledAgents,
                accountIdentity: presentationContext.cursorSpendAccountIdentity
            )
            guard !cancellation.isCancelled else { return }
            let page = database.fetchRequestLogPage(
                app: provider,
                range: timeRange,
                enabledAgents: presentationContext.enabledAgents,
                limit: Self.pageSize
            )
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                presentationContext.performIfCurrent(in: database) {
                    self.summary = summary
                    self.items = page.items
                    self.nextCursor = page.nextCursor
                    self.isLoading = false
                }
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
        let presentationContext = presentationContext

        queryScheduler.submit { [weak self, database] cancellation in
            let page = database.fetchRequestLogPage(
                app: provider,
                range: timeRange,
                enabledAgents: presentationContext.enabledAgents,
                after: cursor,
                limit: Self.pageSize
            )
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                presentationContext.performIfCurrent(in: database) {
                    self.items.append(contentsOf: page.items)
                    self.nextCursor = page.nextCursor
                    self.isLoadingMore = false
                }
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
            model.updateEnabledAgents(
                enabledAgents,
                presentationContext: store.requestPresentationContext
            )
        }
        .onChange(of: store.isRefreshInProgress) { wasRefreshing, isRefreshing in
            if wasRefreshing, !isRefreshing {
                model.updatePresentationContext(store.requestPresentationContext)
                model.reload()
            }
        }
        .onChange(of: store.cursorAccountPresentationState) { _, _ in
            if model.updatePresentationContext(store.requestPresentationContext) {
                model.reload()
            }
        }
        .onChange(of: store.isRebuildingUsageData) { _, _ in
            if model.updatePresentationContext(store.requestPresentationContext) {
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
                value: model.isSummaryAvailable ? formatCount(model.summary.totalRequests) : "—",
                presentation: .detailSummary
            )
            summaryDivider
            StatCard(
                title: "Sessions",
                value: model.isSummaryAvailable ? formatCount(model.summary.totalSessions) : "—",
                presentation: .detailSummary
            )
            summaryDivider
            TokenSummaryCard(
                stats: summaryStats,
                isAvailable: model.isSummaryAvailable,
                activeTip: $activeStatCardTip,
                presentation: .detailSummary
            )
            summaryDivider
            CacheHitCard(
                stats: summaryStats,
                isAvailable: model.isSummaryAvailable,
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
