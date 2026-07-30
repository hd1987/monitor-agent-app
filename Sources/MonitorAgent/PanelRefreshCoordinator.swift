import Foundation

final class PanelRefreshCoordinator {
    typealias RefreshAction = (@escaping () -> Void) -> Void

    private let queue: DispatchQueue
    private let currentDateProvider: () -> Date
    private var timer: DispatchSourceTimer?
    private var refreshAction: RefreshAction?
    private var isRefreshInFlight = false
    private var isRefreshPending = false
    private var lastRefreshStartedAt: Date?
    private(set) var isRunning = false

    init(
        queue: DispatchQueue = .main,
        currentDateProvider: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.currentDateProvider = currentDateProvider
    }

    func start(interval: RefreshInterval, refresh: @escaping RefreshAction) {
        stop()
        refreshAction = refresh
        requestRefresh(
            minimumInterval: interval == .never ? interval.effectiveInterval : nil
        )

        guard interval != .never else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + interval.effectiveInterval,
            repeating: interval.effectiveInterval
        )
        timer.setEventHandler { [weak self] in
            self?.requestRefresh()
        }
        timer.resume()
        self.timer = timer
        isRunning = true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        refreshAction = nil
        isRefreshPending = false
        isRunning = false
    }

    private func requestRefresh(minimumInterval: TimeInterval? = nil) {
        guard let refreshAction else { return }
        let now = currentDateProvider()
        if let minimumInterval,
           let lastRefreshStartedAt,
           now.timeIntervalSince(lastRefreshStartedAt) < minimumInterval {
            return
        }
        guard !isRefreshInFlight else {
            isRefreshPending = true
            return
        }

        isRefreshInFlight = true
        lastRefreshStartedAt = now
        refreshAction { [weak self] in
            self?.queue.async {
                self?.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        isRefreshInFlight = false
        guard isRefreshPending, refreshAction != nil else { return }
        isRefreshPending = false
        requestRefresh()
    }

    deinit {
        stop()
    }
}
