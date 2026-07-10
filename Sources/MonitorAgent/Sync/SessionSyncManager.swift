import Foundation

/// Discovers and incrementally syncs Claude Code and Codex JSONL session logs
/// into the local database on a background timer.
final class SessionSyncManager {
    private let queue = DispatchQueue(label: "com.monitoragent.sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let db: DatabaseManager
    private let fm = FileManager.default
    private let claudeProjectsPath: String
    private let codexSessionsPath: String
    private let codexArchivedSessionsPath: String

    init(
        database: DatabaseManager = .shared,
        claudeProjectsPath: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsPath: String = NSHomeDirectory() + "/.codex/sessions",
        codexArchivedSessionsPath: String = NSHomeDirectory() + "/.codex/archived_sessions"
    ) {
        self.db = database
        self.claudeProjectsPath = claudeProjectsPath
        self.codexSessionsPath = codexSessionsPath
        self.codexArchivedSessionsPath = codexArchivedSessionsPath
    }

    /// Start periodic sync. `onComplete` fires on the sync queue after each cycle.
    func start(interval: TimeInterval = 30, onComplete: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            _ = self?.syncAll()
            onComplete()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Run a single sync cycle on the background queue, then call `onComplete`.
    func syncOnce(onComplete: @escaping () -> Void) {
        queue.async { [weak self] in
            _ = self?.syncAll()
            onComplete()
        }
    }

    func syncAllOnce(onProgress: ((SessionSyncProgress) -> Void)? = nil) -> SessionSyncResult {
        syncAll(onProgress: onProgress)
    }

    func performExclusive<T>(_ operation: () throws -> T) rethrows -> T {
        try queue.sync(execute: operation)
    }

    /// Restart the periodic timer with a new interval.
    func restart(interval: TimeInterval, onComplete: @escaping () -> Void) {
        stop()
        start(interval: interval, onComplete: onComplete)
    }

    // MARK: - Sync Cycle

    private func syncAll(onProgress: ((SessionSyncProgress) -> Void)? = nil) -> SessionSyncResult {
        let claudeFiles = discoverClaudeFiles()
        let codexFiles = discoverCodexFiles()
        let allFiles = claudeFiles.map { ($0, false) } + codexFiles.map { ($0, true) }
        let totalFiles = allFiles.count
        var result = SessionSyncResult()
        var completedFiles = 0

        onProgress?(SessionSyncProgress(
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            recordsSynced: result.recordsSynced
        ))

        for (path, isCodex) in allFiles {
            result.add(syncFile(path: path, isCodex: isCodex))
            completedFiles += 1
            onProgress?(SessionSyncProgress(
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                recordsSynced: result.recordsSynced
            ))
        }
        return result
    }

    // MARK: - File Discovery

    private func discoverClaudeFiles() -> [String] {
        findFiles(under: claudeProjectsPath, matching: { $0.hasSuffix(".jsonl") })
    }

    private func discoverCodexFiles() -> [String] {
        let a = findFiles(under: codexSessionsPath, matching: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") })
        let b = findFiles(under: codexArchivedSessionsPath, matching: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") })
        return a + b
    }

    private func findFiles(under directory: String, matching filter: (String) -> Bool) -> [String] {
        guard fm.fileExists(atPath: directory),
              let enumerator = fm.enumerator(atPath: directory) else { return [] }

        var results: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let filename = (relative as NSString).lastPathComponent
            if filter(filename) {
                results.append((directory as NSString).appendingPathComponent(relative))
            }
        }
        return results
    }

    // MARK: - Per-File Sync

    private func syncFile(path: String, isCodex: Bool) -> SessionSyncResult {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? Int64 else { return SessionSyncResult() }

        let fileMtime = Int(modDate.timeIntervalSince1970)
        let storedState = db.getSyncState(for: path)
        let existing: SyncState?
        if let storedState, storedState.byteOffset > fileSize {
            existing = nil
        } else {
            existing = storedState
        }

        // Skip if file unchanged and fully read
        if let s = existing, s.lastModified == fileMtime, s.byteOffset >= fileSize {
            return SessionSyncResult()
        }

        let offset = existing?.byteOffset ?? 0

        guard let handle = FileHandle(forReadingAtPath: path) else { return SessionSyncResult() }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return SessionSyncResult() }

        // Split by newline, keep only complete lines
        let newlineCode = UInt8(0x0A)
        var lineRanges: [Range<Data.Index>] = []
        var lineStart = data.startIndex
        for i in data.indices {
            if data[i] == newlineCode {
                let lineEnd = i
                if lineEnd > lineStart {
                    lineRanges.append(lineStart..<lineEnd)
                }
                lineStart = i + 1
            }
        }

        // Byte offset advances to after the last complete newline
        let bytesConsumed: Int64
        if let lastNewline = data.lastIndex(of: newlineCode) {
            bytesConsumed = Int64(lastNewline + 1)
        } else {
            // No complete line found
            return SessionSyncResult()
        }

        // Parse lines
        var records: [ParsedRecord] = []

        if isCodex {
            var context = CodexParseContext(syncState: existing)
            for range in lineRanges {
                let lineData = data.subdata(in: range)
                if let record = CodexLogParser.parse(lineData: lineData, context: &context) {
                    records.append(record)
                }
            }
            // Update sync state with context
            let state = SyncState(
                filePath: path,
                byteOffset: offset + bytesConsumed,
                recordCount: context.turnCount,
                sessionId: context.sessionId,
                model: context.currentModel,
                lastModified: fileMtime,
                lastSyncedAt: Int(Date().timeIntervalSince1970),
                lastTotalInputTokens: context.lastTotalIn,
                lastTotalOutputTokens: context.lastTotalOut
            )
            do {
                try db.commitSync(records: records, state: state)
            } catch {
                print("Failed to commit sync for \(path): \(error)")
                return SessionSyncResult()
            }
        } else {
            for range in lineRanges {
                let lineData = data.subdata(in: range)
                if let record = ClaudeLogParser.parse(lineData: lineData) {
                    records.append(record)
                }
            }
            let state = SyncState(
                filePath: path,
                byteOffset: offset + bytesConsumed,
                recordCount: (existing?.recordCount ?? 0) + records.count,
                sessionId: nil,
                model: nil,
                lastModified: fileMtime,
                lastSyncedAt: Int(Date().timeIntervalSince1970)
            )
            do {
                try db.commitSync(records: records, state: state)
            } catch {
                print("Failed to commit sync for \(path): \(error)")
                return SessionSyncResult()
            }
        }
        return SessionSyncResult(filesSynced: 1, recordsSynced: records.count)
    }
}
