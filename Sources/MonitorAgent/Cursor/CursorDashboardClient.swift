import CryptoKit
import Foundation
import GRDB

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

private enum CursorDashboardLimits {
    static let maximumResponseBytes = 5 * 1_024 * 1_024
}

struct CursorResponseCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum CursorRefreshFailureReason: Equatable {
    case authentication
    case request
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

extension Error {
    var cursorRefreshFailureReason: CursorRefreshFailureReason {
        switch self as? CursorUsageError {
        case .authenticationUnavailable, .authenticationRejected:
            return .authentication
        default:
            return .request
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

final class CursorURLSessionTransport: NSObject, CancellableCursorHTTPTransport {
    private final class RequestState {
        let semaphore = DispatchSemaphore(value: 0)
        var data = Data()
        var response: HTTPURLResponse?
        var result: Result<(Data, HTTPURLResponse), Error>?
    }

    private final class SessionDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: CursorURLSessionTransport?

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let owner else {
                completionHandler(.cancel)
                return
            }
            owner.receive(response, for: dataTask, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            owner?.receive(data, for: dataTask)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            owner?.complete(task, error: error)
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

    private static let timeout: TimeInterval = 20
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int
    private let stateLock = NSLock()
    private let sessionLock = NSLock()
    private var requestStates: [Int: RequestState] = [:]
    private var storedSession: URLSession?
    private let delegateQueue: OperationQueue
    private let sessionDelegate: SessionDelegate

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = CursorDashboardLimits.maximumResponseBytes
    ) {
        self.configuration = configuration
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        delegateQueue = queue
        sessionDelegate = SessionDelegate()
        super.init()
        sessionDelegate.owner = self
    }

    deinit {
        sessionDelegate.owner = nil
        sessionLock.lock()
        let session = storedSession
        storedSession = nil
        sessionLock.unlock()
        session?.invalidateAndCancel()
    }

    private func session() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let storedSession {
            return storedSession
        }
        let configuration = configuration
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: delegateQueue
        )
        storedSession = session
        return session
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        try send(request, isCancelled: { false })
    }

    func send(
        _ request: URLRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> (Data, HTTPURLResponse) {
        let state = RequestState()
        let task = session().dataTask(with: request)
        stateLock.lock()
        requestStates[task.taskIdentifier] = state
        stateLock.unlock()
        task.resume()

        let deadline = Date().addingTimeInterval(Self.timeout + 1)
        while state.semaphore.wait(timeout: .now() + 0.1) != .success {
            if isCancelled() {
                task.cancel()
                abandon(task)
                throw CursorUsageError.cancelled
            }
            if Date() >= deadline {
                task.cancel()
                abandon(task)
                throw CursorUsageError.requestFailed
            }
        }

        guard let result = state.result else { throw CursorUsageError.requestFailed }
        return try result.get()
    }

    private func receive(
        _ response: URLResponse,
        for dataTask: URLSessionDataTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            complete(dataTask, with: .failure(CursorUsageError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumResponseBytes) else {
            complete(dataTask, with: .failure(CursorUsageError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        state(for: dataTask)?.response = response
        completionHandler(.allow)
    }

    private func receive(_ data: Data, for dataTask: URLSessionDataTask) {
        guard let state = state(for: dataTask) else { return }
        guard data.count <= maximumResponseBytes - state.data.count else {
            complete(dataTask, with: .failure(CursorUsageError.responseTooLarge))
            dataTask.cancel()
            return
        }
        state.data.append(data)
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        guard let state = state(for: task) else { return }
        if let error {
            complete(task, with: .failure(error))
        } else if let response = state.response {
            complete(task, with: .success((state.data, response)))
        } else {
            complete(task, with: .failure(CursorUsageError.invalidResponse))
        }
    }

    private func state(for task: URLSessionTask) -> RequestState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestStates[task.taskIdentifier]
    }

    private func complete(
        _ task: URLSessionTask,
        with result: Result<(Data, HTTPURLResponse), Error>
    ) {
        stateLock.lock()
        let state = requestStates.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()
        guard let state else { return }
        state.result = result
        state.semaphore.signal()
    }

    private func abandon(_ task: URLSessionTask) {
        stateLock.lock()
        requestStates.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()
    }
}

struct CursorAuthenticatedAccount {
    let token: String
    let account: CursorAccount
}

enum CursorAccountHistoryOrigin: Equatable {
    case missing
    case milliseconds(Int64)
    case invalid
}

struct CursorAccount: Decodable {
    let userId: Int
    let teamId: Int?
    let historyOrigin: CursorAccountHistoryOrigin

    private enum CodingKeys: String, CodingKey {
        case userId
        case teamId
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decodeFlexibleInt(forKey: .userId)
        teamId = try container.decodeFlexibleIntIfPresent(forKey: .teamId)
        do {
            if let milliseconds = try container.decodeCursorTimestampIfPresent(forKey: .createdAt) {
                historyOrigin = .milliseconds(milliseconds)
            } else {
                historyOrigin = .missing
            }
        } catch {
            historyOrigin = .invalid
        }
    }

    var syncIdentity: String {
        let value = "\(userId)|\(teamId.map(String.init) ?? "")"
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "cursor-account:\(digest)"
    }
}

final class CursorDashboardClient {
    private static let apiOrigin = URL(string: "https://api2.cursor.sh")!

    private let authenticationReader: CursorAuthenticationReading
    private let transport: CursorHTTPTransport

    init(
        authenticationReader: CursorAuthenticationReading = CursorStateAuthenticationReader(),
        transport: CursorHTTPTransport = CursorURLSessionTransport()
    ) {
        self.authenticationReader = authenticationReader
        self.transport = transport
    }

    func authenticatedAccount(
        cancellation: CursorOperationCancellation? = nil
    ) throws -> CursorAuthenticatedAccount {
        try checkCancellation(cancellation)
        let token = try authenticationReader.readAccessToken()
        let data = try perform(
            path: "/aiserver.v1.DashboardService/GetMe",
            token: token,
            body: [:],
            cancellation: cancellation
        )
        let account: CursorAccount
        do {
            account = try JSONDecoder().decode(CursorAccount.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
        return CursorAuthenticatedAccount(token: token, account: account)
    }

    func perform(
        path: String,
        token: String,
        body: [String: Any],
        cancellation: CursorOperationCancellation? = nil
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
                    cancellation?.isCursorCancelled == true
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
        guard data.count <= CursorDashboardLimits.maximumResponseBytes else {
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

    func checkCancellation(_ cancellation: CursorOperationCancellation?) throws {
        if cancellation?.isCursorCancelled == true {
            throw CursorUsageError.cancelled
        }
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        let value = try decode(String.self, forKey: key)
        guard let result = Double(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a floating-point number."
            )
        }
        return result
    }

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

    func decodeCursorTimestampIfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let numeric = try? decodeFlexibleInt64IfPresent(forKey: key) {
            guard numeric < 1_000_000_000_000 else { return numeric }
            let (milliseconds, overflow) = numeric.multipliedReportingOverflow(by: 1_000)
            guard !overflow else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: self,
                    debugDescription: "Cursor timestamp overflowed milliseconds."
                )
            }
            return milliseconds
        }
        let value = try decode(String.self, forKey: key)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        guard let date else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a Cursor timestamp."
            )
        }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
