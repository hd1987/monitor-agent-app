import Foundation

protocol CursorSpendRefreshing: AnyObject {
    func refresh(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendSnapshot?) -> Void
    )
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

final class CursorSpendService {
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
    private let client: CursorDashboardClient
    private let now: () -> Date

    init(
        database: DatabaseManager = .shared,
        authenticationReader: CursorAuthenticationReading = CursorStateAuthenticationReader(),
        transport: CursorHTTPTransport = CursorURLSessionTransport(),
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.client = CursorDashboardClient(
            authenticationReader: authenticationReader,
            transport: transport
        )
        self.now = now
    }

    func refresh(
        range: CursorSpendRange,
        force: Bool = false,
        cancellation: AgentSyncCancellation? = nil
    ) throws -> CursorSpendSnapshot? {
        let currentDate = now()
        if !force,
           let cached = database.fetchCursorSpendSnapshot(range: range),
           cached.isFresh(at: currentDate, maximumAge: Self.automaticCacheLifetime) {
            return cached
        }

        let authenticated = try client.authenticatedAccount(cancellation: cancellation)
        let account = authenticated.account
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
    private let service: CursorSpendService
    private let database: DatabaseManager
    private let queue = DispatchQueue(label: "com.monitoragent.cursor-spend", qos: .utility)

    init(
        database: DatabaseManager = .shared,
        service: CursorSpendService? = nil
    ) {
        self.database = database
        self.service = service ?? CursorSpendService(database: database)
    }

    func refresh(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?,
        completion: @escaping (CursorSpendSnapshot?) -> Void
    ) {
        queue.async {
            let snapshot = (try? self.service.refresh(
                range: range,
                force: force,
                cancellation: cancellation
            )) ?? self.database.fetchCursorSpendSnapshot(range: range)
            DispatchQueue.main.async {
                completion(snapshot)
            }
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
        dailySpend = try container.decodeIfPresent(
            [CursorDailySpendItem].self,
            forKey: .dailySpend
        ) ?? []
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
