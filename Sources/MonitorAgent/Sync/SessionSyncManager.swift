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

enum CursorUsageSyncOutcome: Equatable {
    case success
    case failure(CursorRefreshFailureReason)
    case cancelled
    case skipped
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

/// Syncs Claude Code and Codex JSONL logs plus Cursor usage events into the
/// local database for one refresh cycle.
final class SessionSyncManager {
    private struct CursorSyncWaiter {
        let cancellation: AgentSyncCancellation?
        let onSuccess: () -> Void
        let onOutcome: (CursorUsageSyncOutcome) -> Void
        let completion: () -> Void
    }

    private final class CursorSyncRequest {
        let expectedIdentity: String?
        let cancellation: AgentSyncCancellation?
        var waiters: [CursorSyncWaiter]
        var acceptsWaiters = true

        init(
            expectedIdentity: String?,
            cancellation: AgentSyncCancellation?,
            waiter: CursorSyncWaiter
        ) {
            self.expectedIdentity = expectedIdentity
            self.cancellation = cancellation
            waiters = [waiter]
        }

        func canCoalesce(
            expectedIdentity: String?,
            cancellation: AgentSyncCancellation?
        ) -> Bool {
            guard self.expectedIdentity == expectedIdentity else { return false }
            switch (self.cancellation, cancellation) {
            case (nil, nil):
                return true
            case (let current?, let candidate?):
                return current === candidate
            default:
                return false
            }
        }
    }

    private final class CursorOperationResultBox<T> {
        var result: Result<T, Error>?
    }

    private static let rebuildReadChunkSize = 1_048_576
    private static let rebuildRecordBatchSize = 10_000
    private static let newlineDelimiter = Data([UInt8(0x0A)])
    private let queue = DispatchQueue(label: "com.monitoragent.sync", qos: .utility)
    private let cursorQueue: DispatchQueue
    private let cursorScheduleLock = NSLock()
    private let cursorSubmissionLock = NSLock()
    private var lastSubmittedCursorSyncRequest: CursorSyncRequest?
    private let db: DatabaseManager
    private let fm = FileManager.default
    private let claudeProjectsPath: String
    private let codexSessionsPath: String
    private let codexArchivedSessionsPath: String
    private let cursorUsageSyncer: CursorUsageSyncing?
    private let beforeCursorDrainSubmission: (() -> Void)?
    private let beforeCursorOperationSubmission: (() -> Void)?

    init(
        database: DatabaseManager = .shared,
        claudeProjectsPath: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsPath: String = NSHomeDirectory() + "/.codex/sessions",
        codexArchivedSessionsPath: String = NSHomeDirectory() + "/.codex/archived_sessions",
        cursorUsageSyncer: CursorUsageSyncing? = nil,
        cursorQueue: DispatchQueue? = nil,
        beforeCursorDrainSubmission: (() -> Void)? = nil,
        beforeCursorOperationSubmission: (() -> Void)? = nil
    ) {
        self.db = database
        self.claudeProjectsPath = claudeProjectsPath
        self.codexSessionsPath = codexSessionsPath
        self.codexArchivedSessionsPath = codexArchivedSessionsPath
        self.cursorUsageSyncer = cursorUsageSyncer
        self.cursorQueue = cursorQueue ?? DispatchQueue(
            label: "com.monitoragent.cursor-sync",
            qos: .utility
        )
        self.beforeCursorDrainSubmission = beforeCursorDrainSubmission
        self.beforeCursorOperationSubmission = beforeCursorOperationSubmission
    }

    /// Run local and Cursor syncs on separate background queues.
    func syncOnce(
        enabledAgents: Set<AgentID> = Set(AgentID.allCases),
        cancellation: AgentSyncCancellation? = nil,
        expectedCursorIdentity: String? = nil,
        onLocalComplete: @escaping () -> Void,
        onCursorComplete: @escaping () -> Void,
        onCursorOutcome: @escaping (CursorUsageSyncOutcome) -> Void = { _ in },
        completion: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            _ = self.syncLocal(
                enabledAgents: enabledAgents,
                cancellation: cancellation
            )
            onLocalComplete()
            guard enabledAgents.contains(.cursor),
                  cancellation?.isEnabled(.cursor) != false else {
                completion()
                return
            }
            self.scheduleCursorSync(
                expectedIdentity: expectedCursorIdentity,
                cancellation: cancellation,
                onSuccess: onCursorComplete,
                onOutcome: onCursorOutcome,
                completion: completion
            )
        }
    }

    func syncAllOnce(
        enabledAgents: Set<AgentID> = Set(AgentID.allCases),
        onProgress: ((SessionSyncProgress) -> Void)? = nil
    ) -> SessionSyncResult {
        var result = syncLocal(enabledAgents: enabledAgents, onProgress: onProgress)
        if enabledAgents.contains(.cursor),
           let cursorUsageSyncer,
           let cursorResult = try? performSubmittedCursorOperation({
               try cursorUsageSyncer.sync()
           }) {
            result.add(cursorResult)
        }
        return result
    }

    func syncCursorOnce(
        expectedIdentity: String,
        cancellation: AgentSyncCancellation? = nil,
        onSuccess: @escaping () -> Void,
        onOutcome: @escaping (CursorUsageSyncOutcome) -> Void = { _ in },
        completion: @escaping () -> Void
    ) {
        scheduleCursorSync(
            expectedIdentity: expectedIdentity,
            cancellation: cancellation,
            onSuccess: onSuccess,
            onOutcome: onOutcome,
            completion: completion
        )
    }

    func performExclusive<T>(_ operation: @escaping () throws -> T) throws -> T {
        try queue.sync {
            try performSubmittedCursorOperation(operation)
        }
    }

    private func performSubmittedCursorOperation<T>(
        _ operation: @escaping () throws -> T
    ) throws -> T {
        let completion = DispatchSemaphore(value: 0)
        let resultBox = CursorOperationResultBox<T>()
        cursorSubmissionLock.lock()
        cursorScheduleLock.lock()
        lastSubmittedCursorSyncRequest = nil
        beforeCursorOperationSubmission?()
        cursorQueue.async {
            resultBox.result = Result {
                try operation()
            }
            completion.signal()
        }
        cursorScheduleLock.unlock()
        cursorSubmissionLock.unlock()
        completion.wait()
        return try resultBox.result!.get()
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

    // MARK: - Sync Cycle

    private func syncLocal(
        enabledAgents: Set<AgentID> = Set(AgentID.allCases),
        cancellation: AgentSyncCancellation? = nil,
        onProgress: ((SessionSyncProgress) -> Void)? = nil
    ) -> SessionSyncResult {
        let claudeFiles = enabledAgents.contains(.claude) && cancellation?.isEnabled(.claude) != false
            ? discoverClaudeFiles(cancellation: cancellation)
            : []
        let codexFiles = enabledAgents.contains(.codex) && cancellation?.isEnabled(.codex) != false
            ? discoverCodexFiles(cancellation: cancellation)
            : []
        let allFiles = claudeFiles.map { ($0, AgentID.claude) }
            + codexFiles.map { ($0, AgentID.codex) }
        let totalFiles = allFiles.count
        var result = SessionSyncResult()
        var completedFiles = 0

        onProgress?(SessionSyncProgress(
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            recordsSynced: result.recordsSynced
        ))

        for (path, agent) in allFiles {
            guard cancellation?.isEnabled(agent) != false else { continue }
            result.add(syncFile(
                path: path,
                agent: agent,
                cancellation: cancellation
            ))
            completedFiles += 1
            onProgress?(SessionSyncProgress(
                completedFiles: completedFiles,
                totalFiles: totalFiles,
                recordsSynced: result.recordsSynced
            ))
        }
        return result
    }

    private func scheduleCursorSync(
        expectedIdentity: String?,
        cancellation: AgentSyncCancellation?,
        onSuccess: @escaping () -> Void,
        onOutcome: @escaping (CursorUsageSyncOutcome) -> Void,
        completion: @escaping () -> Void
    ) {
        guard let cursorUsageSyncer else {
            onOutcome(.skipped)
            completion()
            return
        }

        let waiter = CursorSyncWaiter(
            cancellation: cancellation,
            onSuccess: onSuccess,
            onOutcome: onOutcome,
            completion: completion
        )
        cursorSubmissionLock.lock()
        cursorScheduleLock.lock()
        if let lastSubmittedCursorSyncRequest,
           lastSubmittedCursorSyncRequest.acceptsWaiters,
           lastSubmittedCursorSyncRequest.canCoalesce(
               expectedIdentity: expectedIdentity,
               cancellation: cancellation
           ) {
            lastSubmittedCursorSyncRequest.waiters.append(waiter)
            cursorScheduleLock.unlock()
            cursorSubmissionLock.unlock()
            return
        }
        let request = CursorSyncRequest(
            expectedIdentity: expectedIdentity,
            cancellation: cancellation,
            waiter: waiter
        )
        lastSubmittedCursorSyncRequest = request
        beforeCursorDrainSubmission?()
        executeCursorSync(request, using: cursorUsageSyncer)
        cursorScheduleLock.unlock()
        cursorSubmissionLock.unlock()
    }

    private func executeCursorSync(
        _ initialRequest: CursorSyncRequest,
        using cursorUsageSyncer: CursorUsageSyncing
    ) {
        cursorQueue.async { [self] in
            let outcome = self.runCursorSync(
                initialRequest,
                using: cursorUsageSyncer
            )
            self.finishCursorSync(initialRequest, outcome: outcome)
        }
    }

    private func runCursorSync(
        _ request: CursorSyncRequest,
        using cursorUsageSyncer: CursorUsageSyncing
    ) -> CursorUsageSyncOutcome {
        guard request.cancellation?.isEnabled(.cursor) != false else { return .cancelled }
        let cursorResult: SessionSyncResult
        do {
            if let cursorUsageSyncer = cursorUsageSyncer as? CancellableCursorUsageSyncing {
                cursorResult = try cursorUsageSyncer.sync(cancellation: request.cancellation)
            } else {
                cursorResult = try cursorUsageSyncer.sync()
            }
        } catch CursorUsageError.cancelled {
            return .cancelled
        } catch {
            return .failure(error.cursorRefreshFailureReason)
        }
        guard request.cancellation?.isEnabled(.cursor) != false else { return .cancelled }
        guard cursorResult.filesSynced > 0 else { return .failure(.request) }
        guard request.expectedIdentity == nil
                || db.getSyncState(
                    for: CursorUsageService.syncStateKey
                )?.sessionId == request.expectedIdentity else {
            return .cancelled
        }
        return .success
    }

    private func finishCursorSync(
        _ request: CursorSyncRequest,
        outcome: CursorUsageSyncOutcome
    ) {
        cursorScheduleLock.lock()
        request.acceptsWaiters = false
        let waiters = request.waiters
        if lastSubmittedCursorSyncRequest === request {
            lastSubmittedCursorSyncRequest = nil
        }
        cursorScheduleLock.unlock()

        waiters.forEach {
            guard $0.cancellation?.isEnabled(.cursor) != false else {
                $0.onOutcome(.cancelled)
                return
            }
            if outcome == .success {
                $0.onSuccess()
            }
            $0.onOutcome(outcome)
        }
        waiters.forEach { $0.completion() }
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

    private func discoverClaudeFiles(cancellation: AgentSyncCancellation?) -> [String] {
        findFiles(
            under: claudeProjectsPath,
            cancellation: cancellation,
            agent: .claude,
            matching: { $0.hasSuffix(".jsonl") }
        )
    }

    private func discoverCodexFiles(cancellation: AgentSyncCancellation?) -> [String] {
        let filter: (String) -> Bool = {
            $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl")
        }
        let a = findFiles(
            under: codexSessionsPath,
            cancellation: cancellation,
            agent: .codex,
            matching: filter
        )
        guard cancellation?.isEnabled(.codex) != false else { return a }
        let b = findFiles(
            under: codexArchivedSessionsPath,
            cancellation: cancellation,
            agent: .codex,
            matching: filter
        )
        return a + b
    }

    private func findFiles(
        under directory: String,
        cancellation: AgentSyncCancellation?,
        agent: AgentID,
        matching filter: (String) -> Bool
    ) -> [String] {
        guard cancellation?.isEnabled(agent) != false else { return [] }
        guard fm.fileExists(atPath: directory),
              let enumerator = fm.enumerator(atPath: directory) else { return [] }

        var results: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard cancellation?.isEnabled(agent) != false else { break }
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

    private func syncFile(
        path: String,
        agent: AgentID,
        cancellation: AgentSyncCancellation?
    ) -> SessionSyncResult {
        guard cancellation?.isEnabled(agent) != false else { return SessionSyncResult() }
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
        var pending = Data()
        var records: [ParsedRecord] = []
        var codexContext = CodexParseContext(syncState: existing)
        var bytesConsumed: Int64 = 0

        while cancellation?.isEnabled(agent) != false {
            let chunk = handle.readData(ofLength: Self.rebuildReadChunkSize)
            guard !chunk.isEmpty else { break }
            let previouslyScannedCount = pending.count
            pending.append(chunk)

            var lineStart = pending.startIndex
            var searchStart = pending.index(
                pending.startIndex,
                offsetBy: previouslyScannedCount
            )
            var consumedThrough = pending.startIndex
            while searchStart < pending.endIndex,
                  let newlineIndex = pending[searchStart..<pending.endIndex].firstIndex(of: UInt8(0x0A)) {
                guard cancellation?.isEnabled(agent) != false else {
                    return SessionSyncResult()
                }
                if newlineIndex > lineStart {
                    let lineData = pending.subdata(in: lineStart..<newlineIndex)
                    let record: ParsedRecord?
                    if agent == .codex {
                        record = CodexLogParser.parse(
                            lineData: lineData,
                            context: &codexContext
                        )
                    } else {
                        record = ClaudeLogParser.parse(lineData: lineData)
                    }
                    if let record {
                        records.append(record)
                    }
                }
                lineStart = pending.index(after: newlineIndex)
                searchStart = lineStart
                consumedThrough = lineStart
            }
            if consumedThrough > pending.startIndex {
                let consumedCount = pending.distance(
                    from: pending.startIndex,
                    to: consumedThrough
                )
                bytesConsumed += Int64(consumedCount)
                pending.removeFirst(consumedCount)
            }
        }
        guard cancellation?.isEnabled(agent) != false else { return SessionSyncResult() }
        guard bytesConsumed > 0 else { return SessionSyncResult() }

        if agent == .codex {
            // Update sync state with context
            let state = SyncState(
                filePath: path,
                byteOffset: offset + bytesConsumed,
                recordCount: codexContext.turnCount,
                sessionId: codexContext.sessionId,
                model: codexContext.currentModel,
                lastModified: fileMtime,
                lastSyncedAt: Int(Date().timeIntervalSince1970),
                lastTotalInputTokens: codexContext.lastTotalIn,
                lastTotalOutputTokens: codexContext.lastTotalOut
            )
            do {
                if let cancellation {
                    guard try cancellation.withEnabledAgent(agent, perform: {
                        try db.commitSync(records: records, state: state)
                    }) != nil else {
                        return SessionSyncResult()
                    }
                } else {
                    try db.commitSync(records: records, state: state)
                }
            } catch {
                print("Failed to commit sync for \(path): \(error)")
                return SessionSyncResult()
            }
        } else {
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
                if let cancellation {
                    guard try cancellation.withEnabledAgent(agent, perform: {
                        try db.commitSync(records: records, state: state)
                    }) != nil else {
                        return SessionSyncResult()
                    }
                } else {
                    try db.commitSync(records: records, state: state)
                }
            } catch {
                print("Failed to commit sync for \(path): \(error)")
                return SessionSyncResult()
            }
        }
        return SessionSyncResult(filesSynced: 1, recordsSynced: records.count)
    }
}
