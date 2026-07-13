import Foundation

final class QuotaRefreshScheduler {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private(set) var isRunning = false

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func start(interval: TimeInterval, onRefresh: @escaping () -> Void) {
        stop()
        onRefresh()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: onRefresh)
        timer.resume()
        self.timer = timer
        isRunning = true
    }

    func restart(interval: TimeInterval, onRefresh: @escaping () -> Void) {
        start(interval: interval, onRefresh: onRefresh)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}
