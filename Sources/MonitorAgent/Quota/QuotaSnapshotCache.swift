import Foundation
import os

protocol QuotaSnapshotCaching: AnyObject {
    func load(
        provider: QuotaProviderID,
        identityDigest: String,
        now: Date,
        completion: @escaping (QuotaSnapshot?) -> Void
    )
    func store(_ snapshot: QuotaSnapshot, identityDigest: String)
}

struct QuotaCachePaths: Equatable {
    let file: String

    static var current: QuotaCachePaths {
        make(homeDirectory: NSHomeDirectory(), environment: .current)
    }

    static func make(
        homeDirectory: String,
        environment: DatabaseEnvironment
    ) -> QuotaCachePaths {
        let directory = switch environment {
        case .development: homeDirectory + "/.monitor-agent/development"
        case .production: homeDirectory + "/.monitor-agent"
        }
        return QuotaCachePaths(file: directory + "/quota-snapshots.json")
    }
}

final class QuotaSnapshotCache: QuotaSnapshotCaching {
    static let shared = QuotaSnapshotCache(path: QuotaCachePaths.current.file)

    private static let maximumFileSize = 65_536
    private static let logger = Logger(
        subsystem: DatabaseEnvironment.productionBundleIdentifier,
        category: "QuotaCache"
    )
    private let path: String
    private let queue = DispatchQueue(label: "com.monitoragent.quota-cache", qos: .utility)
    private var envelope: Envelope?

    init(path: String) {
        self.path = path
    }

    func load(
        provider: QuotaProviderID,
        identityDigest: String,
        now: Date,
        completion: @escaping (QuotaSnapshot?) -> Void
    ) {
        queue.async {
            let envelope = self.loadEnvelopeIfNeeded()
            let snapshot = envelope.records[provider.rawValue]
                .flatMap { record -> QuotaSnapshot? in
                    guard record.identityDigest == identityDigest else { return nil }
                    return record.validSnapshot(provider: provider, now: now)
                }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func store(_ snapshot: QuotaSnapshot, identityDigest: String) {
        guard snapshot.status == .available, !identityDigest.isEmpty else { return }
        queue.async {
            var envelope = self.loadEnvelopeIfNeeded()
            envelope.records[snapshot.provider.rawValue] = Record(
                identityDigest: identityDigest,
                snapshot: Snapshot(snapshot)
            )
            self.envelope = envelope
            self.persist(envelope)
        }
    }

    private func loadEnvelopeIfNeeded() -> Envelope {
        if let envelope { return envelope }
        let loaded: Envelope
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber,
           size.intValue <= Self.maximumFileSize,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(Envelope.self, from: data),
           decoded.schemaVersion == 1 {
            loaded = decoded
        } else {
            loaded = Envelope(schemaVersion: 1, records: [:])
        }
        envelope = loaded
        return loaded
    }

    private func persist(_ envelope: Envelope) {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            logPersistenceFailure(error)
            return
        }
        guard data.count <= Self.maximumFileSize else {
            Self.logger.error("Quota cache persistence rejected an oversized payload")
            return
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            logPersistenceFailure(error)
        }
    }

    private func logPersistenceFailure(_ error: Error) {
        let nsError = error as NSError
        Self.logger.error(
            "Quota cache persistence failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
        )
    }
}

private extension QuotaSnapshotCache {
    struct Envelope: Codable {
        let schemaVersion: Int
        var records: [String: Record]
    }

    struct Record: Codable {
        let identityDigest: String
        let snapshot: Snapshot

        func validSnapshot(provider: QuotaProviderID, now: Date) -> QuotaSnapshot? {
            guard snapshot.fetchedAt <= now.addingTimeInterval(5 * 60) else { return nil }
            let restored = snapshot.validSnapshot(provider: provider, now: now)
            guard restored.fiveHour != nil
                    || restored.weekly != nil
                    || restored.opusWeekly != nil
                    || (restored.resetCredits ?? 0) > 0 else {
                return nil
            }
            return restored
        }
    }

    struct Snapshot: Codable {
        let plan: String?
        let fiveHour: Window?
        let weekly: Window?
        let opusWeekly: Window?
        let resetCredits: Int?
        let resetCreditExpirations: [Date]
        let fetchedAt: Date

        init(_ snapshot: QuotaSnapshot) {
            plan = snapshot.plan
            fiveHour = snapshot.fiveHour.map(Window.init)
            weekly = snapshot.weekly.map(Window.init)
            opusWeekly = snapshot.opusWeekly.map(Window.init)
            resetCredits = snapshot.resetCredits
            resetCreditExpirations = snapshot.resetCreditExpirations
            fetchedAt = snapshot.fetchedAt
        }

        func validSnapshot(provider: QuotaProviderID, now: Date) -> QuotaSnapshot {
            let validFiveHour = fiveHour?.value(
                now: now,
                fallbackExpiration: fetchedAt.addingTimeInterval(5 * 60 * 60)
            )
            let validWeekly = weekly?.value(
                now: now,
                fallbackExpiration: fetchedAt.addingTimeInterval(7 * 24 * 60 * 60)
            )
            let validOpus = opusWeekly?.value(
                now: now,
                fallbackExpiration: fetchedAt.addingTimeInterval(7 * 24 * 60 * 60)
            )
            let resetCreditsState = ResetCreditsState.restored(
                count: resetCredits,
                expirations: resetCreditExpirations,
                now: now
            )
            return QuotaSnapshot(
                provider: provider,
                plan: plan,
                fiveHour: validFiveHour,
                weekly: validWeekly,
                opusWeekly: validOpus,
                resetCredits: resetCreditsState?.count,
                resetCreditExpirations: resetCreditsState?.expirations ?? [],
                status: .available,
                fetchedAt: fetchedAt
            )
        }
    }

    struct Window: Codable {
        let remainingPercent: Double
        let resetsAt: Date?
        let durationSeconds: Int?

        init(_ window: QuotaWindow) {
            remainingPercent = window.remainingPercent
            resetsAt = window.resetsAt
            durationSeconds = window.durationSeconds
        }

        func value(now: Date, fallbackExpiration: Date) -> QuotaWindow? {
            guard remainingPercent.isFinite,
                  (0...100).contains(remainingPercent),
                  (resetsAt ?? fallbackExpiration) > now else { return nil }
            return QuotaWindow(
                remainingPercent: remainingPercent,
                resetsAt: resetsAt,
                durationSeconds: durationSeconds
            )
        }
    }
}
