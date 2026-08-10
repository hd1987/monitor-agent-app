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

struct CursorAuthenticatedAccount {
    let token: String
    let account: CursorAccount
}

struct CursorAccount: Decodable {
    let userId: Int
    let teamId: Int?
    let createdAtMilliseconds: Int64?

    private enum CodingKeys: String, CodingKey {
        case userId
        case teamId
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decodeFlexibleInt(forKey: .userId)
        teamId = try container.decodeFlexibleIntIfPresent(forKey: .teamId)
        createdAtMilliseconds = try? container.decodeCursorTimestampIfPresent(forKey: .createdAt)
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
    private static let maximumResponseBytes = 5 * 1_024 * 1_024

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
        cancellation: AgentSyncCancellation? = nil
    ) throws -> CursorAuthenticatedAccount {
        try checkCancellation(cancellation)
        let token = try authenticationReader.readAccessToken()
        let data = try perform(
            path: "/aiserver.v1.DashboardService/GetMe",
            token: token,
            body: [:],
            cancellation: cancellation
        )
        let account = try JSONDecoder().decode(CursorAccount.self, from: data)
        return CursorAuthenticatedAccount(token: token, account: account)
    }

    func perform(
        path: String,
        token: String,
        body: [String: Any],
        cancellation: AgentSyncCancellation? = nil
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

    func checkCancellation(_ cancellation: AgentSyncCancellation?) throws {
        if cancellation?.isEnabled(.cursor) == false {
            throw CursorUsageError.cancelled
        }
    }
}

extension KeyedDecodingContainer {
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
            return numeric >= 1_000_000_000_000 ? numeric : numeric * 1_000
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
