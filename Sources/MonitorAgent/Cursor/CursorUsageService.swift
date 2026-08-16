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
    private static let overlapMilliseconds: Int64 = 60_000

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
            max($0.byteOffset - Self.overlapMilliseconds, 0)
        }
        let events = try fetchEvents(
            token: token,
            account: account,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            cancellation: cancellation
        )
        try client.checkCancellation(cancellation)
        let records = try events.compactMap { try makeRecord(event: $0) }
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
                try commit(records: records, state: state, accountChanged: accountChanged)
            }) != nil else {
                throw CursorUsageError.cancelled
            }
        } else {
            try commit(records: records, state: state, accountChanged: accountChanged)
        }
        return SessionSyncResult(filesSynced: 1, recordsSynced: records.count)
    }

    private func commit(
        records: [ParsedRecord],
        state: SyncState,
        accountChanged: Bool
    ) throws {
        if accountChanged {
            try database.replaceAppRecords(
                appType: "cursor",
                records: records,
                state: state
            )
        } else {
            try database.commitSync(records: records, state: state)
        }
    }

    private func fetchEvents(
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64?,
        endMilliseconds: Int64,
        cancellation: CursorOperationCancellation?
    ) throws -> [CursorUsageEvent] {
        var events: [CursorUsageEvent] = []
        var page = 1

        while page <= Self.maximumPages {
            try client.checkCancellation(cancellation)
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
            events.append(contentsOf: response.usageEventsDisplay)

            if events.count >= response.totalUsageEventsCount
                || response.usageEventsDisplay.isEmpty {
                return events
            }
            page += 1
        }

        throw CursorUsageError.paginationLimitExceeded
    }

    private func makeRecord(event: CursorUsageEvent) throws -> ParsedRecord? {
        guard let timestamp = event.timestampMilliseconds,
              let usage = event.tokenUsage,
              !event.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let identity = [
            String(timestamp),
            event.conversationId ?? "",
            event.model,
            event.kind ?? "",
            String(usage.inputTokens),
            String(usage.outputTokens),
            String(usage.cacheReadTokens),
            String(usage.cacheWriteTokens),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let requestId = "cursor:\(digest)"
        let sessionId = event.conversationId.flatMap { $0.isEmpty ? nil : $0 } ?? requestId

        return ParsedRecord(
            requestId: requestId,
            appType: "cursor",
            model: event.model,
            inputTokens: max(usage.inputTokens, 0),
            outputTokens: max(usage.outputTokens, 0),
            cacheReadTokens: max(usage.cacheReadTokens, 0),
            cacheCreationTokens: max(usage.cacheWriteTokens, 0),
            sessionId: sessionId,
            createdAt: Int(timestamp / 1_000),
            chargedCostMicros: try costMicros(fromCents: event.chargedCents),
            listCostMicros: try costMicros(fromCents: usage.totalCents),
            discountPercent: usage.discountPercentOff
        )
    }

    private func costMicros(fromCents cents: Double?) throws -> Int64? {
        guard let cents else { return nil }
        guard cents.isFinite, cents >= 0, cents <= Double(Int64.max) / 10_000 else {
            throw CursorUsageError.invalidResponse
        }
        return Int64((cents * 10_000).rounded())
    }
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
