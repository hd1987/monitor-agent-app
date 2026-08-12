import Foundation
import XCTest
@testable import MonitorAgent

final class CursorSpendServiceTests: XCTestCase {
    func testRefreshUsesAllAndOnDemandAndStoresBothValues() throws {
        let database = DatabaseManager(inMemory: true)
        let identity = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 22_481, onDemandCents: 190)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let snapshot = try XCTUnwrap(service.refresh(range: range))

        XCTAssertEqual(snapshot.accountIdentity, identity)
        XCTAssertEqual(snapshot.totalCents, 22_481)
        XCTAssertEqual(snapshot.onDemandCents, 190)
        XCTAssertEqual(
            Set(transport.spendRequestBodies.compactMap { $0["spendType"] as? String }),
            ["SPEND_TYPE_ALL", "SPEND_TYPE_ON_DEMAND"]
        )
        XCTAssertTrue(transport.spendRequestBodies.allSatisfy {
            $0["groupBy"] as? String == "SPEND_GROUP_BY_CATEGORY_MODEL"
                && $0["periodStartMs"] as? String == range.startMilliseconds.map(String.init)
                && $0["periodEndMs"] as? String == range.endMilliseconds.map(String.init)
        })
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testFreshSnapshotAvoidsBothSpendRequestsUnlessForced() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 500, onDemandCents: 100)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let initialSnapshot = try XCTUnwrap(service.refresh(range: range))
        let outcome = service.refreshOutcome(
            range: range,
            force: false,
            cancellation: nil
        )
        XCTAssertEqual(outcome, .cacheHit(initialSnapshot))
        XCTAssertEqual(transport.requestCount, 4)

        _ = try service.refresh(range: range, force: true)
        XCTAssertEqual(transport.requestCount, 7)
    }

    func testFreshSnapshotCannotBypassChangedAccountVerification() throws {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = try seedCursorIdentity(database: database, userId: 42)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: firstIdentity,
            range: range,
            totalCents: 500,
            onDemandCents: 100,
            updatedAt: now
        )
        let transport = CursorSpendTransportStub(
            userId: 84,
            totalCents: 900,
            onDemandCents: 200
        )
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        XCTAssertThrowsError(try service.refresh(range: range)) { error in
            XCTAssertEqual(error as? CursorSpendError, .accountChanged)
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testNonemptyResponseMissingDailySpendDoesNotReplaceCachedValuesWithZeroes() throws {
        let database = DatabaseManager(inMemory: true)
        let identity = try seedCursorIdentity(database: database)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: identity,
            range: range,
            totalCents: 500,
            onDemandCents: 100,
            updatedAt: now.addingTimeInterval(-600)
        )
        let transport = CursorSpendTransportStub(totalCents: 0, onDemandCents: 0)
        transport.returnsMalformedMissingDailySpend = true
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let outcome = service.refreshOutcome(
            range: range,
            force: true,
            cancellation: nil
        )
        guard case .failure(let retainedSnapshot, let reason) = outcome else {
            return XCTFail("Expected retained-cache failure outcome")
        }
        let snapshot = try XCTUnwrap(retainedSnapshot)

        XCTAssertEqual(reason, .request)
        XCTAssertEqual(snapshot.totalCents, 500)
        XCTAssertEqual(snapshot.onDemandCents, 100)
    }

    func testStrictEmptyOnDemandResponseIsAuthoritativeZero() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 500, onDemandCents: 100)
        transport.onDemandReturnsStrictEmptyObject = true
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let outcome = service.refreshOutcome(
            range: range,
            force: true,
            cancellation: nil
        )
        guard case .success(let snapshot) = outcome else {
            return XCTFail("Expected strict empty object to be a successful zero")
        }
        XCTAssertEqual(snapshot.totalCents, 500)
        XCTAssertEqual(snapshot.onDemandCents, 0)
    }

    func testAuthenticationFailuresRemainTypedInSpendOutcome() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 500, onDemandCents: 100)
        transport.totalStatusCode = 401
        transport.onDemandStatusCode = 403
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let outcome = service.refreshOutcome(
            range: spendRange(now: now),
            force: true,
            cancellation: nil
        )
        XCTAssertEqual(outcome, .failure(nil, .authentication))
    }

    func testAuthenticationFailureTakesPrecedenceAcrossSpendScopes() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 500, onDemandCents: 100)
        transport.totalStatusCode = 500
        transport.onDemandStatusCode = 401
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let outcome = service.refreshOutcome(
            range: spendRange(now: now),
            force: true,
            cancellation: nil
        )
        XCTAssertEqual(outcome, .failure(nil, .authentication))
    }

    func testInvalidOnDemandValueDoesNotReplaceValidTotal() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 100, onDemandCents: 101)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let snapshot = try XCTUnwrap(service.refresh(range: spendRange(now: now)))

        XCTAssertEqual(snapshot.totalCents, 100)
        XCTAssertNil(snapshot.onDemandCents)
    }

    func testSuccessfulEmptyResponsesAreAuthoritativeZeroes() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 0, onDemandCents: 0)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )

        let snapshot = try XCTUnwrap(service.refresh(range: spendRange(now: now)))

        XCTAssertEqual(snapshot.totalCents, 0)
        XCTAssertEqual(snapshot.onDemandCents, 0)
    }

    func testSameRangePartialRefreshRetainsPreviousComponent() throws {
        let database = DatabaseManager(inMemory: true)
        _ = try seedCursorIdentity(database: database)
        let transport = CursorSpendTransportStub(totalCents: 500, onDemandCents: 100)
        let now = Date(timeIntervalSince1970: 1_785_470_400)
        let range = spendRange(now: now)
        let service = CursorSpendService(
            database: database,
            authenticationReader: CursorSpendAuthenticationStub(),
            transport: transport,
            now: { now }
        )
        _ = try service.refresh(range: range)
        transport.totalCents = 600
        transport.onDemandStatusCode = 500

        let outcome = service.refreshOutcome(
            range: range,
            force: true,
            cancellation: nil
        )
        guard case .partialFailure(let snapshot, let reason) = outcome else {
            return XCTFail("Expected partial failure outcome")
        }

        XCTAssertEqual(reason, .request)
        XCTAssertEqual(snapshot.totalCents, 600)
        XCTAssertEqual(snapshot.onDemandCents, 100)
    }

    func testChangedRangeDoesNotMergeAComponentFromPreviousDay() throws {
        let database = DatabaseManager(inMemory: true)
        let identity = try seedCursorIdentity(database: database)
        let firstRange = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let secondRange = CursorSpendRange(
            key: "today",
            startMilliseconds: 2_000,
            endMilliseconds: 3_000
        )
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: identity,
            range: firstRange,
            totalCents: 500,
            onDemandCents: 100,
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let snapshot = try XCTUnwrap(database.mergeCursorSpendSnapshot(
            accountIdentity: identity,
            range: secondRange,
            totalCents: 600,
            onDemandCents: nil,
            updatedAt: Date(timeIntervalSince1970: 20)
        ))

        XCTAssertEqual(snapshot.totalCents, 600)
        XCTAssertNil(snapshot.onDemandCents)
    }

    func testCursorAccountReplacementRemovesPreviousSpendSnapshots() throws {
        let database = DatabaseManager(inMemory: true)
        let firstIdentity = try seedCursorIdentity(database: database, userId: 42)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        _ = try database.mergeCursorSpendSnapshot(
            accountIdentity: firstIdentity,
            range: range,
            totalCents: 500,
            onDemandCents: 100,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let secondAccount = try account(userId: 84)
        let secondState = syncState(identity: secondAccount.syncIdentity)

        try database.replaceAppRecords(
            appType: AgentID.cursor.appType,
            records: [],
            state: secondState
        )

        XCTAssertNil(database.fetchCursorSpendSnapshot(
            accountIdentity: secondAccount.syncIdentity,
            range: range
        ))
        XCTAssertTrue(database.fetchCursorSpendSnapshots(accountIdentity: firstIdentity).isEmpty)
    }

    func testRefreshCoordinatorCoalescesMatchingActiveRequests() {
        let service = BlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let completed = expectation(description: "Matching refreshes complete")
        completed.expectedFulfillmentCount = 2

        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        service.releaseFirstRequest.signal()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(service.ranges, [range])
    }

    func testRefreshCoordinatorKeepsOnlyLatestPendingRequest() {
        let service = BlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let firstRange = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let supersededRange = CursorSpendRange(
            key: "last-7",
            startMilliseconds: 3_000,
            endMilliseconds: 4_000
        )
        let latestRange = CursorSpendRange(
            key: "last-30",
            startMilliseconds: 5_000,
            endMilliseconds: 6_000
        )
        let completed = expectation(description: "All refresh waiters complete")
        completed.expectedFulfillmentCount = 3

        coordinator.refresh(
            range: firstRange,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: supersededRange,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        coordinator.refresh(
            range: latestRange,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        service.releaseFirstRequest.signal()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(service.ranges, [firstRange, latestRange])
    }

    func testRefreshCoordinatorPreservesPendingManualRefresh() {
        let service = BlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let completed = expectation(description: "Automatic and manual refreshes complete")
        completed.expectedFulfillmentCount = 3

        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: true,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        service.releaseFirstRequest.signal()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(service.forces, [false, true])
    }

    func testRefreshCoordinatorPreservesManualForceAcrossCancellationDomains() {
        let service = BlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let manualCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let automaticCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let completed = expectation(description: "Cross-domain refreshes complete")
        completed.expectedFulfillmentCount = 3

        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: true,
            cancellation: manualCancellation
        ) { _ in
            completed.fulfill()
        }
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: automaticCancellation
        ) { _ in
            completed.fulfill()
        }
        service.releaseFirstRequest.signal()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(service.forces, [false, true])
    }

    func testManualCompletionWaitsForOwnedForcedRequest() {
        let service = TwoStageBlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let manualCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let automaticCancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        let firstCompleted = expectation(description: "First request completes")
        let manualCompleted = expectation(description: "Transferred manual request completes")
        let automaticCompleted = expectation(description: "Replacement automatic request completes")
        let manualProbe = CompletionProbe()

        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            firstCompleted.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: true,
            cancellation: manualCancellation
        ) { _ in
            manualProbe.markCompleted()
            manualCompleted.fulfill()
        }
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: automaticCancellation
        ) { _ in
            automaticCompleted.fulfill()
        }
        automaticCancellation.disableAgents(notIn: [])

        service.releaseFirstRequest.signal()
        wait(for: [firstCompleted, service.secondRequestStarted], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(manualProbe.isCompleted)

        service.releaseSecondRequest.signal()
        wait(for: [manualCompleted, automaticCompleted], timeout: 1)
        XCTAssertEqual(service.forces, [false, true])
        XCTAssertTrue(service.cancellations[1] === manualCancellation)
    }

    func testRefreshCoordinatorDoesNotCoalesceAcrossAccounts() {
        let service = BlockingCursorSpendServiceStub()
        let coordinator = CursorSpendRefreshCoordinator(service: service)
        let range = CursorSpendRange(
            key: "today",
            startMilliseconds: 1_000,
            endMilliseconds: 2_000
        )
        let completed = expectation(description: "Both account refreshes complete")
        completed.expectedFulfillmentCount = 2

        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-one",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        wait(for: [service.firstRequestStarted], timeout: 1)
        coordinator.refresh(
            range: range,
            expectedAccountIdentity: "account-two",
            force: false,
            cancellation: nil
        ) { _ in
            completed.fulfill()
        }
        service.releaseFirstRequest.signal()

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(service.ranges, [range, range])
    }

    private func seedCursorIdentity(
        database: DatabaseManager,
        userId: Int = 42
    ) throws -> String {
        let account = try account(userId: userId)
        try database.commitSync(records: [], state: syncState(identity: account.syncIdentity))
        return account.syncIdentity
    }

    private func account(userId: Int) throws -> CursorAccount {
        try JSONDecoder().decode(
            CursorAccount.self,
            from: Data(#"{"userId":\#(userId),"teamId":7,"createdAt":"1780000000000"}"#.utf8)
        )
    }

    private func syncState(identity: String) -> SyncState {
        SyncState(
            filePath: CursorUsageService.syncStateKey,
            byteOffset: 0,
            recordCount: 0,
            sessionId: identity,
            model: nil,
            lastModified: 0,
            lastSyncedAt: 0
        )
    }

    private func spendRange(now: Date) -> CursorSpendRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CursorSpendRange(timeRange: .today, now: now, calendar: calendar)
    }
}

private struct CursorSpendAuthenticationStub: CursorAuthenticationReading {
    func readAccessToken() throws -> String {
        "local-token"
    }
}

private final class BlockingCursorSpendServiceStub: CursorSpendServicing {
    let firstRequestStarted = XCTestExpectation(description: "First Cursor spend request started")
    let releaseFirstRequest = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRanges: [CursorSpendRange] = []
    private var storedForces: [Bool] = []

    var ranges: [CursorSpendRange] {
        lock.lock()
        defer { lock.unlock() }
        return storedRanges
    }

    var forces: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedForces
    }

    func refresh(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorSpendSnapshot? {
        lock.lock()
        storedRanges.append(range)
        storedForces.append(force)
        let isFirstRequest = storedRanges.count == 1
        lock.unlock()
        if isFirstRequest {
            firstRequestStarted.fulfill()
            _ = releaseFirstRequest.wait(timeout: .now() + 2)
        }
        return nil
    }
}

private final class TwoStageBlockingCursorSpendServiceStub: CursorSpendServicing {
    let firstRequestStarted = XCTestExpectation(description: "First request started")
    let secondRequestStarted = XCTestExpectation(description: "Second request started")
    let releaseFirstRequest = DispatchSemaphore(value: 0)
    let releaseSecondRequest = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedForces: [Bool] = []
    private var storedCancellations: [AgentSyncCancellation?] = []

    var forces: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedForces
    }

    var cancellations: [AgentSyncCancellation?] {
        lock.lock()
        defer { lock.unlock() }
        return storedCancellations
    }

    func refresh(
        range: CursorSpendRange,
        force: Bool,
        cancellation: AgentSyncCancellation?
    ) throws -> CursorSpendSnapshot? {
        lock.lock()
        storedForces.append(force)
        storedCancellations.append(cancellation)
        let requestIndex = storedForces.count
        lock.unlock()
        if requestIndex == 1 {
            firstRequestStarted.fulfill()
            _ = releaseFirstRequest.wait(timeout: .now() + 2)
        } else if requestIndex == 2 {
            secondRequestStarted.fulfill()
            _ = releaseSecondRequest.wait(timeout: .now() + 2)
        }
        return nil
    }
}

private final class CompletionProbe {
    private let lock = NSLock()
    private var storedIsCompleted = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsCompleted
    }

    func markCompleted() {
        lock.lock()
        storedIsCompleted = true
        lock.unlock()
    }
}

private final class CursorSpendTransportStub: CursorHTTPTransport {
    private let lock = NSLock()
    let userId: Int
    var totalCents: Int
    var onDemandCents: Int
    var totalStatusCode = 200
    var onDemandStatusCode = 200
    var returnsMalformedMissingDailySpend = false
    var onDemandReturnsStrictEmptyObject = false
    private var requests: [URLRequest] = []

    init(userId: Int = 42, totalCents: Int, onDemandCents: Int) {
        self.userId = userId
        self.totalCents = totalCents
        self.onDemandCents = onDemandCents
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var spendRequestBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap { request in
            guard request.url?.path.hasSuffix("GetDailySpendByCategory") == true,
                  let data = request.httpBody else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let totalCents = totalCents
        let onDemandCents = onDemandCents
        let totalStatusCode = totalStatusCode
        let onDemandStatusCode = onDemandStatusCode
        lock.unlock()

        if request.url?.path.hasSuffix("GetMe") == true {
            return response(
                request: request,
                statusCode: 200,
                body: #"{"userId":\#(userId),"teamId":7,"createdAt":"1780000000000"}"#
            )
        }
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let spendType = object["spendType"] as? String
        let isOnDemand = spendType == "SPEND_TYPE_ON_DEMAND"
        let cents = isOnDemand ? onDemandCents : totalCents
        let statusCode = isOnDemand ? onDemandStatusCode : totalStatusCode
        let responseBody = statusCode == 200
            ? (returnsMalformedMissingDailySpend
                ? #"{"categories":[]}"#
                : isOnDemand && onDemandReturnsStrictEmptyObject
                ? #"{}"#
                : cents == 0
                ? #"{"dailySpend":[],"categories":[]}"#
                : #"{"dailySpend":[{"day":"1785000000000","category":"model","spendCents":"\#(cents)"}]}"#)
            : "{}"
        return response(request: request, statusCode: statusCode, body: responseBody)
    }

    private func response(
        request: URLRequest,
        statusCode: Int,
        body: String
    ) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
