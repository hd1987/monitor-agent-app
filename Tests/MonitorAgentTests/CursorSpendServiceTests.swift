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

        _ = try service.refresh(range: range)
        _ = try service.refresh(range: range)
        XCTAssertEqual(transport.requestCount, 3)

        _ = try service.refresh(range: range, force: true)
        XCTAssertEqual(transport.requestCount, 6)
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

        let snapshot = try XCTUnwrap(service.refresh(range: range, force: true))

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

        XCTAssertNil(database.fetchCursorSpendSnapshot(range: range))
        XCTAssertTrue(database.fetchCursorSpendSnapshots(accountIdentity: firstIdentity).isEmpty)
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

private final class CursorSpendTransportStub: CursorHTTPTransport {
    private let lock = NSLock()
    var totalCents: Int
    var onDemandCents: Int
    var totalStatusCode = 200
    var onDemandStatusCode = 200
    private var requests: [URLRequest] = []

    init(totalCents: Int, onDemandCents: Int) {
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
                body: #"{"userId":42,"teamId":7,"createdAt":"1780000000000"}"#
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
            ? (cents == 0
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
