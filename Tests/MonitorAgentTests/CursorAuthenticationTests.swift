import Combine
import Darwin
import Foundation
import XCTest
@testable import MonitorAgent

final class CursorAuthenticationTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("cursor-auth.json") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testTokenValidationRejectsEnvelopeAndHeaderInjection() throws {
        let decoder = CursorStoredTokenDecoder()
        XCTAssertEqual(try decoder.decode("header.payload.signature"), "header.payload.signature")
        for value in ["", "token\r\ninjection", "two tokens", "cursor-safe-storage:v1:AAAA", "令牌"] {
            XCTAssertThrowsError(try decoder.decode(value))
        }
        XCTAssertThrowsError(try decoder.decode(String(repeating: "a", count: 16_385)))
    }

    func testOptionalJWTExpiryDecoding() throws {
        let decoder = CursorStoredTokenDecoder()
        let payload = Data(#"{"exp":1800000000}"#.utf8).base64EncodedString()
        XCTAssertEqual(decoder.expirationDate(for: "header.\(payload).signature"), now)
        XCTAssertNil(decoder.expirationDate(for: "opaque-token"))
        XCTAssertNil(decoder.expirationDate(for: "a.invalid.c"))
    }

    func testBrowserChallengeMatchesRFC7636() {
        let attempt = CursorBrowserLoginAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let query = URLComponents(url: attempt.loginURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "challenge" }?.value, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(attempt.loginURL.absoluteString.contains(attempt.verifier))
        XCTAssertEqual(attempt.loginURL.host, "cursor.com")
        XCTAssertEqual(attempt.pollURL.host, "api2.cursor.sh")
        XCTAssertEqual(CursorBrowserLoginAttempt().verifier.count, 43)
        XCTAssertNotEqual(CursorBrowserLoginAttempt().verifier, CursorBrowserLoginAttempt().verifier)
    }

    func testCredentialFileIsPrivateAtomicAndSurvivesRestart() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        XCTAssertNil(try store.snapshot().credentials)
        try store.replace(credentials())
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try CursorCredentialStore(fileURL: fileURL).snapshot().credentials, credentials())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cursor-auth.json"])
    }

    func testLogoutClearsPersistedCredentialsAndRejectsLateSave() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        let oldRevision = try store.snapshot().revision
        try store.replace(nil)
        XCTAssertFalse(try store.replace(credentials(), expectedRevision: oldRevision))
        XCTAssertNil(try CursorCredentialStore(fileURL: fileURL).snapshot().credentials)
        XCTAssertFalse(try String(contentsOf: fileURL).contains("saved-access"))
    }

    func testUnsafeOrMalformedCredentialFilesFailClosed() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertThrowsError(try CursorCredentialStore(fileURL: fileURL).snapshot())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try Data("invalid".utf8).write(to: fileURL)
        XCTAssertThrowsError(try CursorCredentialStore(fileURL: fileURL).snapshot())
        try Data(repeating: 65, count: 65_537).write(to: fileURL)
        XCTAssertThrowsError(try CursorCredentialStore(fileURL: fileURL).snapshot())
    }

    func testCredentialReaderRejectsSymlinks() throws {
        let target = directory.appendingPathComponent("other.json")
        let store = CursorCredentialStore(fileURL: target)
        try store.replace(credentials())
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try CursorCredentialStore(fileURL: fileURL).snapshot())
    }

    func testMissingIndependentCredentialsNeverStartsNetworkOrBrowser() throws {
        let api = AuthenticationAPIStub()
        api.refreshHandler = { _ in XCTFail("Missing sessions must fail locally"); throw CursorUsageError.requestFailed }
        let service = makeService(api: api)
        XCTAssertFalse(service.isSignedIn)
        XCTAssertThrowsError(try service.readAccessToken()) { error in
            XCTAssertEqual(error as? CursorUsageError, .authenticationUnavailable)
        }
    }

    func testFreshIndependentCredentialsDoNotRefresh() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        let service = makeService(store: store)
        XCTAssertEqual(try service.readAccessToken(), "saved-access")
        XCTAssertEqual(service.accountEmail, "test@example.com")
    }

    func testExpiredSessionRefreshesAndPersistsVerifiedIdentity() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials(expiresAt: now.addingTimeInterval(-1)))
        let api = AuthenticationAPIStub()
        let service = makeService(store: store, api: api)
        let revision = service.authenticationRevision
        XCTAssertEqual(try service.readAccessToken(), "new-access")
        XCTAssertEqual(service.authenticationRevision, revision)
        XCTAssertEqual(try store.snapshot().credentials?.accessToken, "new-access")
        XCTAssertEqual(try service.readAccessToken(), "new-access")
        XCTAssertEqual(api.refreshCount, 1)
    }

    func testSelectedTeamSurvivesRestartAndTokenRenewal() throws {
        let initialStore = CursorCredentialStore(fileURL: fileURL)
        try initialStore.replace(credentials(expiresAt: now.addingTimeInterval(-1), selectedTeamId: 7))
        let restartedStore = CursorCredentialStore(fileURL: fileURL)
        let api = AuthenticationAPIStub()
        api.accountHandler = { _ in try self.account(teamId: 7) }
        let service = makeService(store: restartedStore, api: api)
        XCTAssertEqual(service.selectedTeamId, 7)
        XCTAssertEqual(try service.readAccessToken(), "new-access")
        XCTAssertEqual(api.requestedTeamIds, [7])
        let saved = try XCTUnwrap(CursorCredentialStore(fileURL: fileURL).snapshot().credentials)
        XCTAssertEqual(saved.selectedTeamId, 7)
        XCTAssertEqual(saved.accountIdentity, try account(teamId: 7).syncIdentity)
    }

    func testBrowserLoginVerifiesAndSavesSelectedTeam() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        let api = AuthenticationAPIStub()
        api.pollHandler = { _, _ in CursorTokenPair(accessToken: "new-access", refreshToken: "new-refresh", selectedTeamId: 9) }
        api.accountHandler = { _ in try self.account(teamId: 9) }
        let service = makeService(store: store, api: api, openBrowser: { _ in true })
        let completed = expectation(description: "Selected-team login completed")
        let observer = service.$isSigningIn.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { observer.cancel() }
        service.signIn()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(api.requestedTeamIds, [9])
        XCTAssertEqual(try store.snapshot().credentials?.selectedTeamId, 9)
        XCTAssertEqual(try store.snapshot().credentials?.accountIdentity, try account(teamId: 9).syncIdentity)
    }

    func testBrowserSelectedTeamMismatchPreservesPreviousSession() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        let api = AuthenticationAPIStub()
        api.pollHandler = { _, _ in CursorTokenPair(accessToken: "new-access", refreshToken: "new-refresh", selectedTeamId: 7) }
        let service = makeService(store: store, api: api, openBrowser: { _ in true })
        let completed = expectation(description: "Mismatched team rejected")
        let observer = service.$isSigningIn.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { observer.cancel() }
        service.signIn()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(try store.snapshot().credentials, credentials())
        XCTAssertNotNil(service.errorMessage)
    }

    func testCredentialFileWithoutSelectedTeamRemainsReadable() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        var contents = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var session = try XCTUnwrap(contents["credentials"] as? [String: Any])
        session.removeValue(forKey: "selectedTeamId")
        contents["credentials"] = session
        try JSONSerialization.data(withJSONObject: contents).write(to: fileURL)
        let saved = try CursorCredentialStore(fileURL: fileURL).snapshot().credentials
        XCTAssertEqual(saved, credentials())
        XCTAssertNil(saved?.selectedTeamId)
    }

    func testRefreshFailureOrIdentityMismatchPreservesSavedCredentials() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        let saved = credentials(expiresAt: now.addingTimeInterval(-1))
        try store.replace(saved)
        let api = AuthenticationAPIStub()
        api.refreshHandler = { _ in throw CursorUsageError.requestFailed }
        let service = makeService(store: store, api: api)
        XCTAssertThrowsError(try service.readAccessToken())
        XCTAssertEqual(try store.snapshot().credentials, saved)
        api.refreshHandler = { _ in CursorTokenPair(accessToken: "new-access", refreshToken: "new-refresh") }
        api.accountHandler = { _ in try self.account(id: 99) }
        XCTAssertThrowsError(try service.readAccessToken())
        XCTAssertEqual(try store.snapshot().credentials, saved)
    }

    func testRefreshCannotRestoreSessionAfterLogout() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials(expiresAt: now.addingTimeInterval(-1)))
        let api = AuthenticationAPIStub()
        api.refreshHandler = { _ in
            try store.replace(nil)
            return CursorTokenPair(accessToken: "late-access", refreshToken: "late-refresh")
        }
        let service = makeService(store: store, api: api)
        XCTAssertThrowsError(try service.readAccessToken()) { error in
            XCTAssertEqual(error as? CursorUsageError, .cancelled)
        }
        XCTAssertNil(try store.snapshot().credentials)
    }

    func testLoginPersistsOnlyAfterAccountVerificationAndNotifiesOnce() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        let api = AuthenticationAPIStub()
        api.accountHandler = { _ in
            XCTAssertNil(try store.snapshot().credentials)
            return try self.account()
        }
        let center = NotificationCenter()
        let changed = expectation(description: "Verified session published")
        let observer = center.addObserver(forName: CursorCredentialStore.didChange, object: nil, queue: nil) { note in
            XCTAssertNotNil(note.userInfo?["identity"])
            changed.fulfill()
        }
        defer { center.removeObserver(observer) }
        var openedURL: URL?
        let service = makeService(store: store, api: api, center: center, openBrowser: { openedURL = $0; return true })
        service.signIn()
        XCTAssertTrue(service.isSigningIn)
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(openedURL?.host, "cursor.com")
        XCTAssertTrue(service.isSignedIn)
        XCTAssertEqual(try store.snapshot().credentials?.accessToken, "new-access")
        XCTAssertFalse(service.isSigningIn)
    }

    func testFailedLoginPreservesExistingSession() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        let api = AuthenticationAPIStub()
        api.accountHandler = { _ in throw CursorUsageError.authenticationRejected }
        let service = makeService(store: store, api: api, openBrowser: { _ in true })
        let completed = expectation(description: "Sign-in failure")
        let observer = service.$isSigningIn.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { observer.cancel() }
        service.signIn()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(try store.snapshot().credentials, credentials())
        XCTAssertNotNil(service.errorMessage)
    }

    func testCancelDiscardsLateBrowserSession() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        let api = AuthenticationAPIStub()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let polled = expectation(description: "Cancelled poll returned")
        api.pollHandler = { _, _ in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            polled.fulfill()
            return CursorTokenPair(accessToken: "late-access", refreshToken: "late-refresh")
        }
        let service = makeService(store: store, api: api, openBrowser: { _ in true })
        service.signIn()
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        service.cancelSignIn()
        release.signal()
        wait(for: [polled], timeout: 2)
        XCTAssertFalse(service.isSigningIn)
        XCTAssertNil(try store.snapshot().credentials)
    }

    func testPollingTimeoutReturnsToRetryableState() {
        let api = AuthenticationAPIStub()
        api.pollHandler = { _, _ in nil }
        let service = makeService(api: api, openBrowser: { _ in true })
        let completed = expectation(description: "Polling stopped")
        let observer = service.$isSigningIn.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { observer.cancel() }
        service.signIn()
        wait(for: [completed], timeout: 2)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(service.isSignedIn)
    }

    func testBrowserOpenFailureDoesNotStartPolling() {
        let api = AuthenticationAPIStub()
        api.pollHandler = { _, _ in XCTFail("Browser did not open"); return nil }
        let service = makeService(api: api)
        service.signIn()
        XCTAssertFalse(service.isSigningIn)
        XCTAssertNotNil(service.errorMessage)
    }

    func testSignOutUpdatesUIAndClearsFile() throws {
        let store = CursorCredentialStore(fileURL: fileURL)
        try store.replace(credentials())
        let service = makeService(store: store)
        service.signOut()
        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(service.accountEmail)
        XCTAssertNil(try CursorCredentialStore(fileURL: fileURL).snapshot().credentials)
        XCTAssertThrowsError(try service.readAccessToken())
    }

    private func makeService(
        store: CursorCredentialStore? = nil,
        api: AuthenticationAPIStub = AuthenticationAPIStub(),
        center: NotificationCenter = NotificationCenter(),
        openBrowser: @escaping (URL) -> Bool = { _ in false }
    ) -> CursorAuthenticationService {
        let service = CursorAuthenticationService(
            store: store ?? CursorCredentialStore(fileURL: fileURL), api: api,
            openBrowser: openBrowser, now: { self.now }, pollInterval: 0, maximumPolls: 2,
            notifications: center
        )
        service.loadSavedState()
        return service
    }

    private func account(id: Int = 42, teamId: Int? = nil) throws -> CursorAccount {
        var body: [String: Any] = ["userId": id, "email": "test@example.com"]
        if let teamId { body["teamId"] = teamId }
        return try JSONDecoder().decode(CursorAccount.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func credentials(expiresAt: Date? = nil, selectedTeamId: Int? = nil) -> CursorLoginCredentials {
        CursorLoginCredentials(
            accessToken: "saved-access", refreshToken: "saved-refresh",
            accountIdentity: try! account(teamId: selectedTeamId).syncIdentity, accountEmail: "test@example.com",
            expiresAt: expiresAt ?? now.addingTimeInterval(3_600), selectedTeamId: selectedTeamId
        )
    }
}

private final class AuthenticationAPIStub: CursorAuthenticationAPI {
    var pollHandler: (CursorBrowserLoginAttempt, CursorOperationCancellation) throws -> CursorTokenPair? = { _, _ in
        CursorTokenPair(accessToken: "new-access", refreshToken: "new-refresh")
    }
    var refreshHandler: (String) throws -> CursorTokenPair = { _ in
        CursorTokenPair(accessToken: "new-access", refreshToken: "new-refresh")
    }
    var accountHandler: (String) throws -> CursorAccount = { _ in
        try JSONDecoder().decode(CursorAccount.self, from: Data(#"{"userId":42,"email":"test@example.com"}"#.utf8))
    }
    private(set) var refreshCount = 0
    private(set) var requestedTeamIds: [Int?] = []

    func poll(_ attempt: CursorBrowserLoginAttempt, cancellation: CursorOperationCancellation) throws -> CursorTokenPair? {
        try pollHandler(attempt, cancellation)
    }
    func refresh(_ refreshToken: String) throws -> CursorTokenPair {
        refreshCount += 1
        return try refreshHandler(refreshToken)
    }
    func account(_ accessToken: String, selectedTeamId: Int?, cancellation: CursorOperationCancellation?) throws -> CursorAccount {
        requestedTeamIds.append(selectedTeamId)
        return try accountHandler(accessToken)
    }
}
