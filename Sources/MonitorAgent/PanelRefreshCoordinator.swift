import Foundation

final class PanelRefreshCoordinator {
    typealias RefreshAction = (@escaping () -> Void) -> Void
    private enum RefreshTrigger {
        case automatic
        case manual
    }

    static let manualRefreshCooldown: TimeInterval = 10

    private let queue: DispatchQueue
    private let currentDateProvider: () -> Date
    private var timer: DispatchSourceTimer?
    private var interval: RefreshInterval?
    private var refreshAction: RefreshAction?
    private var refreshStateHandler: ((Bool, Bool) -> Void)?
    private var isRefreshInFlight = false
    private var activeTrigger: RefreshTrigger?
    private var pendingTrigger: RefreshTrigger?
    private var lastRefreshStartedAt: Date?
    private(set) var isRunning = false
    var manualRefreshAvailableAt: Date? {
        lastRefreshStartedAt?.addingTimeInterval(Self.manualRefreshCooldown)
    }

    init(
        queue: DispatchQueue = .main,
        currentDateProvider: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.currentDateProvider = currentDateProvider
    }

    func setRefreshStateHandler(_ handler: @escaping (Bool, Bool) -> Void) {
        refreshStateHandler = handler
        handler(isRefreshInFlight, activeTrigger == .manual)
    }

    func start(
        interval: RefreshInterval,
        initialRefreshMinimumInterval: TimeInterval? = nil,
        refresh: @escaping RefreshAction
    ) {
        stop()
        self.interval = interval
        refreshAction = refresh
        isRunning = interval != .never
        requestRefresh(minimumInterval: initialRefreshMinimumInterval)
    }

    /// Keep the shared manual refresh path available without starting a timer or an initial cycle.
    func configureManualRefresh(_ refresh: @escaping RefreshAction) {
        cancelTimer()
        interval = nil
        refreshAction = refresh
        pendingTrigger = nil
        isRunning = false
    }

    /// Start a manual refresh when the shared cooldown has elapsed.
    @discardableResult
    func refreshNow() -> Bool {
        guard refreshAction != nil else { return false }
        let now = currentDateProvider()
        guard manualRefreshCooldownRemaining(at: now) == 0 else { return false }
        cancelTimer()
        requestRefresh(trigger: .manual)
        return true
    }

    func manualRefreshCooldownRemaining(at date: Date) -> Int {
        guard let manualRefreshAvailableAt else { return 0 }
        return max(0, Int(ceil(manualRefreshAvailableAt.timeIntervalSince(date))))
    }

    func stop() {
        cancelTimer()
        interval = nil
        refreshAction = nil
        pendingTrigger = nil
        isRunning = false
    }

    private func requestRefresh(
        minimumInterval: TimeInterval? = nil,
        trigger: RefreshTrigger = .automatic
    ) {
        guard let refreshAction else { return }
        let now = currentDateProvider()
        if let minimumInterval,
           let lastRefreshStartedAt,
           now.timeIntervalSince(lastRefreshStartedAt) < minimumInterval {
            return
        }
        guard !isRefreshInFlight else {
            if trigger == .manual || pendingTrigger == nil {
                pendingTrigger = trigger
            }
            return
        }

        isRefreshInFlight = true
        activeTrigger = trigger
        refreshStateHandler?(true, trigger == .manual)
        lastRefreshStartedAt = now
        scheduleNextTimer()
        refreshAction { [weak self] in
            self?.queue.async {
                self?.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        if let pendingTrigger, refreshAction != nil {
            self.pendingTrigger = nil
            isRefreshInFlight = false
            activeTrigger = nil
            requestRefresh(trigger: pendingTrigger)
        } else {
            isRefreshInFlight = false
            activeTrigger = nil
            refreshStateHandler?(false, false)
        }
    }

    private func scheduleNextTimer() {
        cancelTimer()
        guard let interval, interval != .never, refreshAction != nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval.effectiveInterval)
        timer.setEventHandler { [weak self] in
            self?.timer = nil
            self?.requestRefresh()
        }
        timer.resume()
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }
}
