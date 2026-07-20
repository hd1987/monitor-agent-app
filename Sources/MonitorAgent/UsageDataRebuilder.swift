import Foundation

enum UsageDataRebuildError: LocalizedError, Equatable {
    case validationFailed
    case noSourceFiles
    case suspiciousEmptyResult

    var errorDescription: String? {
        switch self {
        case .validationFailed:
            return "The rebuilt database failed validation."
        case .noSourceFiles:
            return "No source session files could be read. The existing database was not changed."
        case .suspiciousEmptyResult:
            return "The rebuilt database contained no usage requests. The existing database was not changed."
        }
    }
}

final class UsageDataRebuilder {
    private let activeDatabase: DatabaseManager
    private let temporaryDatabasePath: String
    private let claudeProjectsPath: String
    private let codexSessionsPath: String
    private let codexArchivedSessionsPath: String
    private let validateTemporaryDatabase: (DatabaseManager) -> Bool

    init(
        activeDatabase: DatabaseManager = .shared,
        temporaryDatabasePath: String? = nil,
        claudeProjectsPath: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsPath: String = NSHomeDirectory() + "/.codex/sessions",
        codexArchivedSessionsPath: String = NSHomeDirectory() + "/.codex/archived_sessions",
        validateTemporaryDatabase: @escaping (DatabaseManager) -> Bool = { $0.integrityCheck() }
    ) {
        self.activeDatabase = activeDatabase
        self.temporaryDatabasePath = temporaryDatabasePath
            ?? activeDatabase.ownedRebuildDatabasePath
            ?? ""
        self.claudeProjectsPath = claudeProjectsPath
        self.codexSessionsPath = codexSessionsPath
        self.codexArchivedSessionsPath = codexArchivedSessionsPath
        self.validateTemporaryDatabase = validateTemporaryDatabase
    }

    func rebuild(
        cancellation: UsageDataRebuildCancellation = UsageDataRebuildCancellation(),
        onProgress: ((SessionSyncProgress) -> Void)? = nil
    ) throws -> UsageDataRebuildSummary {
        let startedAt = Date()
        var temporaryDatabase: DatabaseManager?
        let usesPersistentTemporaryDatabase = activeDatabase.isPersistent

        do {
            if usesPersistentTemporaryDatabase {
                cleanUpTemporaryDatabase()
            }
            let rebuildDatabase = try usesPersistentTemporaryDatabase
                ? DatabaseManager(path: temporaryDatabasePath)
                : DatabaseManager()
            temporaryDatabase = rebuildDatabase

            let syncManager = SessionSyncManager(
                database: rebuildDatabase,
                claudeProjectsPath: claudeProjectsPath,
                codexSessionsPath: codexSessionsPath,
                codexArchivedSessionsPath: codexArchivedSessionsPath
            )
            onProgress?(phaseProgress(.scanning))
            let initialSnapshot = try syncManager.makeSourceSnapshot(cancellation: cancellation)

            let activeStats = activeDatabase.fetchStats(app: .all, range: .allTime)
            let activeDataMustBePreserved = activeStats.totalRequests > 0
                || (!activeDatabase.isAvailable && activeDatabase.hasExistingDatabaseFile)
            if initialSnapshot.files.isEmpty && activeDataMustBePreserved {
                throw UsageDataRebuildError.noSourceFiles
            }

            var syncResult = try syncManager.rebuild(
                snapshot: initialSnapshot,
                isCatchUp: false,
                cancellation: cancellation,
                onProgress: onProgress
            )

            try syncManager.validateSourcesRemainAppendCompatible(with: initialSnapshot)
            let catchUpSnapshot = try syncManager.makeSourceSnapshot(cancellation: cancellation)
            try syncManager.validateSourcesRemainAppendCompatible(with: initialSnapshot)
            let recordsBeforeCatchUp = syncResult.recordsSynced
            syncResult.add(try syncManager.rebuild(
                snapshot: catchUpSnapshot,
                isCatchUp: true,
                startingRecordsSynced: recordsBeforeCatchUp,
                cancellation: cancellation,
                onProgress: onProgress
            ))
            try syncManager.validateSourcesRemainAppendCompatible(with: initialSnapshot)
            try syncManager.validateSourcesRemainAppendCompatible(with: catchUpSnapshot)

            onProgress?(phaseProgress(.validating, recordsSynced: syncResult.recordsSynced))
            guard syncManager.validateSnapshotCoverage(catchUpSnapshot),
                  validateTemporaryDatabase(rebuildDatabase) else {
                throw UsageDataRebuildError.validationFailed
            }

            let stats = rebuildDatabase.fetchStats(app: .all, range: .allTime)
            if activeDataMustBePreserved && stats.totalRequests == 0 {
                throw UsageDataRebuildError.suspiciousEmptyResult
            }

            onProgress?(phaseProgress(.replacing, recordsSynced: syncResult.recordsSynced))
            if usesPersistentTemporaryDatabase {
                rebuildDatabase.close()
                temporaryDatabase = nil
                try activeDatabase.replaceDatabase(with: temporaryDatabasePath)
            } else {
                try activeDatabase.replaceDatabase(with: rebuildDatabase)
                rebuildDatabase.close()
                temporaryDatabase = nil
            }

            onProgress?(phaseProgress(.syncingLatest, recordsSynced: syncResult.recordsSynced))
            let latestSyncManager = SessionSyncManager(
                database: activeDatabase,
                claudeProjectsPath: claudeProjectsPath,
                codexSessionsPath: codexSessionsPath,
                codexArchivedSessionsPath: codexArchivedSessionsPath
            )
            var latestActivityPending = false
            var finalSourceFileCount = catchUpSnapshot.files.count
            do {
                let latestSnapshot = try latestSyncManager.makeSourceSnapshot()
                finalSourceFileCount = latestSnapshot.files.count
                _ = try latestSyncManager.rebuild(
                    snapshot: latestSnapshot,
                    isCatchUp: true,
                    cancellation: UsageDataRebuildCancellation()
                )
            } catch {
                latestActivityPending = true
            }
            let finalStats = activeDatabase.fetchStats(app: .all, range: .allTime)
            let claudeStats = activeDatabase.fetchStats(app: .claude, range: .allTime)
            let codexStats = activeDatabase.fetchStats(app: .codex, range: .allTime)
            return UsageDataRebuildSummary(
                filesSynced: finalSourceFileCount,
                recordsSynced: syncResult.recordsSynced,
                totalRequests: finalStats.totalRequests,
                totalSessions: finalStats.totalSessions,
                claudeRequests: claudeStats.totalRequests,
                codexRequests: codexStats.totalRequests,
                duration: Date().timeIntervalSince(startedAt),
                latestActivityPending: latestActivityPending
            )
        } catch {
            temporaryDatabase?.close()
            if usesPersistentTemporaryDatabase {
                cleanUpTemporaryDatabase()
            }
            throw error
        }
    }

    private func phaseProgress(
        _ phase: UsageDataRebuildPhase,
        recordsSynced: Int = 0
    ) -> SessionSyncProgress {
        SessionSyncProgress(
            completedFiles: 0,
            totalFiles: 0,
            recordsSynced: recordsSynced,
            phase: phase
        )
    }

    private func cleanUpTemporaryDatabase() {
        let fm = FileManager.default
        for candidate in [
            temporaryDatabasePath,
            "\(temporaryDatabasePath)-shm",
            "\(temporaryDatabasePath)-wal",
        ] where fm.fileExists(atPath: candidate) {
            try? fm.removeItem(atPath: candidate)
        }
    }
}
