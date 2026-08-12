import Foundation

enum UsageDataRebuildError: LocalizedError, Equatable {
    case validationFailed
    case noSourceFiles
    case suspiciousEmptyResult
    case cursorRefreshFailed

    var errorDescription: String? {
        switch self {
        case .validationFailed:
            return "The rebuilt database failed validation."
        case .noSourceFiles:
            return "No source session files could be read. The existing database was not changed."
        case .suspiciousEmptyResult:
            return "The rebuilt database contained no usage requests. The existing database was not changed."
        case .cursorRefreshFailed:
            return "Cursor usage could not be refreshed, so the existing Cursor cache was preserved."
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
    private let cursorUsageServiceFactory: ((DatabaseManager) -> CursorUsageSyncing)?

    init(
        activeDatabase: DatabaseManager = .shared,
        temporaryDatabasePath: String = DatabaseManager.rebuildDatabasePath,
        claudeProjectsPath: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsPath: String = NSHomeDirectory() + "/.codex/sessions",
        codexArchivedSessionsPath: String = NSHomeDirectory() + "/.codex/archived_sessions",
        validateTemporaryDatabase: @escaping (DatabaseManager) -> Bool = { $0.integrityCheck() },
        cursorUsageServiceFactory: ((DatabaseManager) -> CursorUsageSyncing)? = nil
    ) {
        self.activeDatabase = activeDatabase
        self.temporaryDatabasePath = temporaryDatabasePath
        self.claudeProjectsPath = claudeProjectsPath
        self.codexSessionsPath = codexSessionsPath
        self.codexArchivedSessionsPath = codexArchivedSessionsPath
        self.validateTemporaryDatabase = validateTemporaryDatabase
        self.cursorUsageServiceFactory = cursorUsageServiceFactory
    }

    func rebuild(
        cancellation: UsageDataRebuildCancellation = UsageDataRebuildCancellation(),
        onProgress: ((SessionSyncProgress) -> Void)? = nil
    ) throws -> UsageDataRebuildSummary {
        let startedAt = Date()
        var temporaryDatabase: DatabaseManager?

        do {
            cleanUpTemporaryDatabase()
            let rebuildDatabase = try DatabaseManager(path: temporaryDatabasePath)
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
            let activeClaudeStats = activeDatabase.fetchStats(app: .claude, range: .allTime)
            let activeCodexStats = activeDatabase.fetchStats(app: .codex, range: .allTime)
            let activeCursorStats = activeDatabase.fetchStats(app: .cursor, range: .allTime)
            let activeCursorIdentity = activeDatabase.getSyncState(
                for: CursorUsageService.syncStateKey
            )?.sessionId
            let activeCursorSpendSnapshots = activeCursorIdentity.map {
                activeDatabase.fetchCursorSpendSnapshots(accountIdentity: $0)
            } ?? []
            let activeCursorDailySpendArchive = activeCursorIdentity.flatMap {
                activeDatabase.fetchCursorDailySpendArchive(accountIdentity: $0)
            }
            let activeDataMustBePreserved = activeStats.totalRequests > 0
                || (!activeDatabase.isAvailable && activeDatabase.hasExistingDatabaseFile)
            let localDataMustBePreserved =
                activeClaudeStats.totalRequests > 0 || activeCodexStats.totalRequests > 0
            if initialSnapshot.files.isEmpty
                && (localDataMustBePreserved
                    || (!activeDatabase.isAvailable && activeDatabase.hasExistingDatabaseFile)) {
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

            if let cursorUsageServiceFactory {
                do {
                    let cursorResult = try cursorUsageServiceFactory(rebuildDatabase).sync()
                    let rebuiltCursorStats = rebuildDatabase.fetchStats(app: .cursor, range: .allTime)
                    guard activeCursorStats.totalRequests == 0
                            || rebuiltCursorStats.totalRequests > 0 else {
                        throw UsageDataRebuildError.cursorRefreshFailed
                    }
                    if let rebuiltIdentity = rebuildDatabase.getSyncState(
                        for: CursorUsageService.syncStateKey
                    )?.sessionId,
                       rebuiltIdentity == activeCursorIdentity {
                        if let activeCursorDailySpendArchive {
                            try rebuildDatabase.restoreCursorDailySpendArchive(
                                activeCursorDailySpendArchive
                            )
                        }
                        try rebuildDatabase.restoreCursorSpendSnapshots(
                            activeCursorSpendSnapshots
                        )
                    }
                    syncResult.add(cursorResult)
                } catch let error as CursorUsageError
                    where activeCursorStats.totalRequests == 0
                        && activeCursorSpendSnapshots.isEmpty
                        && activeCursorDailySpendArchive == nil
                        && error.allowsRebuildWithoutCursorData {
                    // A missing Cursor session does not block rebuilding other sources.
                } catch let error as UsageDataRebuildError {
                    throw error
                } catch where activeCursorStats.totalRequests > 0
                    || !activeCursorSpendSnapshots.isEmpty
                    || activeCursorDailySpendArchive != nil {
                    throw UsageDataRebuildError.cursorRefreshFailed
                } catch {
                    throw error
                }
            }

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
            rebuildDatabase.close()
            temporaryDatabase = nil
            try activeDatabase.replaceDatabase(with: temporaryDatabasePath)

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
            let cursorStats = activeDatabase.fetchStats(app: .cursor, range: .allTime)
            return UsageDataRebuildSummary(
                filesSynced: finalSourceFileCount,
                recordsSynced: syncResult.recordsSynced,
                totalRequests: finalStats.totalRequests,
                totalSessions: finalStats.totalSessions,
                claudeRequests: claudeStats.totalRequests,
                codexRequests: codexStats.totalRequests,
                cursorRequests: cursorStats.totalRequests,
                duration: Date().timeIntervalSince(startedAt),
                latestActivityPending: latestActivityPending
            )
        } catch {
            temporaryDatabase?.close()
            cleanUpTemporaryDatabase()
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
