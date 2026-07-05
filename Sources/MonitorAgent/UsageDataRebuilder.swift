import Foundation

enum UsageDataRebuildError: LocalizedError {
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .validationFailed:
            return "The rebuilt database failed validation."
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
        temporaryDatabasePath: String = DatabaseManager.rebuildDatabasePath,
        claudeProjectsPath: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsPath: String = NSHomeDirectory() + "/.codex/sessions",
        codexArchivedSessionsPath: String = NSHomeDirectory() + "/.codex/archived_sessions",
        validateTemporaryDatabase: @escaping (DatabaseManager) -> Bool = { $0.integrityCheck() }
    ) {
        self.activeDatabase = activeDatabase
        self.temporaryDatabasePath = temporaryDatabasePath
        self.claudeProjectsPath = claudeProjectsPath
        self.codexSessionsPath = codexSessionsPath
        self.codexArchivedSessionsPath = codexArchivedSessionsPath
        self.validateTemporaryDatabase = validateTemporaryDatabase
    }

    func rebuild(onProgress: ((SessionSyncProgress) -> Void)? = nil) throws -> UsageDataRebuildSummary {
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
            let syncResult = syncManager.syncAllOnce(onProgress: onProgress)

            guard validateTemporaryDatabase(rebuildDatabase) else {
                throw UsageDataRebuildError.validationFailed
            }

            let stats = rebuildDatabase.fetchStats(app: .all, range: .allTime)
            let summary = UsageDataRebuildSummary(
                filesSynced: syncResult.filesSynced,
                recordsSynced: syncResult.recordsSynced,
                totalRequests: stats.totalRequests,
                totalSessions: stats.totalSessions
            )

            rebuildDatabase.close()
            temporaryDatabase = nil
            try activeDatabase.replaceDatabase(with: temporaryDatabasePath)
            return summary
        } catch {
            temporaryDatabase?.close()
            cleanUpTemporaryDatabase()
            try? activeDatabase.reopen()
            throw error
        }
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
