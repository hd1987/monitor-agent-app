import Foundation

protocol CursorSpendRefreshing: AnyObject {
    func refresh(
        range: CursorSpendRange,
        expectedAccountIdentity: String?,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendSnapshot?) -> Void
    )
}

protocol CursorSpendServicing: AnyObject {
    func refresh(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorSpendSnapshot?
}

enum CursorSpendError: LocalizedError, Equatable {
    case accountChanged
    case invalidRange
    case invalidBreakdown

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            return "Cursor changed accounts before spend could be saved."
        case .invalidRange:
            return "The selected Cursor spend range is invalid."
        case .invalidBreakdown:
            return "Cursor returned an invalid spend breakdown."
        }
    }
}

final class CursorSpendService: CursorSpendServicing {
    static let automaticCacheLifetime: TimeInterval = 5 * 60

    private enum Scope: CaseIterable {
        case total
        case onDemand

        var apiValue: String {
            switch self {
            case .total: return "SPEND_TYPE_ALL"
            case .onDemand: return "SPEND_TYPE_ON_DEMAND"
            }
        }
    }

    private let database: DatabaseManager
    private let accountSession: CursorAccountResolving
    private let client: CursorDashboardClient
    private let now: () -> Date

    init(
        database: DatabaseManager = .shared,
        accountSession: CursorAccountResolving = CursorAccountSession.shared,
        client: CursorDashboardClient = CursorDashboardClient(),
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.accountSession = accountSession
        self.client = client
        self.now = now
    }

    convenience init(
        database: DatabaseManager = .shared,
        authenticationReader: CursorAuthenticationReading,
        transport: CursorHTTPTransport,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            database: database,
            accountSession: CursorAccountSession(
                authenticationReader: authenticationReader,
                transport: transport,
                normalReuseInterval: 0
            ),
            client: CursorDashboardClient(
                authenticationReader: authenticationReader,
                transport: transport
            ),
            now: now
        )
    }

    func refresh(
        range: CursorSpendRange,
        force: Bool = false,
        cancellation: AgentSyncCancellation? = nil
    ) throws -> CursorSpendSnapshot? {
        let currentDate = now()
        let authenticated = try accountSession.resolve(
            force: true,
            cancellation: cancellation
        )
        let account = authenticated.account
        if !force,
           let cached = database.fetchCursorSpendSnapshot(
               accountIdentity: account.syncIdentity,
               range: range
           ),
           cached.isFresh(at: currentDate, maximumAge: Self.automaticCacheLifetime) {
            return cached
        }

        let startMilliseconds = range.startMilliseconds
            ?? account.createdAtMilliseconds
            ?? 0
        let endMilliseconds = range.endMilliseconds
            ?? Int64(currentDate.timeIntervalSince1970 * 1_000)
        guard startMilliseconds >= 0,
              endMilliseconds > startMilliseconds else {
            throw CursorSpendError.invalidRange
        }

        let results = fetchScopes(
            token: authenticated.token,
            account: account,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            cancellation: cancellation
        )
        let totalCents = results[.total]?.successValue
        var onDemandCents = results[.onDemand]?.successValue

        if let total = totalCents,
           let onDemand = onDemandCents,
           onDemand > total {
            onDemandCents = nil
        }
        if totalCents == nil, onDemandCents == nil {
            if let cached = database.fetchCursorSpendSnapshot(
                accountIdentity: account.syncIdentity,
                range: range
            ) {
                return cached
            }
            throw results.values.compactMap(\.failureValue).first
                ?? CursorUsageError.invalidResponse
        }

        let commit = {
            try self.database.mergeCursorSpendSnapshot(
                accountIdentity: account.syncIdentity,
                range: range,
                totalCents: totalCents,
                onDemandCents: onDemandCents,
                updatedAt: currentDate
            )
        }
        let snapshot: CursorSpendSnapshot?
        if let cancellation {
            guard let committed = try cancellation.withEnabledAgent(
                .cursor,
                perform: commit
            ) else {
                throw CursorUsageError.cancelled
            }
            snapshot = committed
        } else {
            snapshot = try commit()
        }
        guard let snapshot else {
            throw CursorSpendError.accountChanged
        }
        return snapshot
    }

    private func fetchScopes(
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        cancellation: AgentSyncCancellation?
    ) -> [Scope: Result<Int, Error>] {
        let group = DispatchGroup()
        let lock = NSLock()
        let queue = DispatchQueue(
            label: "com.monitoragent.cursor-spend-scopes",
            qos: .utility,
            attributes: .concurrent
        )
        var results: [Scope: Result<Int, Error>] = [:]

        for scope in Scope.allCases {
            group.enter()
            queue.async {
                let result = Result {
                    try self.fetchSpend(
                        scope: scope,
                        token: token,
                        account: account,
                        startMilliseconds: startMilliseconds,
                        endMilliseconds: endMilliseconds,
                        cancellation: cancellation
                    )
                }
                lock.lock()
                results[scope] = result
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results
    }

    private func fetchSpend(
        scope: Scope,
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        cancellation: AgentSyncCancellation?
    ) throws -> Int {
        var body: [String: Any] = [
            "userId": account.userId,
            "periodStartMs": String(startMilliseconds),
            "periodEndMs": String(endMilliseconds),
            "groupBy": "SPEND_GROUP_BY_CATEGORY_MODEL",
            "spendType": scope.apiValue,
        ]
        if let teamId = account.teamId {
            body["teamId"] = teamId
        }
        let data = try client.perform(
            path: "/aiserver.v1.DashboardService/GetDailySpendByCategory",
            token: token,
            body: body,
            cancellation: cancellation
        )
        let response: CursorDailySpendResponse
        do {
            response = try JSONDecoder().decode(CursorDailySpendResponse.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
        var total: Int64 = 0
        for item in response.dailySpend {
            guard item.spendCents >= 0 else {
                throw CursorUsageError.invalidResponse
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(item.spendCents))
            guard !overflow, next <= Int64(Int.max) else {
                throw CursorUsageError.invalidResponse
            }
            total = next
        }
        return Int(total)
    }
}

final class CursorSpendRefreshCoordinator: CursorSpendRefreshing {
    private final class Request {
        let range: CursorSpendRange
        let expectedAccountIdentity: String?
        var force: Bool
        let cancellation: AgentSyncCancellation?
        var completions: [(CursorSpendSnapshot?) -> Void]

        init(
            range: CursorSpendRange,
            expectedAccountIdentity: String?,
            force: Bool,
            cancellation: AgentSyncCancellation?,
            completion: @escaping (CursorSpendSnapshot?) -> Void
        ) {
            self.range = range
            self.expectedAccountIdentity = expectedAccountIdentity
            self.force = force
            self.cancellation = cancellation
            completions = [completion]
        }

        func matches(
            range: CursorSpendRange,
            expectedAccountIdentity: String?,
            cancellation: AgentSyncCancellation?
        ) -> Bool {
            guard matchesScope(
                range: range,
                expectedAccountIdentity: expectedAccountIdentity
            ) else {
                return false
            }
            switch (self.cancellation, cancellation) {
            case (nil, nil):
                return true
            case (let current?, let candidate?):
                return current === candidate
            default:
                return false
            }
        }

        func matchesScope(
            range: CursorSpendRange,
            expectedAccountIdentity: String?
        ) -> Bool {
            self.range == range
                && self.expectedAccountIdentity == expectedAccountIdentity
        }
    }

    private let service: CursorSpendServicing
    private let queue = DispatchQueue(label: "com.monitoragent.cursor-spend", qos: .utility)
    private let stateLock = NSLock()
    private var activeRequest: Request?
    private var pendingRequest: Request?

    init(
        database: DatabaseManager = .shared,
        service: CursorSpendServicing? = nil
    ) {
        self.service = service ?? CursorSpendService(database: database)
    }

    func refresh(
        range: CursorSpendRange,
        expectedAccountIdentity: String?,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendSnapshot?) -> Void
    ) {
        let request = Request(
            range: range,
            expectedAccountIdentity: expectedAccountIdentity,
            force: force,
            cancellation: cancellation,
            completion: completion
        )
        var requestToStart: Request?
        var supersededCompletions: [(CursorSpendSnapshot?) -> Void] = []

        stateLock.lock()
        if let activeRequest {
            if let pendingRequest,
               pendingRequest.matches(
                   range: range,
                   expectedAccountIdentity: expectedAccountIdentity,
                   cancellation: cancellation
               ) {
                pendingRequest.force = pendingRequest.force || force
                pendingRequest.completions.append(completion)
            } else if let pendingRequest,
                      pendingRequest.force,
                      pendingRequest.matchesScope(
                          range: range,
                          expectedAccountIdentity: expectedAccountIdentity
                      ) {
                pendingRequest.completions.append(completion)
            } else {
                supersededCompletions = pendingRequest?.completions ?? []
                pendingRequest = nil
                if activeRequest.matches(
                    range: range,
                    expectedAccountIdentity: expectedAccountIdentity,
                    cancellation: cancellation
                ),
                   activeRequest.force || !request.force {
                    activeRequest.completions.append(completion)
                } else {
                    pendingRequest = request
                }
            }
        } else {
            activeRequest = request
            requestToStart = request
        }
        stateLock.unlock()

        let completionsToSupersede = supersededCompletions
        if !completionsToSupersede.isEmpty {
            DispatchQueue.main.async {
                completionsToSupersede.forEach { $0(nil) }
            }
        }
        if let requestToStart {
            execute(requestToStart)
        }
    }

    private func execute(_ request: Request) {
        queue.async {
            let snapshot = try? self.service.refresh(
                range: request.range,
                force: request.force,
                cancellation: request.cancellation
            )
            self.finish(request, snapshot: snapshot)
        }
    }

    private func finish(_ request: Request, snapshot: CursorSpendSnapshot?) {
        stateLock.lock()
        guard activeRequest === request else {
            stateLock.unlock()
            return
        }
        let completions = request.completions
        let nextRequest = pendingRequest
        activeRequest = nextRequest
        pendingRequest = nil
        stateLock.unlock()

        DispatchQueue.main.async {
            completions.forEach { $0(snapshot) }
        }
        if let nextRequest {
            execute(nextRequest)
        }
    }
}

private struct CursorDailySpendResponse: Decodable {
    let dailySpend: [CursorDailySpendItem]

    private enum CodingKeys: String, CodingKey {
        case dailySpend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailySpend = try container.decode(
            [CursorDailySpendItem].self,
            forKey: .dailySpend
        )
    }
}

private struct CursorDailySpendItem: Decodable {
    let spendCents: Int

    private enum CodingKeys: String, CodingKey {
        case spendCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spendCents = try container.decodeFlexibleInt(forKey: .spendCents)
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failureValue: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
