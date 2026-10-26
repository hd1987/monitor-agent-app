import Foundation

protocol CursorAccountResolving: AnyObject {
    func resolve(
        force: Bool,
        cancellation: CursorOperationCancellation?
    ) throws -> CursorAuthenticatedAccount
}

final class CursorAccountSession: CursorAccountResolving {
    static let shared = CursorAccountSession()

    private let client: CursorDashboardClient
    private let now: () -> Date
    private let normalReuseInterval: TimeInterval
    private let onWaitForInFlight: (() -> Void)?
    private let condition = NSCondition()
    private let resolutionQueue = DispatchQueue(
        label: "com.monitoragent.cursor-account-session",
        qos: .userInitiated
    )
    private var isResolving = false
    private var resolvingAuthenticationRevision: UInt64?
    private var lastAuthenticationRevision: UInt64?
    private var resolutionGeneration = 0
    private var lastResult: Result<CursorAuthenticatedAccount, Error>?
    private var lastResolvedAt: Date?

    init(
        authenticationReader: CursorAuthenticationReading = CursorAuthenticationService.shared,
        transport: CursorHTTPTransport = CursorURLSessionTransport(),
        normalReuseInterval: TimeInterval = 2,
        onWaitForInFlight: (() -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        client = CursorDashboardClient(
            authenticationReader: authenticationReader,
            transport: transport
        )
        self.normalReuseInterval = normalReuseInterval
        self.onWaitForInFlight = onWaitForInFlight
        self.now = now
    }

    func resolve(
        force: Bool = false,
        cancellation: CursorOperationCancellation? = nil
    ) throws -> CursorAuthenticatedAccount {
        try checkCancellation(cancellation)
        let authenticationRevision = client.authenticationRevision
        condition.lock()
        defer { condition.unlock() }

        while isResolving, resolvingAuthenticationRevision != authenticationRevision {
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            try checkCancellation(cancellation)
            guard client.authenticationRevision == authenticationRevision else {
                throw CursorUsageError.cancelled
            }
        }

        if !isResolving,
           !force,
           lastAuthenticationRevision == authenticationRevision,
           let reusable = reusableResult() {
            return try reusable.get()
        }

        let observedGeneration = resolutionGeneration
        if isResolving {
            onWaitForInFlight?()
        } else {
            isResolving = true
            resolvingAuthenticationRevision = authenticationRevision
            resolutionQueue.async { [weak self] in
                guard let self else { return }
                let result = Result {
                    guard self.client.authenticationRevision == authenticationRevision else {
                        throw CursorUsageError.cancelled
                    }
                    return try self.client.authenticatedAccount(cancellation: nil)
                }
                self.condition.lock()
                self.lastResult = result
                self.lastAuthenticationRevision = authenticationRevision
                self.lastResolvedAt = self.now()
                self.isResolving = false
                self.resolutionGeneration += 1
                self.condition.broadcast()
                self.condition.unlock()
            }
        }

        while resolutionGeneration == observedGeneration {
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            try checkCancellation(cancellation)
        }
        guard client.authenticationRevision == authenticationRevision else {
            throw CursorUsageError.cancelled
        }
        guard let lastResult else {
            throw CursorUsageError.invalidResponse
        }
        return try lastResult.get()
    }

    private func reusableResult() -> Result<CursorAuthenticatedAccount, Error>? {
        guard let lastResult,
              let lastResolvedAt else {
            return nil
        }
        guard now().timeIntervalSince(lastResolvedAt) >= 0,
              now().timeIntervalSince(lastResolvedAt) < normalReuseInterval else {
            return nil
        }
        return lastResult
    }

    private func checkCancellation(_ cancellation: CursorOperationCancellation?) throws {
        if cancellation?.isCursorCancelled == true {
            throw CursorUsageError.cancelled
        }
    }
}
