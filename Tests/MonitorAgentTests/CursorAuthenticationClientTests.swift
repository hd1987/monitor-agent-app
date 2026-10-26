import Foundation
import XCTest
@testable import MonitorAgent

final class CursorAuthenticationClientTests: XCTestCase {
    func testPollingUsesProofVerifierOnlyAtOfficialAPI() throws {
        let transport = AuthenticationHTTPStub(statuses: [404, 200], bodies: ["{}", #"{"accessToken":"access","refreshToken":"refresh"}"#])
        let client = CursorBrowserAuthenticationClient(transport: transport)
        let attempt = CursorBrowserLoginAttempt(verifier: "private-verifier")
        let cancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        XCTAssertNil(try client.poll(attempt, cancellation: cancellation))
        let pair = try XCTUnwrap(client.poll(attempt, cancellation: cancellation))
        XCTAssertEqual(pair.accessToken, "access")
        XCTAssertEqual(pair.refreshToken, "refresh")
        XCTAssertEqual(transport.requests[0].url?.host, "api2.cursor.sh")
        XCTAssertEqual(transport.requests[0].url?.path, "/auth/poll")
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(transport.requests[0].url!.query!.contains("verifier=private-verifier"))
    }

    func testPollingRejectsAuthenticationAndMalformedSuccess() {
        for (status, body) in [
            (403, "{}"), (500, "{}"), (200, "{}"),
            (200, #"{"accessToken":"access","refreshToken":""}"#),
            (200, #"{"accessToken":"access\r\ninjection","refreshToken":"refresh"}"#)
        ] {
            let client = CursorBrowserAuthenticationClient(transport: AuthenticationHTTPStub(statuses: [status], bodies: [body]))
            XCTAssertThrowsError(try client.poll(
                CursorBrowserLoginAttempt(), cancellation: AgentSyncCancellation(enabledAgents: [.cursor])
            ))
        }
    }

    func testPollingCancellationStopsBeforeSendingRequest() {
        let transport = AuthenticationHTTPStub(statuses: [], bodies: [])
        let client = CursorBrowserAuthenticationClient(transport: transport)
        let cancellation = AgentSyncCancellation(enabledAgents: [])
        XCTAssertThrowsError(try client.poll(CursorBrowserLoginAttempt(), cancellation: cancellation))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPollingPreservesSelectedTeamAndScopesGetMe() throws {
        let transport = AuthenticationHTTPStub(statuses: [200, 200], bodies: [
            #"{"accessToken":"access","refreshToken":"refresh","selectedTeamId":"7"}"#,
            #"{"userId":42,"teamId":7}"#
        ])
        let client = CursorBrowserAuthenticationClient(transport: transport)
        let pair = try XCTUnwrap(client.poll(CursorBrowserLoginAttempt(), cancellation: AgentSyncCancellation(enabledAgents: [.cursor])))
        XCTAssertEqual(pair.selectedTeamId, 7)
        let account = try client.account(pair.accessToken, selectedTeamId: pair.selectedTeamId, cancellation: nil)
        XCTAssertEqual(account.teamId, 7)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests[1].httpBody)) as? [String: Int])
        XCTAssertEqual(body, ["teamId": 7])
    }

    func testSelectedTeamVerificationRejectsDefaultTeamResponse() {
        let transport = AuthenticationHTTPStub(statuses: [200], bodies: [#"{"userId":42,"teamId":8}"#])
        let client = CursorBrowserAuthenticationClient(transport: transport)
        XCTAssertThrowsError(try client.account("access", selectedTeamId: 7, cancellation: nil)) { error in
            XCTAssertEqual(error as? CursorUsageError, .authenticationRejected)
        }
    }

    func testPollingRejectsMalformedOrNonpositiveSelectedTeam() {
        for value in ["0", "-1", "\"invalid\"", "true", "1.5"] {
            let transport = AuthenticationHTTPStub(statuses: [200], bodies: [
                "{\"accessToken\":\"access\",\"refreshToken\":\"refresh\",\"selectedTeamId\":\(value)}"
            ])
            let client = CursorBrowserAuthenticationClient(transport: transport)
            XCTAssertThrowsError(try client.poll(CursorBrowserLoginAttempt(), cancellation: AgentSyncCancellation(enabledAgents: [.cursor])))
        }
    }

    func testRefreshMatchesCursorProtocolAndUsesRotatedToken() throws {
        let transport = AuthenticationHTTPStub(statuses: [200], bodies: [#"{"access_token":"new-access"}"#])
        let pair = try CursorBrowserAuthenticationClient(transport: transport).refresh("old-refresh")
        XCTAssertEqual(pair.accessToken, "new-access")
        XCTAssertEqual(pair.refreshToken, "new-access")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api2.cursor.sh/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "old-refresh")
        XCTAssertNotNil(body["client_id"])
    }

    func testRefreshAcceptsSeparateRefreshTokenAndRejectsLogout() throws {
        let transport = AuthenticationHTTPStub(statuses: [200, 200], bodies: [
            #"{"access_token":"access","refresh_token":"refresh"}"#,
            #"{"shouldLogout":true,"error":"signed_out"}"#
        ])
        let client = CursorBrowserAuthenticationClient(transport: transport)
        XCTAssertEqual(try client.refresh("old").refreshToken, "refresh")
        XCTAssertThrowsError(try client.refresh("old")) { error in
            XCTAssertEqual(error as? CursorUsageError, .authenticationRejected)
        }
    }

    func testAccountVerificationUsesIndependentToken() throws {
        let transport = AuthenticationHTTPStub(statuses: [200], bodies: [#"{"userId":42}"#])
        let account = try CursorBrowserAuthenticationClient(transport: transport).account("independent-token", cancellation: nil)
        XCTAssertEqual(account.userId, 42)
        XCTAssertEqual(transport.requests[0].url?.path, "/aiserver.v1.DashboardService/GetMe")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer independent-token")
    }

    func testAccountResolutionDoesNotReuseCompletedDifferentSession() throws {
        let reader = RevisionedAuthenticationReader()
        let transport = AuthenticationHTTPStub(statuses: [200, 200], bodies: [#"{"userId":1}"#, #"{"userId":2}"#])
        let session = CursorAccountSession(authenticationReader: reader, transport: transport, normalReuseInterval: 100)
        XCTAssertEqual(try session.resolve().account.userId, 1)
        reader.changeSession()
        XCTAssertEqual(try session.resolve().account.userId, 2)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testAccountVerificationRejectsSessionChangeDuringRequest() {
        let reader = RevisionedAuthenticationReader()
        let transport = AuthenticationHTTPStub(statuses: [200], bodies: [#"{"userId":1}"#])
        transport.onSend = { reader.changeSession() }
        let client = CursorDashboardClient(authenticationReader: reader, transport: transport)
        XCTAssertThrowsError(try client.authenticatedAccount()) { error in
            XCTAssertEqual(error as? CursorUsageError, .cancelled)
        }
    }

    func testNewSessionWaiterDoesNotInheritPreviousInFlightAccount() {
        let reader = RevisionedAuthenticationReader()
        let transport = BlockingRevisionHTTPStub()
        let session = CursorAccountSession(authenticationReader: reader, transport: transport)
        let previousCompleted = expectation(description: "Previous session cancelled")
        let currentCompleted = expectation(description: "Current session resolved")
        DispatchQueue.global().async {
            do {
                _ = try session.resolve(force: true)
                XCTFail("A superseded session must not resolve an account")
            } catch {
                XCTAssertEqual(error as? CursorUsageError, .cancelled)
            }
            previousCompleted.fulfill()
        }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 1), .success)
        reader.changeSession()
        DispatchQueue.global().async {
            XCTAssertEqual(try? session.resolve(force: true).account.userId, 2)
            currentCompleted.fulfill()
        }
        transport.release.signal()
        wait(for: [previousCompleted, currentCompleted], timeout: 2)
    }
}

private final class BlockingRevisionHTTPStub: CursorHTTPTransport {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let isPrevious = request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0"
        if isPrevious {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        return (
            Data("{\"userId\":\(isPrevious ? 1 : 2)}".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private final class AuthenticationHTTPStub: CursorHTTPTransport {
    var requests: [URLRequest] = []
    var onSend: (() -> Void)?
    private var statuses: [Int]
    private var bodies: [String]

    init(statuses: [Int], bodies: [String]) {
        self.statuses = statuses
        self.bodies = bodies
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onSend?()
        guard !statuses.isEmpty, !bodies.isEmpty else { throw CursorUsageError.requestFailed }
        return (
            Data(bodies.removeFirst().utf8),
            HTTPURLResponse(url: request.url!, statusCode: statuses.removeFirst(), httpVersion: nil, headerFields: nil)!
        )
    }
}

private final class RevisionedAuthenticationReader: CursorAuthenticationReading {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    var authenticationRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }
    func changeSession() {
        lock.lock()
        revision += 1
        lock.unlock()
    }
    func readAccessToken() throws -> String { "token-\(authenticationRevision)" }
}
