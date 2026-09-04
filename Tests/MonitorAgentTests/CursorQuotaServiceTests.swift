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

        XCTAssertEqual(presentation.sections, [.usageLimits, .usageAmounts])
        XCTAssertEqual(monthly.label, "1m")
        XCTAssertEqual(monthly.cardValueText, "89%")
        XCTAssertEqual(monthly.cardUsedAmountText, "$68.47")
        XCTAssertEqual(monthly.detailsItemText, "1m • 89%")
        let amountDetails = try XCTUnwrap(monthly.usageAmountDetails)
        XCTAssertEqual(amountDetails.periodText, "Monthly")
        XCTAssertEqual(amountDetails.usedText, "$68.47")
        XCTAssertEqual(amountDetails.limitText, "$600")
        XCTAssertEqual(
            amountDetails.balanceAccessibilityText,
            "$68.47 used of $600, $531.53 remaining"
        )
        XCTAssertEqual(monthly.countdownText, "28d")
        XCTAssertEqual(monthly.status, .healthy)
        XCTAssertEqual(
            monthly.accessibilityItemText,
            "1m limit, $68.47 used of $600, $531.53 remaining, 89% remaining"
        )
    }

    func testCursorMonthlyQuotaPreservesOverageAccessibility() {
        let amountDetails = QuotaUsageAmountPresentation(
            periodText: "Monthly",
            usageAmount: QuotaUsageAmount(usedCents: 62_000, limitCents: 60_000)
        )
        let presentation = QuotaWindowPresentation(
            label: "1m",
            remainingPercent: 0,
            usageAmountDetails: amountDetails,
            countdownText: "2d",
            absoluteResetText: "Oct 1, 10:07",
            status: .warning
        )

        XCTAssertEqual(presentation.cardValueText, "0%")
        XCTAssertEqual(presentation.cardUsedAmountText, "$620")
        XCTAssertEqual(presentation.usageAmountDetails, amountDetails)
        XCTAssertEqual(amountDetails.balanceAccessibilityText, "$620 used of $600, $20 over")
        XCTAssertEqual(
            presentation.accessibilityItemText,
            "1m limit, $620 used of $600, $20 over, 0% remaining"
        )
    }

    func testCursorMonthlyQuotaPresentsZeroAndFullyUsedAmounts() {
        let zeroAmountDetails = QuotaUsageAmountPresentation(
            periodText: "Monthly",
            usageAmount: QuotaUsageAmount(usedCents: 0, limitCents: 60_000)
        )
        let fullyUsedAmountDetails = QuotaUsageAmountPresentation(
            periodText: "Monthly",
            usageAmount: QuotaUsageAmount(usedCents: 60_000, limitCents: 60_000)
        )
        let zeroUsage = QuotaWindowPresentation(
            label: "1m",
            remainingPercent: 100,
            usageAmountDetails: zeroAmountDetails,
            countdownText: "28d",
            absoluteResetText: "Oct 1, 10:07",
            status: .healthy
        )
        let fullyUsed = QuotaWindowPresentation(
            label: "1m",
            remainingPercent: 0,
            usageAmountDetails: fullyUsedAmountDetails,
            countdownText: "28d",
            absoluteResetText: "Oct 1, 10:07",
            status: .healthy
        )

        XCTAssertEqual(zeroUsage.cardUsedAmountText, "$0")
        XCTAssertEqual(zeroUsage.usageAmountDetails, zeroAmountDetails)
        XCTAssertEqual(fullyUsed.cardUsedAmountText, "$600")
        XCTAssertEqual(fullyUsed.usageAmountDetails, fullyUsedAmountDetails)
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
