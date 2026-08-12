import Foundation
import XCTest
@testable import MonitorAgent

final class CursorUsageServiceTests: XCTestCase {
    func testSyncMapsExactCursorUsageIntoExistingMetrics() throws {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":"42","teamId":7}"#),
            response(body: """
                {
                  "totalUsageEventsCount": 1,
                  "usageEventsDisplay": [{
                    "timestamp": "1785376800000",
                    "model": "claude-4.5-sonnet",
                    "kind": "USAGE_EVENT_KIND_INFERENCE",
                    "conversationId": "conversation-1",
                    "tokenUsage": {
                      "inputTokens": "100",
                      "outputTokens": "200",
                      "cacheReadTokens": "300",
                      "cacheWriteTokens": "400"
                    }
                  }]
                }
                """),
        ])
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "local-token"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_785_377_000) }
        )

        let result = try service.sync()
        let stats = database.fetchStats(app: .cursor, range: .allTime)

        XCTAssertEqual(result, SessionSyncResult(filesSynced: 1, recordsSynced: 1))
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.inputTokens, 100)
        XCTAssertEqual(stats.outputTokens, 200)
        XCTAssertEqual(stats.cacheReadTokens, 300)
        XCTAssertEqual(stats.cacheCreationTokens, 400)
        XCTAssertEqual(stats.totalTokens, 1_000)
        XCTAssertEqual(stats.cacheHitRate, 0.375, accuracy: 0.000_001)
        XCTAssertEqual(database.fetchModelDistribution(app: .cursor, range: .allTime).first?.model, "claude-4.5-sonnet")
        XCTAssertTrue(transport.requests.allSatisfy {
            $0.url?.scheme == "https"
                && $0.url?.host == "api2.cursor.sh"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer local-token"
        })
        XCTAssertEqual(
            transport.requests.map(\.url?.path),
            [
                "/aiserver.v1.DashboardService/GetMe",
                "/aiserver.v1.DashboardService/GetFilteredUsageEvents",
            ]
        )
    }

    func testSyncPaginatesAndUsesIncrementalOverlap() throws {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":42}"#),
            response(body: usagePage(total: 1, timestamp: "1785376800000", conversation: "initial")),
            response(body: #"{"userId":42}"#),
            response(body: usagePage(total: 2, timestamp: "1785376800000", conversation: "one")),
            response(body: usagePage(total: 2, timestamp: "1785376860000", conversation: "two")),
        ])
        var currentDate = Date(timeIntervalSince1970: 1_785_377_000)
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { currentDate }
        )

        _ = try service.sync()
        currentDate = Date(timeIntervalSince1970: 1_785_377_100)
        XCTAssertEqual(try service.sync().recordsSynced, 2)
        XCTAssertEqual(transport.requests.count, 5)

        let firstPageBody = try requestBody(transport.requests[3])
        let secondPageBody = try requestBody(transport.requests[4])
        XCTAssertEqual(firstPageBody["startDate"] as? String, "1785376940000")
        XCTAssertEqual(firstPageBody["page"] as? Int, 1)
        XCTAssertEqual(secondPageBody["page"] as? Int, 2)
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.byteOffset,
            1_785_377_100_000
        )
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.recordCount,
            2
        )
    }

    func testRepeatedEventIsDeduplicatedByStableRequestIdentifier() throws {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":42}"#),
            response(body: usagePage(total: 1, timestamp: "1785376800000", conversation: "same")),
            response(body: #"{"userId":42}"#),
            response(body: usagePage(total: 1, timestamp: "1785376800000", conversation: "same")),
        ])
        var currentDate = Date(timeIntervalSince1970: 1_785_377_000)
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { currentDate }
        )

        _ = try service.sync()
        currentDate = currentDate.addingTimeInterval(61)
        _ = try service.sync()

        XCTAssertEqual(database.fetchStats(app: .cursor, range: .allTime).totalRequests, 1)
    }

    func testAccountChangeReplacesCursorUsageWithFullFetch() throws {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":1,"teamId":10}"#),
            response(body: usagePage(
                total: 1,
                timestamp: "1785376800000",
                conversation: "account-one",
                model: "model-one"
            )),
            response(body: #"{"userId":2,"teamId":20}"#),
            response(body: usagePage(
                total: 1,
                timestamp: "1785376860000",
                conversation: "account-two",
                model: "model-two"
            )),
        ])
        var currentDate = Date(timeIntervalSince1970: 1_785_377_000)
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { currentDate }
        )

        _ = try service.sync()
        currentDate = currentDate.addingTimeInterval(10)
        _ = try service.sync()

        let stats = database.fetchStats(app: .cursor, range: .allTime)
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(
            database.fetchModelDistribution(app: .cursor, range: .allTime).map(\.model),
            ["model-two"]
        )
        XCTAssertNil(try requestBody(transport.requests[3])["startDate"])
    }

    func testSuccessfulEmptySyncAdvancesIncrementalWatermark() throws {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":42}"#),
            response(body: usagePage(total: 1, timestamp: "1785376800000", conversation: "initial")),
            response(body: #"{"userId":42}"#),
            response(body: #"{}"#),
            response(body: #"{"userId":42}"#),
            response(body: #"{}"#),
        ])
        var currentDate = Date(timeIntervalSince1970: 1_785_377_000)
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { currentDate }
        )

        _ = try service.sync()
        currentDate = Date(timeIntervalSince1970: 1_785_377_100)
        _ = try service.sync()
        currentDate = Date(timeIntervalSince1970: 1_785_377_200)
        _ = try service.sync()

        let thirdUsageBody = try requestBody(transport.requests[5])
        XCTAssertEqual(thirdUsageBody["startDate"] as? String, "1785377040000")
        XCTAssertEqual(
            database.getSyncState(for: CursorUsageService.syncStateKey)?.byteOffset,
            1_785_377_200_000
        )
    }

    func testNonemptyUsageResponseMissingRequiredFieldsStillFails() {
        let database = DatabaseManager(inMemory: true)
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":42}"#),
            response(body: #"{"metadata":{}}"#),
        ])
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_785_377_000) }
        )

        XCTAssertThrowsError(try service.sync())
        XCTAssertNil(database.getSyncState(for: CursorUsageService.syncStateKey))
    }

    func testAuthenticationFailurePreservesCachedCursorUsage() throws {
        let database = DatabaseManager(inMemory: true)
        database.insertRecords([ParsedRecord(
            requestId: "cursor:existing",
            appType: "cursor",
            model: "existing-model",
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheCreationTokens: 40,
            sessionId: "existing-session",
            createdAt: 1_785_376_000
        )])
        let transport = CursorTransportStub(responses: [
            response(statusCode: 401, body: "{}"),
        ])
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "expired"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_785_377_000) }
        )

        XCTAssertThrowsError(try service.sync()) { error in
            XCTAssertEqual(error as? CursorUsageError, .authenticationRejected)
        }
        XCTAssertEqual(database.fetchStats(app: .cursor, range: .allTime).totalRequests, 1)
        XCTAssertNil(database.getSyncState(for: CursorUsageService.syncStateKey))
    }

    func testCancellationStopsActiveRequestBeforeDatabaseCommit() {
        let database = DatabaseManager(inMemory: true)
        let transport = BlockingCancellableCursorTransport()
        let cancellation = AgentSyncCancellation(enabledAgents: Set(AgentID.allCases))
        let service = CursorUsageService(
            database: database,
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_785_377_000) }
        )
        let completed = expectation(description: "Cancelled Cursor sync completes")

        DispatchQueue.global().async {
            do {
                _ = try service.sync(cancellation: cancellation)
                XCTFail("Cursor sync should be cancelled")
            } catch {
                XCTAssertEqual(error as? CursorUsageError, .cancelled)
            }
            completed.fulfill()
        }
        wait(for: [transport.usageRequestStarted], timeout: 1)

        cancellation.disableAgents(notIn: [.claude, .codex])

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(database.fetchStats(app: .cursor, range: .allTime).totalRequests, 0)
        XCTAssertNil(database.getSyncState(for: CursorUsageService.syncStateKey))
    }

    func testAccountSessionCancellationDoesNotFailAnotherWaiter() {
        let transport = BlockingCursorAccountTransport()
        let waiterStarted = DispatchSemaphore(value: 0)
        let session = CursorAccountSession(
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport,
            onWaitForInFlight: { waiterStarted.signal() }
        )
        let firstCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let secondCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let firstCompleted = expectation(description: "Cancelled account waiter completes")
        let secondCompleted = expectation(description: "Independent account waiter completes")
        let resultLock = NSLock()
        var firstError: CursorUsageError?
        var secondIdentity: String?

        DispatchQueue.global().async {
            do {
                _ = try session.resolve(force: true, cancellation: firstCancellation)
            } catch {
                resultLock.lock()
                firstError = error as? CursorUsageError
                resultLock.unlock()
            }
            firstCompleted.fulfill()
        }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            let account = try? session.resolve(force: true, cancellation: secondCancellation)
            resultLock.lock()
            secondIdentity = account?.account.syncIdentity
            resultLock.unlock()
            secondCompleted.fulfill()
        }
        XCTAssertEqual(waiterStarted.wait(timeout: .now() + 1), .success)
        firstCancellation.disableAgents(notIn: [])
        transport.release.signal()

        wait(for: [firstCompleted, secondCompleted], timeout: 1)
        resultLock.lock()
        let capturedFirstError = firstError
        let capturedSecondIdentity = secondIdentity
        resultLock.unlock()
        XCTAssertEqual(capturedFirstError, .cancelled)
        XCTAssertNotNil(capturedSecondIdentity)
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testAccountSessionStarterCanCancelWithoutStoppingSharedRequest() {
        let transport = BlockingCursorAccountTransport()
        let session = CursorAccountSession(
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport
        )
        let cancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let starterCompleted = expectation(description: "Account request starter cancels promptly")
        let resultLock = NSLock()
        var starterError: CursorUsageError?

        DispatchQueue.global().async {
            do {
                _ = try session.resolve(force: true, cancellation: cancellation)
            } catch {
                resultLock.lock()
                starterError = error as? CursorUsageError
                resultLock.unlock()
            }
            starterCompleted.fulfill()
        }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)

        cancellation.disableAgents(notIn: [])
        wait(for: [starterCompleted], timeout: 0.5)
        resultLock.lock()
        let capturedError = starterError
        resultLock.unlock()
        XCTAssertEqual(capturedError, .cancelled)

        transport.release.signal()
    }

    func testForcedAccountResolutionDoesNotReuseCompletedResult() throws {
        let transport = CursorTransportStub(responses: [
            response(body: #"{"userId":1}"#),
            response(body: #"{"userId":2}"#),
        ])
        let session = CursorAccountSession(
            authenticationReader: CursorAuthenticationStub(token: "token"),
            transport: transport
        )

        let first = try session.resolve(force: true, cancellation: nil)
        let second = try session.resolve(force: true, cancellation: nil)

        XCTAssertNotEqual(first.account.syncIdentity, second.account.syncIdentity)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testURLSessionTransportRejectsResponseWhileStreamingPastLimit() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedCursorURLProtocol.self]
        ChunkedCursorURLProtocol.configure(chunks: [
            Data("123".utf8),
            Data("456".utf8),
        ])
        let transport = CursorURLSessionTransport(
            configuration: configuration,
            maximumResponseBytes: 5
        )
        let request = URLRequest(url: URL(string: "https://api2.cursor.sh/test")!)

        XCTAssertThrowsError(try transport.send(request)) { error in
            XCTAssertEqual(error as? CursorUsageError, .responseTooLarge)
        }
    }

    func testURLSessionTransportReleasesAfterRequestCompletes() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedCursorURLProtocol.self]
        ChunkedCursorURLProtocol.configure(chunks: [Data("ok".utf8)])
        var transport: CursorURLSessionTransport? = CursorURLSessionTransport(
            configuration: configuration,
            maximumResponseBytes: 5
        )
        weak let weakTransport = transport
        let request = URLRequest(url: URL(string: "https://api2.cursor.sh/test")!)

        let (data, _) = try XCTUnwrap(transport).send(request)
        XCTAssertEqual(data, Data("ok".utf8))
        transport = nil

        XCTAssertNil(weakTransport)
    }

    private func response(statusCode: Int = 200, body: String) -> CursorHTTPResponseStub {
        CursorHTTPResponseStub(statusCode: statusCode, data: Data(body.utf8))
    }

    private func usagePage(
        total: Int,
        timestamp: String,
        conversation: String,
        model: String = "cursor-model"
    ) -> String {
        """
        {
          "totalUsageEventsCount": \(total),
          "usageEventsDisplay": [{
            "timestamp": "\(timestamp)",
            "model": "\(model)",
            "conversationId": "\(conversation)",
            "tokenUsage": {
              "inputTokens": 1,
              "outputTokens": 2,
              "cacheReadTokens": 3,
              "cacheWriteTokens": 4
            }
          }]
        }
        """
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct CursorAuthenticationStub: CursorAuthenticationReading {
    let token: String

    func readAccessToken() throws -> String {
        token
    }
}

private final class ChunkedCursorURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var configuredChunks: [Data] = []

    static func configure(chunks: [Data]) {
        lock.lock()
        configuredChunks = chunks
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let chunks = Self.configuredChunks
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        chunks.forEach { client?.urlProtocol(self, didLoad: $0) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct CursorHTTPResponseStub {
    let statusCode: Int
    let data: Data
}

private final class CursorTransportStub: CursorHTTPTransport {
    private var responses: [CursorHTTPResponseStub]
    private(set) var requests: [URLRequest] = []

    init(responses: [CursorHTTPResponseStub]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CursorUsageError.requestFailed
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }
}

private final class BlockingCancellableCursorTransport: CancellableCursorHTTPTransport {
    let usageRequestStarted = XCTestExpectation(description: "Cursor usage request started")

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        XCTFail("CursorUsageService should use the cancellable transport path")
        throw CursorUsageError.requestFailed
    }

    func send(
        _ request: URLRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/aiserver.v1.DashboardService/GetMe" {
            return response(for: request, body: #"{"userId":42}"#)
        }

        usageRequestStarted.fulfill()
        while !isCancelled() {
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CursorUsageError.cancelled
    }

    private func response(
        for request: URLRequest,
        body: String
    ) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private final class BlockingCursorAccountTransport: CursorHTTPTransport {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRequestCount = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        storedRequestCount += 1
        lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 2)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#"{"userId":42}"#.utf8), response)
    }
}
