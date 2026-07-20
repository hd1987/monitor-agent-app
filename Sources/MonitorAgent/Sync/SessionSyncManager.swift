import Foundation

enum SessionLogSource: String, Equatable {
    case claude = "Claude Code"
    case codex = "Codex"
}

struct SessionSourceFileSnapshot: Equatable {
    let path: String
    let source: SessionLogSource
    let byteCount: Int64
    let fileIdentity: String
    let modifiedAt: Int
}

struct SessionSourceSnapshot: Equatable {
    let files: [SessionSourceFileSnapshot]

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }
}

enum StrictSessionSyncError: LocalizedError, Equatable {
    case cancelled
    case sourceDirectoryUnreadable(String)
    case sourceFileUnavailable(String)
    case sourceFileChanged(String)
    case sourceReadFailed(String)
    case databaseWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The rebuild was canceled. Your existing usage data was not changed."
        case .sourceDirectoryUnreadable(let path):
            return "The session log directory could not be read: \(Self.displayPath(path))."
        case .sourceFileUnavailable(let path):
            return "A session log became unavailable during the rebuild: \(Self.displayPath(path))."
        case .sourceFileChanged(let path):
            return "A session log was replaced or truncated during the rebuild: \(Self.displayPath(path))."
        case .sourceReadFailed(let path):
            return "A session log could not be read: \(Self.displayPath(path))."
        case .databaseWriteFailed(let path):
            return "Rebuilt data from a session log could not be saved: \(Self.displayPath(path))."
        }
    }

    private static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

enum SessionLogLineFilter {
    private static let assistantMarker = Data("assistant".utf8)
    private static let usageMarker = Data("usage".utf8)
    private static let sessionMetaMarker = Data("session_meta".utf8)
    private static let turnContextMarker = Data("turn_context".utf8)
    private static let tokenCountMarker = Data("token_count".utf8)

    static func shouldParseClaude(
        _ data: Data,
        in range: Range<Data.Index>? = nil
    ) -> Bool {
        let searchRange = range ?? data.startIndex..<data.endIndex
        return contains(assistantMarker, in: data, range: searchRange)
            && contains(usageMarker, in: data, range: searchRange)
    }

    static func shouldParseCodex(
        _ data: Data,
        in range: Range<Data.Index>? = nil
    ) -> Bool {
        let searchRange = range ?? data.startIndex..<data.endIndex
        return contains(sessionMetaMarker, in: data, range: searchRange)
            || contains(turnContextMarker, in: data, range: searchRange)
            || contains(tokenCountMarker, in: data, range: searchRange)
    }

    private static func contains(
        _ marker: Data,
        in data: Data,
        range: Range<Data.Index>
    ) -> Bool {
        data.range(of: marker, options: [], in: range) != nil
    }
}

/// Discovers and incrementally syncs Claude Code and Codex JSONL session logs
/// into the local database on a background timer.
final class SessionSyncManager {
    private static let rebuildReadChunkSize = 1_048_576
    private static let rebuildRecordBatchSize = 10_000
    private static let newlineDelimiter = Data([UInt8(0x0A)])
    private let queue = DispatchQueue(label: "com.monitoragent.sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let db: DatabaseManager
    private let fm = FileManager.default
    private let claudeProjectsPath: String
    private let codexSessionsPath: String
    private let codexArchivedSessionsPath: String
    private(set) var isRunning = false

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
        isRunning = true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
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

    func makeSourceSnapshot(
        cancellation: UsageDataRebuildCancellation? = nil
    ) throws -> SessionSourceSnapshot {
        try checkCancellation(cancellation)
        let claudeFiles = try discoverFilesStrict(
            under: claudeProjectsPath,
            source: .claude,
            matching: { $0.hasSuffix(".jsonl") }
        )
        try checkCancellation(cancellation)
        let codexFiles = try discoverFilesStrict(
            under: codexSessionsPath,
            source: .codex,
            matching: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
        ) + discoverFilesStrict(
            under: codexArchivedSessionsPath,
            source: .codex,
            matching: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
        )
        return SessionSourceSnapshot(files: claudeFiles + codexFiles)
    }

    func validateSourcesRemainAppendCompatible(with snapshot: SessionSourceSnapshot) throws {
        for file in snapshot.files {
            let current = try currentSnapshot(for: file.path, source: file.source)
            guard current.fileIdentity == file.fileIdentity,
                  current.byteCount >= file.byteCount else {
                throw StrictSessionSyncError.sourceFileChanged(file.path)
            }
        }
    }

    func validateSnapshotCoverage(_ snapshot: SessionSourceSnapshot) -> Bool {
        snapshot.files.allSatisfy { file in
            guard let state = db.getSyncState(for: file.path) else { return false }
            return state.byteOffset >= 0 && state.byteOffset <= file.byteCount
        }
    }

    func rebuild(
        snapshot: SessionSourceSnapshot,
        isCatchUp: Bool,
        startingRecordsSynced: Int = 0,
        cancellation: UsageDataRebuildCancellation,
        onProgress: ((SessionSyncProgress) -> Void)? = nil
    ) throws -> SessionSyncResult {
        var work: [(file: SessionSourceFileSnapshot, offset: Int64)] = []
        for file in snapshot.files {
            let offset = db.getSyncState(for: file.path)?.byteOffset ?? 0
            guard offset <= file.byteCount else {
                throw StrictSessionSyncError.sourceFileChanged(file.path)
            }
            if db.getSyncState(for: file.path) == nil || offset < file.byteCount {
                work.append((file, offset))
            }
        }

        let totalBytes = work.reduce(Int64(0)) { $0 + max($1.file.byteCount - $1.offset, 0) }
        var processedBytes: Int64 = 0
        var completedFiles = 0
        var result = SessionSyncResult()
        onProgress?(strictProgress(
            file: work.first?.file,
            isCatchUp: isCatchUp,
            completedFiles: completedFiles,
            totalFiles: work.count,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            recordsSynced: startingRecordsSynced + result.recordsSynced
        ))

        for item in work {
            try checkCancellation(cancellation)
            let fileResult = try rebuildFile(
                item.file,
                startingAt: item.offset,
                cancellation: cancellation,
                onBytesProcessed: { bytes, records in
                    processedBytes += bytes
                    onProgress?(self.strictProgress(
                        file: item.file,
                        isCatchUp: isCatchUp,
                        completedFiles: completedFiles,
                        totalFiles: work.count,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        recordsSynced: startingRecordsSynced + result.recordsSynced + records
                    ))
                }
            )
            result.add(fileResult)
            completedFiles += 1
            onProgress?(strictProgress(
                file: item.file,
                isCatchUp: isCatchUp,
                completedFiles: completedFiles,
                totalFiles: work.count,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                recordsSynced: startingRecordsSynced + result.recordsSynced
            ))
        }
        return result
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

    private func discoverFilesStrict(
        under directory: String,
        source: SessionLogSource,
        matching filter: (String) -> Bool
    ) throws -> [SessionSourceFileSnapshot] {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else {
            throw StrictSessionSyncError.sourceDirectoryUnreadable(directory)
        }

        var enumerationError: Error?
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw StrictSessionSyncError.sourceDirectoryUnreadable(directory)
        }

        var results: [SessionSourceFileSnapshot] = []
        for case let url as URL in enumerator {
            guard filter(url.lastPathComponent) else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                results.append(try currentSnapshot(for: url.path, source: source))
            } catch let error as StrictSessionSyncError {
                throw error
            } catch {
                throw StrictSessionSyncError.sourceFileUnavailable(url.path)
            }
        }
        if enumerationError != nil {
            throw StrictSessionSyncError.sourceDirectoryUnreadable(directory)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func currentSnapshot(
        for path: String,
        source: SessionLogSource
    ) throws -> SessionSourceFileSnapshot {
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw StrictSessionSyncError.sourceFileUnavailable(path)
        }
        return SessionSourceFileSnapshot(
            path: path,
            source: source,
            byteCount: size,
            fileIdentity: "\(systemNumber):\(fileNumber)",
            modifiedAt: Int(modifiedAt.timeIntervalSince1970)
        )
    }

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

    private func rebuildFile(
        _ file: SessionSourceFileSnapshot,
        startingAt offset: Int64,
        cancellation: UsageDataRebuildCancellation,
        onBytesProcessed: (Int64, Int) -> Void
    ) throws -> SessionSyncResult {
        let initial = try currentSnapshot(for: file.path, source: file.source)
        guard initial.fileIdentity == file.fileIdentity,
              initial.byteCount >= file.byteCount else {
            throw StrictSessionSyncError.sourceFileChanged(file.path)
        }

        let existing = db.getSyncState(for: file.path)
        var codexContext = CodexParseContext(syncState: existing)
        var claudeRecordCount = existing?.recordCount ?? 0
        var parsedRecordCount = 0
        var pending = Data()
        var searchedByteCount = 0
        var batch: [ParsedRecord] = []
        var bytesRead: Int64 = 0
        var remaining = file.byteCount - offset

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            throw StrictSessionSyncError.sourceReadFailed(file.path)
        }
        defer { try? handle.close() }

        func flushBatch() throws {
            guard !batch.isEmpty else { return }
            do {
                try db.insertRecordsThrowing(batch)
                batch.removeAll(keepingCapacity: true)
            } catch {
                throw StrictSessionSyncError.databaseWriteFailed(file.path)
            }
        }

        while remaining > 0 {
            try checkCancellation(cancellation)
            let readCount = min(Int64(Self.rebuildReadChunkSize), remaining)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: Int(readCount)) ?? Data()
            } catch {
                throw StrictSessionSyncError.sourceReadFailed(file.path)
            }
            guard !chunk.isEmpty else {
                throw StrictSessionSyncError.sourceReadFailed(file.path)
            }

            pending.append(chunk)
            bytesRead += Int64(chunk.count)
            remaining -= Int64(chunk.count)

            var lineStart = pending.startIndex
            var searchStart = pending.index(
                pending.startIndex,
                offsetBy: min(searchedByteCount, pending.count)
            )
            var consumedThrough = pending.startIndex
            while searchStart < pending.endIndex,
                  let newlineRange = pending.range(
                    of: Self.newlineDelimiter,
                    options: [],
                    in: searchStart..<pending.endIndex
                  ) {
                let newlineIndex = newlineRange.lowerBound
                if newlineIndex > lineStart {
                    let lineRange = lineStart..<newlineIndex
                    let record: ParsedRecord?
                    switch file.source {
                    case .claude:
                        record = SessionLogLineFilter.shouldParseClaude(pending, in: lineRange)
                            ? ClaudeLogParser.parse(lineData: pending.subdata(in: lineRange))
                            : nil
                    case .codex:
                        record = SessionLogLineFilter.shouldParseCodex(pending, in: lineRange)
                            ? CodexLogParser.parse(
                                lineData: pending.subdata(in: lineRange),
                                context: &codexContext
                            )
                            : nil
                    }
                    if let record {
                        batch.append(record)
                        parsedRecordCount += 1
                        if file.source == .claude {
                            claudeRecordCount += 1
                        }
                        if batch.count >= Self.rebuildRecordBatchSize {
                            try flushBatch()
                        }
                    }
                }
                lineStart = newlineRange.upperBound
                searchStart = newlineRange.upperBound
                consumedThrough = lineStart
            }
            if consumedThrough > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<consumedThrough)
            }
            searchedByteCount = pending.count
            onBytesProcessed(Int64(chunk.count), parsedRecordCount)
        }

        try checkCancellation(cancellation)
        let final = try currentSnapshot(for: file.path, source: file.source)
        guard final.fileIdentity == file.fileIdentity,
              final.byteCount >= file.byteCount else {
            throw StrictSessionSyncError.sourceFileChanged(file.path)
        }

        let completedOffset = offset + bytesRead - Int64(pending.count)
        let state = SyncState(
            filePath: file.path,
            byteOffset: completedOffset,
            recordCount: file.source == .codex ? codexContext.turnCount : claudeRecordCount,
            sessionId: file.source == .codex ? codexContext.sessionId : nil,
            model: file.source == .codex ? codexContext.currentModel : nil,
            lastModified: final.modifiedAt,
            lastSyncedAt: Int(Date().timeIntervalSince1970),
            lastTotalInputTokens: file.source == .codex ? codexContext.lastTotalIn : 0,
            lastTotalOutputTokens: file.source == .codex ? codexContext.lastTotalOut : 0
        )
        do {
            try db.commitSync(records: batch, state: state)
        } catch {
            throw StrictSessionSyncError.databaseWriteFailed(file.path)
        }
        return SessionSyncResult(filesSynced: 1, recordsSynced: parsedRecordCount)
    }

    private func strictProgress(
        file: SessionSourceFileSnapshot?,
        isCatchUp: Bool,
        completedFiles: Int,
        totalFiles: Int,
        processedBytes: Int64,
        totalBytes: Int64,
        recordsSynced: Int
    ) -> SessionSyncProgress {
        let phase: UsageDataRebuildPhase
        if isCatchUp {
            phase = .catchingUp
        } else if file?.source == .codex {
            phase = .rebuildingCodex
        } else {
            phase = .rebuildingClaude
        }
        return SessionSyncProgress(
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            recordsSynced: recordsSynced,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            phase: phase,
            currentSource: file?.source.rawValue
        )
    }

    private func checkCancellation(_ cancellation: UsageDataRebuildCancellation?) throws {
        if cancellation?.isCancelled == true {
            throw StrictSessionSyncError.cancelled
        }
    }

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
