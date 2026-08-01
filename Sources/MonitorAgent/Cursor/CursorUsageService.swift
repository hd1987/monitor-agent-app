import CryptoKit
import Foundation
import GRDB

protocol CursorUsageSyncing {
    func sync() throws -> SessionSyncResult
}

protocol CancellableCursorUsageSyncing: CursorUsageSyncing {
    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult
}

protocol CursorAuthenticationReading {
    func readAccessToken() throws -> String
}

protocol CursorHTTPTransport {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse)
}

protocol CancellableCursorHTTPTransport: CursorHTTPTransport {
    func send(
        _ request: URLRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> (Data, HTTPURLResponse)
}

enum CursorUsageError: LocalizedError, Equatable {
    case authenticationUnavailable
    case authenticationRejected
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case paginationLimitExceeded
    case requestFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .authenticationUnavailable:
            return "Cursor is not signed in locally."
        case .authenticationRejected:
            return "Cursor rejected its current local login session."
        case .invalidEndpoint:
            return "The Cursor usage endpoint was rejected."
        case .invalidResponse:
            return "Cursor returned an unsupported usage response."
        case .responseTooLarge:
            return "Cursor returned an unexpectedly large usage response."
        case .paginationLimitExceeded:
            return "Cursor usage pagination exceeded the safety limit."
        case .requestFailed:
            return "Cursor usage could not be refreshed."
        case .cancelled:
            return "Cursor usage refresh was canceled."
        }
    }

    var allowsRebuildWithoutCursorData: Bool {
        switch self {
        case .authenticationUnavailable, .authenticationRejected, .requestFailed, .cancelled:
            return true
        case .invalidEndpoint, .invalidResponse, .responseTooLarge, .paginationLimitExceeded:
            return false
        }
    }
}

final class CursorStateAuthenticationReader: CursorAuthenticationReading {
    static let defaultDatabasePath =
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    private let databasePath: String

    init(databasePath: String = CursorStateAuthenticationReader.defaultDatabasePath) {
        self.databasePath = databasePath
    }

    func readAccessToken() throws -> String {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: databasePath, configuration: configuration)
        let token = try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                arguments: ["cursorAuth/accessToken"]
            )
        }?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token, !token.isEmpty else {
            throw CursorUsageError.authenticationUnavailable
        }
        return token
    }
}

final class CursorURLSessionTransport: NSObject, CancellableCursorHTTPTransport, URLSessionTaskDelegate {
    private static let timeout: TimeInterval = 20
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        try send(request, isCancelled: { false })
    }

    func send(
        _ request: URLRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<(Data, HTTPURLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            lock.lock()
            defer {
                lock.unlock()
                semaphore.signal()
            }
            if let error {
                result = .failure(error)
            } else if let data, let response = response as? HTTPURLResponse {
                result = .success((data, response))
            } else {
                result = .failure(CursorUsageError.invalidResponse)
            }
        }
        task.resume()

        let deadline = Date().addingTimeInterval(Self.timeout + 1)
        while semaphore.wait(timeout: .now() + 0.1) != .success {
            if isCancelled() {
                task.cancel()
                throw CursorUsageError.cancelled
            }
            if Date() >= deadline {
                task.cancel()
                throw CursorUsageError.requestFailed
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard let result else { throw CursorUsageError.requestFailed }
        return try result.get()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class CursorUsageService: CancellableCursorUsageSyncing {
    static let syncStateKey = "cursor://usage-events"

    private static let apiOrigin = URL(string: "https://api2.cursor.sh")!
    private static let pageSize = 100
    private static let maximumPages = 1_000
    private static let maximumResponseBytes = 5 * 1_024 * 1_024
    private static let overlapMilliseconds: Int64 = 60_000

    private let database: DatabaseManager
    private let authenticationReader: CursorAuthenticationReading
    private let transport: CursorHTTPTransport
    private let now: () -> Date

    init(
        database: DatabaseManager = .shared,
        authenticationReader: CursorAuthenticationReading = CursorStateAuthenticationReader(),
        transport: CursorHTTPTransport = CursorURLSessionTransport(),
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.authenticationReader = authenticationReader
        self.transport = transport
        self.now = now
    }

    func sync() throws -> SessionSyncResult {
        try sync(cancellation: nil)
    }

    func sync(cancellation: AgentSyncCancellation?) throws -> SessionSyncResult {
        try checkCancellation(cancellation)
        let currentDate = now()
        let currentSeconds = Int(currentDate.timeIntervalSince1970)
        let existingState = database.getSyncState(for: Self.syncStateKey)
        let token = try authenticationReader.readAccessToken()
        try checkCancellation(cancellation)
        let account = try fetchAccount(token: token, cancellation: cancellation)
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
        try checkCancellation(cancellation)
        let records = events.compactMap(makeRecord)
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
            guard try cancellation.withEnabledAgent(.cursor, perform: {
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

    private func fetchAccount(
        token: String,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorAccount {
        let data = try perform(
            path: "/aiserver.v1.DashboardService/GetMe",
            token: token,
            body: [:],
            cancellation: cancellation
        )
        return try JSONDecoder().decode(CursorAccount.self, from: data)
    }

    private func fetchEvents(
        token: String,
        account: CursorAccount,
        startMilliseconds: Int64?,
        endMilliseconds: Int64,
        cancellation: AgentSyncCancellation?
    ) throws -> [CursorUsageEvent] {
        var events: [CursorUsageEvent] = []
        var page = 1

        while page <= Self.maximumPages {
            try checkCancellation(cancellation)
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

            let data = try perform(
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

    private func perform(
        path: String,
        token: String,
        body: [String: Any],
        cancellation: AgentSyncCancellation?
    ) throws -> Data {
        try checkCancellation(cancellation)
        let url = Self.apiOrigin.appendingPathComponent(path)
        guard url.scheme == "https",
              url.host == "api2.cursor.sh",
              url.port == nil else {
            throw CursorUsageError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let data: Data
        let response: HTTPURLResponse
        do {
            if let transport = transport as? CancellableCursorHTTPTransport {
                (data, response) = try transport.send(request) {
                    cancellation?.isEnabled(.cursor) == false
                }
            } else {
                (data, response) = try transport.send(request)
            }
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestFailed
        }
        try checkCancellation(cancellation)
        guard data.count <= Self.maximumResponseBytes else {
            throw CursorUsageError.responseTooLarge
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CursorUsageError.authenticationRejected
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CursorUsageError.requestFailed
        }
        return data
    }

    private func checkCancellation(_ cancellation: AgentSyncCancellation?) throws {
        if cancellation?.isEnabled(.cursor) == false {
            throw CursorUsageError.cancelled
        }
    }

    private func makeRecord(event: CursorUsageEvent) -> ParsedRecord? {
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
            createdAt: Int(timestamp / 1_000)
        )
    }
}

private struct CursorAccount: Decodable {
    let userId: Int
    let teamId: Int?

    private enum CodingKeys: String, CodingKey {
        case userId
        case teamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decodeFlexibleInt(forKey: .userId)
        teamId = try container.decodeFlexibleIntIfPresent(forKey: .teamId)
    }

    var syncIdentity: String {
        let value = "\(userId)|\(teamId.map(String.init) ?? "")"
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "cursor-account:\(digest)"
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

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case model
        case kind
        case conversationId
        case tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampMilliseconds = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        tokenUsage = try container.decodeIfPresent(CursorTokenUsage.self, forKey: .tokenUsage)
    }
}

private struct CursorTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cacheWriteTokens
        case cacheReadTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeFlexibleIntIfPresent(forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeFlexibleIntIfPresent(forKey: .outputTokens) ?? 0
        cacheWriteTokens = try container.decodeFlexibleIntIfPresent(forKey: .cacheWriteTokens) ?? 0
        cacheReadTokens = try container.decodeFlexibleIntIfPresent(forKey: .cacheReadTokens) ?? 0
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        let value = try decode(String.self, forKey: key)
        guard let result = Int(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected an integer."
            )
        }
        return result
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFlexibleInt(forKey: key)
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int64.self, forKey: key) {
            return value
        }
        let value = try decode(String.self, forKey: key)
        guard let result = Int64(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a 64-bit integer."
            )
        }
        return result
    }
}
