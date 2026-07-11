import Foundation
import Security

final class QuotaService {
    static let shared = QuotaService()
    static let minimumRefreshInterval: TimeInterval = 60

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.monitoragent.quota-service")
    private var lastAttempts: [QuotaProviderID: Date] = [:]
    private var inFlight = Set<QuotaProviderID>()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh(
        provider: QuotaProviderID,
        force: Bool = false,
        now: Date = Date(),
        completion: @escaping (QuotaSnapshot) -> Void
    ) {
        queue.async {
            if self.inFlight.contains(provider) { return }
            if !force,
               let lastAttempt = self.lastAttempts[provider],
               now.timeIntervalSince(lastAttempt) < Self.minimumRefreshInterval {
                return
            }
            self.lastAttempts[provider] = now
            self.inFlight.insert(provider)

            let finish: (QuotaSnapshot) -> Void = { snapshot in
                self.queue.async {
                    self.inFlight.remove(provider)
                    DispatchQueue.main.async { completion(snapshot) }
                }
            }

            guard QuotaEnvironmentDetector.isInstalled(provider) else {
                finish(.failure(provider: provider, status: .notInstalled, at: now))
                return
            }
            guard !QuotaEnvironmentDetector.usesThirdPartyAPI(provider) else {
                finish(.failure(provider: provider, status: .thirdPartyConfigured, at: now))
                return
            }

            switch provider {
            case .claude:
                self.fetchClaude(now: now, completion: finish)
            case .codex:
                self.fetchCodex(now: now, completion: finish)
            }
        }
    }

    private func fetchClaude(now: Date, completion: @escaping (QuotaSnapshot) -> Void) {
        guard let credentials = loadClaudeCredentials() else {
            completion(.failure(provider: .claude, status: .signedOut, at: now))
            return
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(.failure(provider: .claude, status: .unavailable("Quota service unavailable"), at: now))
                return
            }
            guard http.statusCode != 401 && http.statusCode != 403 else {
                completion(.failure(provider: .claude, status: .authenticationExpired, at: now))
                return
            }
            guard http.statusCode == 200, let data, data.count <= 1_048_576,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(provider: .claude, status: .unavailable("Quota service unavailable"), at: now))
                return
            }

            let fiveHour = Self.parseClaudeWindow(root["five_hour"])
            let weekly = Self.parseClaudeWindow(root["seven_day"])
            let opus = Self.parseClaudeWindow(root["seven_day_opus"])
            guard fiveHour != nil || weekly != nil else {
                completion(.failure(provider: .claude, status: .unavailable("Quota response unavailable"), at: now))
                return
            }
            completion(QuotaSnapshot(
                provider: .claude,
                plan: credentials.plan,
                fiveHour: fiveHour,
                weekly: weekly,
                opusWeekly: opus,
                resetCredits: nil,
                resetCreditExpirations: [],
                status: .available,
                fetchedAt: now
            ))
        }.resume()
    }

    private func fetchCodex(now: Date, completion: @escaping (QuotaSnapshot) -> Void) {
        guard let auth = loadCodexAuth() else {
            completion(.failure(provider: .codex, status: .signedOut, at: now))
            return
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var request = codexRequest(url: url, auth: auth)
        request.timeoutInterval = 10

        session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else {
                completion(.failure(provider: .codex, status: .unavailable("Quota service unavailable"), at: now))
                return
            }
            guard http.statusCode != 401 && http.statusCode != 403 else {
                completion(.failure(provider: .codex, status: .authenticationExpired, at: now))
                return
            }
            guard http.statusCode == 200, let data, data.count <= 1_048_576,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(provider: .codex, status: .unavailable("Quota service unavailable"), at: now))
                return
            }

            let rateLimit = (root["rate_limit"] as? [String: Any]) ?? root
            let fiveHour = Self.parseCodexWindow(
                rateLimit["primary_window"] ?? rateLimit["five_hour_window"]
            )
            let weekly = Self.parseCodexWindow(
                rateLimit["secondary_window"] ?? rateLimit["weekly_window"]
            )
            guard fiveHour != nil || weekly != nil else {
                completion(.failure(provider: .codex, status: .unavailable("Quota response unavailable"), at: now))
                return
            }

            let embeddedCredits = Self.parseResetCredits(root["rate_limit_reset_credits"])
            let base = QuotaSnapshot(
                provider: .codex,
                plan: (root["plan_type"] as? String)?.uppercased(),
                fiveHour: fiveHour,
                weekly: weekly,
                opusWeekly: nil,
                resetCredits: embeddedCredits.count,
                resetCreditExpirations: embeddedCredits.expirations,
                status: .available,
                fetchedAt: now
            )
            self.fetchCodexResetCredits(auth: auth, base: base, completion: completion)
        }.resume()
    }

    private func fetchCodexResetCredits(
        auth: CodexAuth,
        base: QuotaSnapshot,
        completion: @escaping (QuotaSnapshot) -> Void
    ) {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else {
            completion(base)
            return
        }
        var request = codexRequest(url: url, auth: auth)
        request.timeoutInterval = 10
        session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, data.count <= 1_048_576,
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                completion(base)
                return
            }
            let credits = Self.parseResetCredits(root)
            completion(QuotaSnapshot(
                provider: base.provider,
                plan: base.plan,
                fiveHour: base.fiveHour,
                weekly: base.weekly,
                opusWeekly: base.opusWeekly,
                resetCredits: credits.count ?? base.resetCredits,
                resetCreditExpirations: credits.expirations.isEmpty ? base.resetCreditExpirations : credits.expirations,
                status: base.status,
                fetchedAt: base.fetchedAt
            ))
        }.resume()
    }

    private func codexRequest(url: URL, auth: CodexAuth) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        if let accountID = auth.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }
}

private extension QuotaService {
    struct ClaudeCredentials {
        let accessToken: String
        let plan: String?
    }

    struct CodexAuth {
        let accessToken: String
        let accountID: String?
    }

    func loadClaudeCredentials() -> ClaudeCredentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path), let credentials = parseClaudeCredentials(data) {
            return credentials
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return parseClaudeCredentials(data)
    }

    func parseClaudeCredentials(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = (oauth["accessToken"] ?? oauth["access_token"]) as? String,
              !token.isEmpty else { return nil }
        let plan = (oauth["subscriptionType"] ?? oauth["subscription_type"]) as? String
        return ClaudeCredentials(accessToken: token, plan: plan?.uppercased())
    }

    func loadCodexAuth() -> CodexAuth? {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: custom)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        let path = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path), data.count <= 262_144,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = (root["tokens"] as? [String: Any]) ?? root
        guard let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              !token.isEmpty else { return nil }
        let directAccountID = (tokens["account_id"] ?? tokens["accountId"]) as? String
        return CodexAuth(accessToken: token, accountID: directAccountID ?? Self.accountID(fromJWT: token))
    }

    static func accountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["https://api.openai.com/auth.chatgpt_account_id"]
            ?? root["chatgpt_account_id"]) as? String
    }

    static func parseClaudeWindow(_ value: Any?) -> QuotaWindow? {
        guard let value = value as? [String: Any],
              let utilization = number(value["utilization"]) else { return nil }
        return QuotaWindow(
            remainingPercent: min(100, max(0, 100 - utilization)),
            resetsAt: parseDate(value["resets_at"] ?? value["resetsAt"])
        )
    }

    static func parseCodexWindow(_ value: Any?) -> QuotaWindow? {
        guard let value = value as? [String: Any] else { return nil }
        let remaining: Double?
        if let result = number(value["remaining_percent"] ?? value["remainingPercent"]) {
            remaining = result
        } else if let used = number(value["used_percent"] ?? value["usedPercent"] ?? value["utilization"]) {
            remaining = 100 - used
        } else {
            remaining = nil
        }
        guard let remaining else { return nil }
        return QuotaWindow(
            remainingPercent: min(100, max(0, remaining)),
            resetsAt: parseDate(value["reset_at"] ?? value["resetAt"] ?? value["resets_at"] ?? value["resetsAt"])
        )
    }

    static func parseResetCredits(_ value: Any?) -> (count: Int?, expirations: [Date]) {
        guard let value else { return (nil, []) }
        let dictionary = value as? [String: Any]
        let count = number(
            dictionary?["available_count"]
                ?? dictionary?["availableCount"]
                ?? dictionary?["remaining"]
                ?? dictionary?["count"]
        ).map(Int.init)
        var dates: [Date] = []
        collectDates(value, into: &dates)
        return (count, Array(Set(dates)).sorted())
    }

    static func collectDates(_ value: Any, into dates: inout [Date]) {
        if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                if key.lowercased().contains("expir"), let date = parseDate(item) {
                    dates.append(date)
                } else {
                    collectDates(item, into: &dates)
                }
            }
        } else if let array = value as? [Any] {
            array.forEach { collectDates($0, into: &dates) }
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
