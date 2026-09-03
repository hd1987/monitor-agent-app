import XCTest
@testable import MonitorAgent

final class CursorQuotaServiceTests: XCTestCase {
    func testRefreshUsesCurrentPeriodEndpointAndMapsMonthlyQuota() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Date(timeIntervalSince1970: 1_802_419_200)
        let account = try cursorAccount(userId: 42, teamId: 7)
        let resolver = CursorQuotaAccountResolver(
            authenticated: CursorAuthenticatedAccount(token: "cursor-token", account: account)
        )
        let transport = CursorQuotaTransport(
            data: pooledPeriodPayload(
                usedCents: 6_847,
                limitCents: 60_000,
                reset: reset
            )
        )
        let service = CursorQuotaService(
            accountSession: resolver,
            client: CursorDashboardClient(
                authenticationReader: CursorQuotaAuthenticationReader(),
                transport: transport
            )
        )
        let completed = expectation(description: "Cursor quota refresh completes")
        var result: QuotaRefreshResult?

        service.refresh(now: now) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(
            request.url?.path,
            "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
        XCTAssertEqual(
            try requestBody(request),
            ["includePooledUsage": true]
        )
        XCTAssertEqual(result?.identityDigest, account.syncIdentity)
        XCTAssertEqual(result?.snapshot.provider, .cursor)
        XCTAssertEqual(result?.snapshot.monthly?.usageAmount?.usedCents, 6_847)
        XCTAssertEqual(result?.snapshot.monthly?.usageAmount?.limitCents, 60_000)
        XCTAssertEqual(result?.snapshot.monthly?.resetsAt, reset)
        XCTAssertEqual(
            try XCTUnwrap(result?.snapshot.monthly?.remainingPercent),
            88.58833333333334,
            accuracy: 0.000_001
        )
    }

    func testParserRejectsMalformedAndExpiredQuota() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(30 * 24 * 60 * 60)
        let payloads = [
            currentPeriodPayload(usedCents: -1, limitCents: 1_000, reset: future),
            currentPeriodPayload(usedCents: 100, limitCents: 0, reset: future),
            currentPeriodPayload(usedCents: 100, limitCents: 1_000, reset: now),
            Data(#"{"billingCycleEnd":"1802592000000"}"#.utf8),
        ]

        for payload in payloads {
            XCTAssertThrowsError(try CursorQuotaService.parseSnapshot(data: payload, now: now)) {
                XCTAssertEqual($0 as? CursorUsageError, .invalidResponse)
            }
        }
    }

    func testCursorMonthlyQuotaUsesSharedPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try CursorQuotaService.parseSnapshot(
            data: currentPeriodPayload(
                usedCents: 6_847,
                limitCents: 60_000,
                reset: now.addingTimeInterval(28 * 24 * 60 * 60)
            ),
            now: now
        )

        let presentation = QuotaDetailsPresentation.make(
            provider: .cursor,
            snapshot: snapshot,
            refreshPhase: .idle,
            expirationDate: nil,
            now: now
        )
        let monthly = try XCTUnwrap(presentation.usageWindows.first)

        XCTAssertEqual(presentation.sections, [.usageLimits])
        XCTAssertEqual(monthly.label, "1m")
        XCTAssertEqual(monthly.cardValueText, "$68.47 / $600")
        XCTAssertEqual(monthly.detailsItemText, "1m • $68.47 / $600")
        XCTAssertEqual(monthly.countdownText, "28d")
        XCTAssertEqual(monthly.status, .healthy)
        XCTAssertEqual(
            monthly.accessibilityItemText,
            "1m limit, $68.47 used of $600, $531.53 remaining, 89% remaining"
        )
    }

    private func currentPeriodPayload(
        usedCents: Int,
        limitCents: Int,
        reset: Date
    ) -> Data {
        let resetMilliseconds = Int64(reset.timeIntervalSince1970 * 1_000)
        return Data(
            """
            {"billingCycleStart":"1799913600000","billingCycleEnd":"\(resetMilliseconds)","planUsage":{"totalSpend":\(usedCents),"includedSpend":\(usedCents),"limit":\(limitCents)}}
            """.utf8
        )
    }

    private func pooledPeriodPayload(
        usedCents: Int,
        limitCents: Int,
        reset: Date
    ) -> Data {
        let resetMilliseconds = Int64(reset.timeIntervalSince1970 * 1_000)
        return Data(
            """
            {"billingCycleStart":"1799913600000","billingCycleEnd":"\(resetMilliseconds)","planUsage":{"totalPercentUsed":12.5},"spendLimitUsage":{"pooledUsed":\(usedCents),"overallUsed":\(usedCents),"overallLimit":\(limitCents),"limitType":"pooled"}}
            """.utf8
        )
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Bool] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )
    }

    private func cursorAccount(userId: Int, teamId: Int) throws -> CursorAccount {
        try JSONDecoder().decode(
            CursorAccount.self,
            from: Data(#"{"userId":\#(userId),"teamId":\#(teamId)}"#.utf8)
        )
    }
}

private final class CursorQuotaAccountResolver: CursorAccountResolving {
    let authenticated: CursorAuthenticatedAccount

    init(authenticated: CursorAuthenticatedAccount) {
        self.authenticated = authenticated
    }

    func resolve(
        force: Bool,
        cancellation: CursorOperationCancellation?
    ) throws -> CursorAuthenticatedAccount {
        authenticated
    }
}

private struct CursorQuotaAuthenticationReader: CursorAuthenticationReading {
    func readAccessToken() throws -> String {
        "unused"
    }
}

private final class CursorQuotaTransport: CursorHTTPTransport {
    let data: Data
    private(set) var request: URLRequest?

    init(data: Data) {
        self.data = data
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
