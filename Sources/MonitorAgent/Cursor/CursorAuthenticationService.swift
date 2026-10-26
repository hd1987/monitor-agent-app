import AppKit
import Combine
import CryptoKit
import Foundation

struct CursorBrowserLoginAttempt {
    let id: UUID
    let verifier: String

    init(id: UUID = UUID(), verifier: String? = nil) {
        self.id = id
        self.verifier = verifier ?? Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    var loginURL: URL {
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://cursor.com/loginDeepControl")!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: id.uuidString.lowercased()),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "supportsSelectedTeamLogin", value: "true")
        ]
        return components.url!
    }

    var pollURL: URL {
        var components = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: id.uuidString.lowercased()),
            URLQueryItem(name: "verifier", value: verifier)
        ]
        return components.url!
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct CursorTokenPair {
    let accessToken: String
    let refreshToken: String
    let selectedTeamId: Int?

    init(accessToken: String, refreshToken: String, selectedTeamId: Int? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.selectedTeamId = selectedTeamId
    }
}

protocol CursorAuthenticationAPI {
    func poll(_ attempt: CursorBrowserLoginAttempt, cancellation: CursorOperationCancellation) throws -> CursorTokenPair?
    func refresh(_ refreshToken: String) throws -> CursorTokenPair
    func account(_ accessToken: String, selectedTeamId: Int?, cancellation: CursorOperationCancellation?) throws -> CursorAccount
}

final class CursorBrowserAuthenticationClient: CursorAuthenticationAPI {
    private let transport: CursorHTTPTransport

    init(transport: CursorHTTPTransport = CursorURLSessionTransport()) {
        self.transport = transport
    }

    func poll(_ attempt: CursorBrowserLoginAttempt, cancellation: CursorOperationCancellation) throws -> CursorTokenPair? {
        let (data, response) = try send(URLRequest(url: attempt.pollURL), cancellation: cancellation)
        if response.statusCode == 404 { return nil }
        try validate(response)
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String
            let selectedTeamId: Int?

            private enum CodingKeys: String, CodingKey {
                case accessToken, refreshToken, selectedTeamId
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                accessToken = try container.decode(String.self, forKey: .accessToken)
                refreshToken = try container.decode(String.self, forKey: .refreshToken)
                selectedTeamId = try container.decodeFlexibleIntIfPresent(forKey: .selectedTeamId)
            }
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CursorUsageError.invalidResponse
        }
        return try validatedPair(result.accessToken, result.refreshToken, selectedTeamId: result.selectedTeamId)
    }

    func refresh(_ refreshToken: String) throws -> CursorTokenPair {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": refreshToken
        ])
        let (data, response) = try send(request, cancellation: nil)
        try validate(response)
        struct Response: Decodable {
            let access_token: String?
            let refresh_token: String?
            let shouldLogout: Bool?
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CursorUsageError.invalidResponse
        }
        if result.shouldLogout == true { throw CursorUsageError.authenticationRejected }
        guard let token = result.access_token else { throw CursorUsageError.invalidResponse }
        // Cursor's client uses the new access token for subsequent refreshes when no separate token is returned.
        return try validatedPair(token, result.refresh_token ?? token)
    }

    func account(
        _ accessToken: String, selectedTeamId: Int? = nil,
        cancellation: CursorOperationCancellation?
    ) throws -> CursorAccount {
        struct TokenReader: CursorAuthenticationReading {
            let token: String
            let selectedTeamId: Int?
            func readAccessToken() throws -> String { token }
        }
        return try CursorDashboardClient(
            authenticationReader: TokenReader(token: accessToken, selectedTeamId: selectedTeamId), transport: transport
        ).authenticatedAccount(cancellation: cancellation).account
    }

    private func validatedPair(
        _ accessToken: String, _ refreshToken: String, selectedTeamId: Int? = nil
    ) throws -> CursorTokenPair {
        guard selectedTeamId.map({ $0 > 0 }) ?? true else { throw CursorUsageError.invalidResponse }
        let decoder = CursorStoredTokenDecoder()
        return try CursorTokenPair(
            accessToken: decoder.decode(accessToken), refreshToken: decoder.decode(refreshToken),
            selectedTeamId: selectedTeamId
        )
    }

    private func send(
        _ request: URLRequest, cancellation: CursorOperationCancellation?
    ) throws -> (Data, HTTPURLResponse) {
        guard cancellation?.isCursorCancelled != true else { throw CursorUsageError.cancelled }
        let result: (Data, HTTPURLResponse)
        do {
            if let transport = transport as? CancellableCursorHTTPTransport {
                result = try transport.send(request) { cancellation?.isCursorCancelled == true }
            } else {
                result = try transport.send(request)
            }
        } catch let error as CursorUsageError { throw error }
        catch { throw CursorUsageError.requestFailed }
        guard cancellation?.isCursorCancelled != true else { throw CursorUsageError.cancelled }
        guard result.0.count <= 5 * 1_024 * 1_024 else { throw CursorUsageError.responseTooLarge }
        return result
    }

    private func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CursorUsageError.authenticationRejected
        }
        guard (200..<300).contains(response.statusCode) else { throw CursorUsageError.requestFailed }
    }
}

final class CursorAuthenticationService: ObservableObject, CursorAuthenticationReading {
    static let shared = CursorAuthenticationService()

    @Published private(set) var isSigningIn = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var errorMessage: String?

    private let store: CursorCredentialStore
    private let api: CursorAuthenticationAPI
    private let openBrowser: (URL) -> Bool
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let maximumPolls: Int
    private let notifications: NotificationCenter
    private let loginQueue = DispatchQueue(label: "com.monitoragent.cursor-browser-login", qos: .userInitiated)
    private let refreshLock = NSLock()
    private var loginCancellation: AgentSyncCancellation?
    private var loginGeneration = 0

    init(
        store: CursorCredentialStore = .shared,
        api: CursorAuthenticationAPI = CursorBrowserAuthenticationClient(),
        openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 2,
        maximumPolls: Int = 150,
        notifications: NotificationCenter = .default
    ) {
        self.store = store
        self.api = api
        self.openBrowser = openBrowser
        self.now = now
        self.pollInterval = pollInterval
        self.maximumPolls = maximumPolls
        self.notifications = notifications
    }

    var authenticationRevision: UInt64 { store.currentRevision }
    var selectedTeamId: Int? { (try? store.snapshot())?.credentials?.selectedTeamId }
    var savedAccountIdentity: String? { (try? store.snapshot())?.credentials?.accountIdentity }

    func readAccessToken() throws -> String {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        let snapshot = try store.snapshot()
        guard let saved = snapshot.credentials else { throw CursorUsageError.authenticationUnavailable }
        if saved.expiresAt.timeIntervalSince(now()) > 300 { return saved.accessToken }
        let tokens = try api.refresh(saved.refreshToken)
        let account = try api.account(tokens.accessToken, selectedTeamId: saved.selectedTeamId, cancellation: nil)
        guard account.syncIdentity == saved.accountIdentity else {
            throw CursorUsageError.authenticationRejected
        }
        let updated = try credentials(tokens, account: account, selectedTeamId: saved.selectedTeamId)
        guard try store.replace(updated, expectedRevision: snapshot.revision, isRefresh: true) else {
            throw CursorUsageError.cancelled
        }
        return updated.accessToken
    }

    func signIn() {
        guard !isSigningIn else { return }
        errorMessage = nil
        let attempt = CursorBrowserLoginAttempt()
        guard openBrowser(attempt.loginURL) else {
            errorMessage = "Could not open the Cursor sign-in page."
            return
        }
        loginGeneration += 1
        let generation = loginGeneration
        let revision = store.currentRevision
        let cancellation = AgentSyncCancellation(enabledAgents: [.cursor])
        loginCancellation = cancellation
        isSigningIn = true
        let loginDeadline = DispatchTime.now().uptimeNanoseconds + 300_000_000_000
        loginQueue.async { [weak self] in
            guard let self else { return }
            let result = Result<CursorLoginCredentials, Error> {
                for _ in 0..<self.maximumPolls {
                    if cancellation.isCursorCancelled { throw CursorUsageError.cancelled }
                    guard DispatchTime.now().uptimeNanoseconds < loginDeadline else {
                        throw CursorUsageError.requestFailed
                    }
                    if let tokens = try self.api.poll(attempt, cancellation: cancellation) {
                        let account = try self.api.account(
                            tokens.accessToken, selectedTeamId: tokens.selectedTeamId, cancellation: cancellation
                        )
                        return try self.credentials(tokens, account: account, selectedTeamId: tokens.selectedTeamId)
                    }
                    let deadline = Date().addingTimeInterval(self.pollInterval)
                    while Date() < deadline {
                        if cancellation.isCursorCancelled { throw CursorUsageError.cancelled }
                        Thread.sleep(forTimeInterval: min(0.1, self.pollInterval))
                    }
                }
                throw CursorUsageError.requestFailed
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loginGeneration == generation,
                      !cancellation.isCursorCancelled else { return }
                self.isSigningIn = false
                self.loginCancellation = nil
                do {
                    let saved = try result.get()
                    guard try self.store.replace(saved, expectedRevision: revision) else { return }
                    self.loadSavedState()
                    self.notifications.post(
                        name: CursorCredentialStore.didChange, object: self.store,
                        userInfo: ["identity": saved.accountIdentity]
                    )
                } catch {
                    self.errorMessage = "Cursor sign-in could not be completed. Try again."
                }
            }
        }
    }

    func cancelSignIn() {
        loginGeneration += 1
        loginCancellation?.disableAgents(notIn: [])
        loginCancellation = nil
        isSigningIn = false
        errorMessage = nil
    }

    func signOut() {
        cancelSignIn()
        do {
            try store.replace(nil)
            loadSavedState()
            notifications.post(name: CursorCredentialStore.didChange, object: store)
        } catch {
            errorMessage = "Could not clear the saved Cursor sign-in."
        }
    }

    func loadSavedState() {
        do {
            let saved = try store.snapshot().credentials
            isSignedIn = saved != nil
            accountEmail = saved?.accountEmail
        } catch {
            errorMessage = "Could not read the saved Cursor sign-in. Sign in again."
        }
    }

    private func credentials(
        _ tokens: CursorTokenPair, account: CursorAccount, selectedTeamId: Int?
    ) throws -> CursorLoginCredentials {
        let decoder = CursorStoredTokenDecoder()
        let accessToken = try decoder.decode(tokens.accessToken)
        let expiration = decoder.expirationDate(for: accessToken) ?? now().addingTimeInterval(3_600)
        guard expiration > now() else { throw CursorUsageError.authenticationRejected }
        if let selectedTeamId, account.teamId != selectedTeamId {
            throw CursorUsageError.authenticationRejected
        }
        let result = CursorLoginCredentials(
            accessToken: accessToken, refreshToken: try decoder.decode(tokens.refreshToken),
            accountIdentity: account.syncIdentity, accountEmail: account.email, expiresAt: expiration,
            selectedTeamId: selectedTeamId
        )
        try result.validate()
        return result
    }
}
