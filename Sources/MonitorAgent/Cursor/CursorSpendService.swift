import Foundation

enum CursorSpendRefreshOutcome: Equatable {
    case success(CursorSpendSnapshot)
    case failure(CursorSpendSnapshot?, CursorRefreshFailureReason)
    case cancelled
    case superseded

    var snapshot: CursorSpendSnapshot? {
        switch self {
        case .success(let snapshot):
            return snapshot
        case .failure(let snapshot, _):
            return snapshot
        case .cancelled, .superseded:
            return nil
        }
    }
}

protocol CursorSpendRefreshing: AnyObject {
    func refresh(
        range: CursorSpendRange,
        expectedAccountIdentity: String?,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendRefreshOutcome) -> Void
    )
}

protocol CursorSpendServicing: AnyObject {
    func refresh(
        range: CursorSpendRange,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorSpendSnapshot?

    func refreshOutcome(
        range: CursorSpendRange,
        cancellation: AgentSyncCancellation?
    ) -> CursorSpendRefreshOutcome
}

extension CursorSpendServicing {
    func refreshOutcome(
        range: CursorSpendRange,
        cancellation: AgentSyncCancellation?
    ) -> CursorSpendRefreshOutcome {
        do {
            guard let snapshot = try refresh(
                range: range,
                cancellation: cancellation
            ) else {
                return .failure(nil, .request)
            }
            return .success(snapshot)
        } catch CursorUsageError.cancelled {
            return .cancelled
        } catch {
            return .failure(nil, error.cursorRefreshFailureReason)
        }
    }
}

enum CursorSpendError: LocalizedError, Equatable {
    case accountChanged
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .accountChanged:
            return "Cursor changed accounts before spend could be saved."
        case .invalidRange:
            return "The selected Cursor spend range is invalid."
        }
    }
}

final class CursorSpendService: CursorSpendServicing {
    private enum RefreshResult {
        case success(CursorSpendSnapshot)
        case failure(CursorSpendSnapshot, CursorRefreshFailureReason)

        var snapshot: CursorSpendSnapshot {
            switch self {
            case .success(let snapshot),
                 .failure(let snapshot, _):
                return snapshot
            }
        }
    }

    private struct TypedRefreshError: Error {
        let reason: CursorRefreshFailureReason
        let underlyingError: Error
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
        cancellation: AgentSyncCancellation? = nil
    ) throws -> CursorSpendSnapshot? {
        do {
            return try refreshResult(
                range: range,
                cancellation: cancellation
            ).snapshot
        } catch let error as TypedRefreshError {
            throw error.underlyingError
        }
    }

    func refreshOutcome(
        range: CursorSpendRange,
        cancellation: AgentSyncCancellation?
    ) -> CursorSpendRefreshOutcome {
        do {
            switch try refreshResult(
                range: range,
                cancellation: cancellation
            ) {
            case .success(let snapshot): return .success(snapshot)
            case .failure(let snapshot, let reason):
                return .failure(snapshot, reason)
            }
        } catch CursorUsageError.cancelled {
            return .cancelled
        } catch let error as TypedRefreshError {
            return .failure(nil, error.reason)
        } catch {
            return .failure(nil, error.cursorRefreshFailureReason)
        }
    }

    private func refreshResult(
        range: CursorSpendRange,
        cancellation: AgentSyncCancellation?
    ) throws -> RefreshResult {
        let currentDate = now()
        let authenticated = try accountSession.resolve(
            force: true,
            cancellation: cancellation
        )
        let account = authenticated.account
        let endMilliseconds = Int64(currentDate.timeIntervalSince1970 * 1_000)
        let hasDailyHistory = database.hasCursorDailySpendHistory(
            accountIdentity: account.syncIdentity
        )
        let replacementStart: Int64?
        let requestRanges: [(start: Int64, end: Int64)]
        if hasDailyHistory {
            replacementStart = previousUTCMonthStart(milliseconds: endMilliseconds)
            requestRanges = [(replacementStart!, endMilliseconds)]
        } else {
            replacementStart = nil
            requestRanges = utcMonthRanges(
                startMilliseconds: account.createdAtMilliseconds ?? 0,
                endMilliseconds: endMilliseconds
            )
        }
        guard !requestRanges.isEmpty else { throw CursorSpendError.invalidRange }

        let days: [CursorDailySpend]
        do {
            var totals: [Int64: Int64] = [:]
            for requestRange in requestRanges {
                for day in try fetchSpend(
                    token: authenticated.token,
                    account: account,
                    startMilliseconds: requestRange.start,
                    endMilliseconds: requestRange.end,
                    cancellation: cancellation
                ) {
                    let current = totals[day.dayMilliseconds] ?? 0
                    let (next, overflow) = current.addingReportingOverflow(Int64(day.totalCents))
                    guard !overflow, next <= Int64(Int.max) else {
                        throw CursorUsageError.invalidResponse
                    }
                    totals[day.dayMilliseconds] = next
                }
            }
            days = totals.map {
                CursorDailySpend(dayMilliseconds: $0.key, totalCents: Int($0.value))
            }
        } catch CursorUsageError.cancelled {
            throw CursorUsageError.cancelled
        } catch {
            let failureReason = error.cursorRefreshFailureReason
            if let cached = database.fetchCursorSpendSnapshot(
                accountIdentity: account.syncIdentity,
                range: range
            ) {
                return .failure(cached, failureReason)
            }
            throw TypedRefreshError(
                reason: failureReason,
                underlyingError: error
            )
        }

        let commit = {
            try self.database.replaceCursorDailySpend(
                accountIdentity: account.syncIdentity,
                days: days,
                replacementStartMilliseconds: replacementStart,
                replacementEndMilliseconds: replacementStart == nil ? nil : endMilliseconds,
                syncedThroughMilliseconds: endMilliseconds,
                updatedAt: currentDate
            )
        }
        if let cancellation {
            guard try cancellation.withEnabledAgent(
                .cursor,
                perform: commit
            ) != nil else {
                throw CursorUsageError.cancelled
            }
        } else {
            try commit()
        }
        guard let snapshot = database.fetchCursorSpendSnapshot(
            accountIdentity: account.syncIdentity,
            range: range
        ) else {
            throw CursorSpendError.accountChanged
        }
        return .success(snapshot)
    }

    private func fetchSpend(
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        cancellation: AgentSyncCancellation?
    ) throws -> [CursorDailySpend] {
        var body: [String: Any] = [
            "userId": account.userId,
            "periodStartMs": String(startMilliseconds),
            "periodEndMs": String(endMilliseconds),
            "groupBy": "SPEND_GROUP_BY_CATEGORY_MODEL",
            "spendType": "SPEND_TYPE_ALL",
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
        var totals: [Int64: Int64] = [:]
        let firstIncludedDay = startMilliseconds - (startMilliseconds % 86_400_000)
        for item in response.dailySpend {
            guard item.dayMilliseconds >= 0,
                  item.dayMilliseconds % 86_400_000 == 0,
                  item.dayMilliseconds >= firstIncludedDay,
                  item.dayMilliseconds < endMilliseconds,
                  item.spendCents >= 0 else {
                throw CursorUsageError.invalidResponse
            }
            let current = totals[item.dayMilliseconds] ?? 0
            let (next, overflow) = current.addingReportingOverflow(Int64(item.spendCents))
            guard !overflow, next <= Int64(Int.max) else {
                throw CursorUsageError.invalidResponse
            }
            totals[item.dayMilliseconds] = next
        }
        return totals.map {
            CursorDailySpend(dayMilliseconds: $0.key, totalCents: Int($0.value))
        }
    }

    private func previousUTCMonthStart(milliseconds: Int64) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        )!
        let previousMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth)!
        return Int64(previousMonth.timeIntervalSince1970 * 1_000)
    }

    private func utcMonthRanges(
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) -> [(start: Int64, end: Int64)] {
        guard startMilliseconds >= 0, endMilliseconds > startMilliseconds else { return [] }
        guard startMilliseconds > 0 else { return [(startMilliseconds, endMilliseconds)] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var start = startMilliseconds
        var ranges: [(start: Int64, end: Int64)] = []
        while start < endMilliseconds {
            let date = Date(timeIntervalSince1970: TimeInterval(start) / 1_000)
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: date)
            )!
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let end = min(Int64(nextMonth.timeIntervalSince1970 * 1_000), endMilliseconds)
            ranges.append((start, end))
            start = end
        }
        return ranges
    }
}

final class CursorSpendRefreshCoordinator: CursorSpendRefreshing {
    private final class Request {
        let range: CursorSpendRange
        let expectedAccountIdentity: String?
        var force: Bool
        let cancellation: AgentSyncCancellation?
        var completions: [(CursorSpendRefreshOutcome) -> Void]

        init(
            range: CursorSpendRange,
            expectedAccountIdentity: String?,
            force: Bool,
            cancellation: AgentSyncCancellation?,
            completion: @escaping (CursorSpendRefreshOutcome) -> Void
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
        completion: @escaping (CursorSpendRefreshOutcome) -> Void
    ) {
        let request = Request(
            range: range,
            expectedAccountIdentity: expectedAccountIdentity,
            force: force,
            cancellation: cancellation,
            completion: completion
        )
        var requestToStart: Request?
        var supersededCompletions: [(CursorSpendRefreshOutcome) -> Void] = []

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
                completionsToSupersede.forEach { $0(.superseded) }
            }
        }
        if let requestToStart {
            execute(requestToStart)
        }
    }

    private func execute(_ request: Request) {
        queue.async {
            let outcome = self.service.refreshOutcome(
                range: request.range,
                cancellation: request.cancellation
            )
            self.finish(request, outcome: outcome)
        }
    }

    private func finish(_ request: Request, outcome: CursorSpendRefreshOutcome) {
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
            completions.forEach { $0(outcome) }
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
        let responseContainer = try decoder.container(keyedBy: CursorResponseCodingKey.self)
        if responseContainer.allKeys.isEmpty {
            dailySpend = []
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailySpend = try container.decode(
            [CursorDailySpendItem].self,
            forKey: .dailySpend
        )
    }
}

private struct CursorDailySpendItem: Decodable {
    let dayMilliseconds: Int64
    let spendCents: Int

    private enum CodingKeys: String, CodingKey {
        case day
        case spendCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let day = try container.decodeFlexibleInt64IfPresent(forKey: .day) else {
            throw CursorUsageError.invalidResponse
        }
        dayMilliseconds = day
        spendCents = try container.decodeFlexibleInt(forKey: .spendCents)
    }
}
