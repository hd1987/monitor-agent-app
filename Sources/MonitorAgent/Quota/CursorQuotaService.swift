import Foundation

protocol CursorQuotaServicing: AnyObject {
    func refresh(
        now: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    )
    func resolveIdentityDigest(completion: @escaping (String?) -> Void)
}

final class CursorQuotaService: CursorQuotaServicing {
    private let accountSession: CursorAccountResolving
    private let client: CursorDashboardClient
    private let queue = DispatchQueue(label: "com.monitoragent.cursor-quota", qos: .utility)

    init(
        accountSession: CursorAccountResolving = CursorAccountSession.shared,
        client: CursorDashboardClient = CursorDashboardClient()
    ) {
        self.accountSession = accountSession
        self.client = client
    }

    func refresh(
        now: Date,
        completion: @escaping (QuotaRefreshResult) -> Void
    ) {
        queue.async {
            var identityDigest: String?
            let snapshot: QuotaSnapshot
            do {
                let authenticated = try self.accountSession.resolve(
                    force: true,
                    cancellation: nil
                )
                identityDigest = authenticated.account.syncIdentity
                let data = try self.client.perform(
                    path: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                    token: authenticated.token,
                    body: ["includePooledUsage": true]
                )
                snapshot = try Self.parseSnapshot(data: data, now: now)
            } catch CursorUsageError.authenticationUnavailable {
                snapshot = .failure(provider: .cursor, status: .signedOut, at: now)
            } catch CursorUsageError.authenticationRejected {
                snapshot = .failure(provider: .cursor, status: .authenticationExpired, at: now)
            } catch {
                snapshot = .failure(
                    provider: .cursor,
                    status: .unavailable("Quota service unavailable"),
                    at: now
                )
            }
            let result = QuotaRefreshResult(
                snapshot: snapshot,
                identityDigest: identityDigest
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    func resolveIdentityDigest(completion: @escaping (String?) -> Void) {
        queue.async {
            let identity = try? self.accountSession.resolve(
                force: false,
                cancellation: nil
            ).account.syncIdentity
            DispatchQueue.main.async { completion(identity) }
        }
    }

    static func parseSnapshot(data: Data, now: Date) throws -> QuotaSnapshot {
        let response: CursorCurrentPeriodUsageResponse
        do {
            response = try JSONDecoder().decode(CursorCurrentPeriodUsageResponse.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }
        guard let usageAmount = response.usageAmount,
              let billingCycleEnd = response.billingCycleEnd,
              billingCycleEnd > now else {
            throw CursorUsageError.invalidResponse
        }
        let usedRatio = min(
            1,
            Double(usageAmount.usedCents) / Double(usageAmount.limitCents)
        )
        return QuotaSnapshot(
            provider: .cursor,
            plan: nil,
            fiveHour: nil,
            weekly: nil,
            opusWeekly: nil,
            monthly: QuotaWindow(
                remainingPercent: (1 - usedRatio) * 100,
                resetsAt: billingCycleEnd,
                durationSeconds: nil,
                usageAmount: usageAmount
            ),
            resetCredits: nil,
            resetCreditExpirations: [],
            status: .available,
            fetchedAt: now
        )
    }
}

private struct CursorCurrentPeriodUsageResponse: Decodable {
    let billingCycleEnd: Date?
    let planUsage: CursorCurrentPeriodPlanUsage?
    let spendLimitUsage: CursorCurrentPeriodSpendLimitUsage?

    private enum CodingKeys: String, CodingKey {
        case billingCycleEnd
        case planUsage
        case spendLimitUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let milliseconds = try container.decodeCursorTimestampIfPresent(
            forKey: .billingCycleEnd
        ) {
            billingCycleEnd = Date(
                timeIntervalSince1970: TimeInterval(milliseconds) / 1_000
            )
        } else {
            billingCycleEnd = nil
        }
        planUsage = try container.decodeIfPresent(
            CursorCurrentPeriodPlanUsage.self,
            forKey: .planUsage
        )
        spendLimitUsage = try container.decodeIfPresent(
            CursorCurrentPeriodSpendLimitUsage.self,
            forKey: .spendLimitUsage
        )
    }

    var usageAmount: QuotaUsageAmount? {
        planUsage?.usageAmount ?? spendLimitUsage?.usageAmount
    }
}

private struct CursorCurrentPeriodPlanUsage: Decodable {
    let includedSpend: Int?
    let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case includedSpend
        case limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includedSpend = try container.decodeFlexibleIntIfPresent(forKey: .includedSpend)
        limit = try container.decodeFlexibleIntIfPresent(forKey: .limit)
    }

    var usageAmount: QuotaUsageAmount? {
        Self.makeUsageAmount(usedCents: includedSpend, limitCents: limit)
    }

    fileprivate static func makeUsageAmount(
        usedCents: Int?,
        limitCents: Int?
    ) -> QuotaUsageAmount? {
        let usedCents = usedCents ?? 0
        guard usedCents >= 0,
              let limitCents,
              limitCents > 0 else { return nil }
        return QuotaUsageAmount(
            usedCents: usedCents,
            limitCents: limitCents
        )
    }
}

private struct CursorCurrentPeriodSpendLimitUsage: Decodable {
    let overallUsed: Int?
    let overallLimit: Int?

    private enum CodingKeys: String, CodingKey {
        case overallUsed
        case overallLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overallUsed = try container.decodeFlexibleIntIfPresent(forKey: .overallUsed)
        overallLimit = try container.decodeFlexibleIntIfPresent(forKey: .overallLimit)
    }

    var usageAmount: QuotaUsageAmount? {
        CursorCurrentPeriodPlanUsage.makeUsageAmount(
            usedCents: overallUsed,
            limitCents: overallLimit
        )
    }
}
