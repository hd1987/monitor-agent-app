import CryptoKit
import Foundation

protocol CursorUsageSyncing {
    func sync() throws -> SessionSyncResult
}

protocol CancellableCursorUsageSyncing: CursorUsageSyncing {
    func sync(cancellation: CursorOperationCancellation?) throws -> SessionSyncResult
}

final class CursorUsageService: CancellableCursorUsageSyncing {
    static let syncStateKey = "cursor://usage-events"

    private static let pageSize = 100
    private static let maximumPages = 1_000
    private static let maximumBackfillPages = 10
    private static let maximumBackfillWindowMilliseconds: Int64 = 30 * 86_400_000
    private static let minimumBackfillWindowMilliseconds: Int64 = 60_000
    static let overlapMilliseconds: Int64 = 3_600_000

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

    func sync() throws -> SessionSyncResult {
        try sync(cancellation: nil)
    }

    func sync(cancellation: CursorOperationCancellation?) throws -> SessionSyncResult {
        try client.checkCancellation(cancellation)
        let currentDate = now()
        let currentSeconds = Int(currentDate.timeIntervalSince1970)
        let existingState = database.getSyncState(for: Self.syncStateKey)
        let authenticated = try accountSession.resolve(
            force: true,
            cancellation: cancellation
        )
        let token = authenticated.token
        let account = authenticated.account
        let accountIdentity = account.syncIdentity
        let accountChanged = existingState?.sessionId != accountIdentity
        let endMilliseconds = Int64(currentDate.timeIntervalSince1970 * 1_000)
        let startMilliseconds = accountChanged ? nil : existingState.map {
            Self.secondStart(milliseconds: max($0.byteOffset - Self.overlapMilliseconds, 0))
        }
        let events = try fetchEvents(
            token: token,
            account: account,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            cancellation: cancellation
        )
        try client.checkCancellation(cancellation)
        let records = try makeRecords(
            events: events,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        if let startMilliseconds {
            let replacementRange = Self.createdAtRange(
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
            guard records.allSatisfy({ replacementRange.contains($0.createdAt) }) else {
                throw CursorUsageError.invalidResponse
            }
        }
        let costBackfill = try accountChanged ? nil : fetchCostBackfill(
            token: token,
            account: account,
            accountIdentity: accountIdentity,
            currentSeconds: currentSeconds,
            cancellation: cancellation
        )
        let state = SyncState(
            filePath: Self.syncStateKey,
            byteOffset: endMilliseconds,
            recordCount: records.count,
            sessionId: accountIdentity,
            model: nil,
            lastModified: currentSeconds,
            lastSyncedAt: currentSeconds
        )
        if let cancellation {
            guard try cancellation.withActiveCursor(perform: {
                try commit(
                    records: records,
                    state: state,
                    accountChanged: accountChanged,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds,
                    costBackfill: costBackfill
                )
            }) != nil else {
                throw CursorUsageError.cancelled
            }
        } else {
            try commit(
                records: records,
                state: state,
                accountChanged: accountChanged,
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds,
                costBackfill: costBackfill
            )
        }
        return SessionSyncResult(
            filesSynced: 1,
            recordsSynced: records.count + (costBackfill?.records.count ?? 0)
        )
    }

    private func commit(
        records: [ParsedRecord],
        state: SyncState,
        accountChanged: Bool,
        startMilliseconds: Int64?,
        endMilliseconds: Int64,
        costBackfill: CursorUsageCostBackfillCommit?
    ) throws {
        if accountChanged {
            try database.replaceAppRecords(
                appType: "cursor",
                records: records,
                state: state
            )
        } else {
            guard let startMilliseconds else { throw CursorUsageError.invalidResponse }
            try database.replaceAppRecords(
                appType: AgentID.cursor.appType,
                records: records,
                state: state,
                createdAtRange: Self.createdAtRange(
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds
                ),
                costBackfill: costBackfill
            )
        }
    }

    private func fetchCostBackfill(
        token: String,
        account: CursorAccount,
        accountIdentity: String,
        currentSeconds: Int,
        cancellation: CursorOperationCancellation?
    ) throws -> CursorUsageCostBackfillCommit? {
        guard let state = database.cursorUsageCostBackfillState(
            accountIdentity: accountIdentity
        ), state.nextStartMilliseconds < state.targetEndMilliseconds else {
            return nil
        }

        let startMilliseconds = state.nextStartMilliseconds
        var endMilliseconds = min(
            startMilliseconds + Self.maximumBackfillWindowMilliseconds,
            state.targetEndMilliseconds
        )
        var events: [CursorUsageEvent] = []
        while true {
            do {
                events = try fetchEvents(
                    token: token,
                    account: account,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds,
                    cancellation: cancellation,
                    reportsDenseRange: true
                )
                break
            } catch CursorUsageFetchError.rangeTooDense {
                let reducedSpan = (endMilliseconds - startMilliseconds) / 2
                guard reducedSpan >= Self.minimumBackfillWindowMilliseconds else {
                    throw CursorUsageError.paginationLimitExceeded
                }
                endMilliseconds = startMilliseconds + reducedSpan
            }
        }

        let records = try makeRecords(
            events: events,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        let replacementRange = Self.createdAtRange(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds
        )
        guard records.allSatisfy({ replacementRange.contains($0.createdAt) }) else {
            throw CursorUsageError.invalidResponse
        }
        let nextState = endMilliseconds >= state.targetEndMilliseconds ? nil :
            CursorUsageCostBackfillState(
                accountIdentity: accountIdentity,
                nextStartMilliseconds: endMilliseconds,
                targetEndMilliseconds: state.targetEndMilliseconds,
                lastSyncedAt: currentSeconds
            )
        return CursorUsageCostBackfillCommit(
            records: records,
            createdAtRange: replacementRange,
            nextState: nextState
        )
    }

    private func fetchEvents(
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64?,
        endMilliseconds: Int64,
        cancellation: CursorOperationCancellation?,
        reportsDenseRange: Bool = false
    ) throws -> [CursorUsageEvent] {
        var events: [CursorUsageEvent] = []
        var page = 1
        var expectedEventCount: Int?

        while page <= Self.maximumPages {
            try client.checkCancellation(cancellation)
            if reportsDenseRange, page > Self.maximumBackfillPages {
                throw CursorUsageFetchError.rangeTooDense
            }
            var body: [String: Any] = [
                "userId": account.userId,
                "endDate": String(endMilliseconds),
                "page": page,
                "pageSize": Self.pageSize,
            ]
            if let teamId = account.teamId {
                body["teamId"] = teamId
            }
            if let startMilliseconds {
                body["startDate"] = String(startMilliseconds)
            }

            let data = try client.perform(
                path: "/aiserver.v1.DashboardService/GetFilteredUsageEvents",
                token: token,
                body: body,
                cancellation: cancellation
            )
            let response = try JSONDecoder().decode(CursorUsagePage.self, from: data)
            guard response.totalUsageEventsCount >= 0 else {
                throw CursorUsageError.invalidResponse
            }
            if let expectedEventCount {
                guard response.totalUsageEventsCount == expectedEventCount else {
                    throw CursorUsageError.invalidResponse
                }
            } else {
                expectedEventCount = response.totalUsageEventsCount
            }
            if reportsDenseRange,
               page == 1,
               response.totalUsageEventsCount > Self.pageSize * Self.maximumBackfillPages {
                throw CursorUsageFetchError.rangeTooDense
            }
            if response.totalUsageEventsCount == 0 {
                guard page == 1, response.usageEventsDisplay.isEmpty else {
                    throw CursorUsageError.invalidResponse
                }
                return events
            }
            guard !response.usageEventsDisplay.isEmpty else {
                throw CursorUsageError.invalidResponse
            }
            events.append(contentsOf: response.usageEventsDisplay)
            guard events.count <= response.totalUsageEventsCount else {
                throw CursorUsageError.invalidResponse
            }
            if events.count == response.totalUsageEventsCount {
                return events
            }
            page += 1
        }

        throw CursorUsageError.paginationLimitExceeded
    }

    private func makeRecord(event: CursorUsageEvent) throws -> ParsedRecord {
        guard let timestamp = event.timestampMilliseconds,
              !event.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CursorUsageError.invalidResponse
        }

        let usage = event.tokenUsage
        if usage == nil, event.chargedCents != 0 {
            throw CursorUsageError.invalidResponse
        }

        var identity = [
            String(timestamp),
            event.conversationId ?? "",
            event.model,
            event.kind ?? "",
        ]
        if let usage {
            identity.append(contentsOf: [
                String(usage.inputTokens),
                String(usage.outputTokens),
                String(usage.cacheReadTokens),
                String(usage.cacheWriteTokens),
            ])
        } else {
            identity.append("free")
        }
        let identityValue = identity.joined(separator: "|")
        let digest = SHA256.hash(data: Data(identityValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let requestId = "cursor:\(digest)"
        let sessionId = event.conversationId.flatMap { $0.isEmpty ? nil : $0 } ?? requestId

        return ParsedRecord(
            requestId: requestId,
            appType: "cursor",
            model: event.model,
            inputTokens: max(usage?.inputTokens ?? 0, 0),
            outputTokens: max(usage?.outputTokens ?? 0, 0),
            cacheReadTokens: max(usage?.cacheReadTokens ?? 0, 0),
            cacheCreationTokens: max(usage?.cacheWriteTokens ?? 0, 0),
            sessionId: sessionId,
            createdAt: Int(timestamp / 1_000),
            chargedCostMicros: try costMicros(fromCents: event.chargedCents),
            listCostMicros: try costMicros(fromCents: usage?.totalCents),
            discountPercent: usage?.discountPercentOff,
            isFreeRequest: usage == nil
        )
    }

    private func makeRecords(
        events: [CursorUsageEvent],
        startMilliseconds: Int64?,
        endMilliseconds: Int64
    ) throws -> [ParsedRecord] {
        let lowerBound = startMilliseconds ?? 0
        guard lowerBound <= endMilliseconds,
              events.allSatisfy({ event in
                  guard let timestamp = event.timestampMilliseconds else { return false }
                  return lowerBound <= timestamp && timestamp <= endMilliseconds
              }) else {
            throw CursorUsageError.invalidResponse
        }
        let records = try events.map { try makeRecord(event: $0) }
        guard Set(records.map(\.requestId)).count == records.count else {
            throw CursorUsageError.invalidResponse
        }
        return records
    }

    private static func secondStart(milliseconds: Int64) -> Int64 {
        milliseconds - (milliseconds % 1_000)
    }

    private static func createdAtRange(
        startMilliseconds: Int64,
        endMilliseconds: Int64
    ) -> Range<Int> {
        let startSeconds = Int(startMilliseconds / 1_000)
        let endSeconds = Int(endMilliseconds / 1_000) + 1
        return startSeconds..<endSeconds
    }

    private func costMicros(fromCents cents: Double?) throws -> Int64? {
        guard let cents else { return nil }
        guard cents.isFinite, cents >= 0, cents <= Double(Int64.max) / 10_000 else {
            throw CursorUsageError.invalidResponse
        }
        return Int64((cents * 10_000).rounded())
    }
}

private enum CursorUsageFetchError: Error {
    case rangeTooDense
}

private struct CursorUsagePage: Decodable {
    let totalUsageEventsCount: Int
    let usageEventsDisplay: [CursorUsageEvent]

    private enum CodingKeys: String, CodingKey {
        case totalUsageEventsCount
        case usageEventsDisplay
    }

    init(from decoder: Decoder) throws {
        let responseContainer = try decoder.container(keyedBy: CursorResponseCodingKey.self)
        if responseContainer.allKeys.isEmpty {
            totalUsageEventsCount = 0
            usageEventsDisplay = []
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalUsageEventsCount = try container.decodeFlexibleInt(forKey: .totalUsageEventsCount)
        usageEventsDisplay = try container.decode([CursorUsageEvent].self, forKey: .usageEventsDisplay)
    }
}

private struct CursorUsageEvent: Decodable {
    let timestampMilliseconds: Int64?
    let model: String
    let kind: String?
    let conversationId: String?
    let tokenUsage: CursorTokenUsage?
    let chargedCents: Double?

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case model
        case kind
        case conversationId
        case tokenUsage
        case chargedCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampMilliseconds = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        tokenUsage = try container.decodeIfPresent(CursorTokenUsage.self, forKey: .tokenUsage)
        chargedCents = try container.decodeFlexibleDoubleIfPresent(forKey: .chargedCents)
    }
}

private struct CursorTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let totalCents: Double?
    let discountPercentOff: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheWriteTokens
        case cacheReadTokens
        case totalCents
        case discountPercentOff
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeFlexibleIntIfPresent(forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeFlexibleIntIfPresent(forKey: .outputTokens) ?? 0
        cacheWriteTokens = try container.decodeFlexibleIntIfPresent(forKey: .cacheWriteTokens) ?? 0
        cacheReadTokens = try container.decodeFlexibleIntIfPresent(forKey: .cacheReadTokens) ?? 0
        totalCents = try container.decodeFlexibleDoubleIfPresent(forKey: .totalCents)
        discountPercentOff = try container.decodeFlexibleIntIfPresent(forKey: .discountPercentOff)
        if let discountPercentOff, !(0...100).contains(discountPercentOff) {
            throw DecodingError.dataCorruptedError(
                forKey: .discountPercentOff,
                in: container,
                debugDescription: "Expected a percentage from 0 through 100."
            )
        }
    }
}
