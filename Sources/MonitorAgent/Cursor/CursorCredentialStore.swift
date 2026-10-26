import Darwin
import Foundation

struct CursorLoginCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let accountIdentity: String
    let accountEmail: String?
    let expiresAt: Date
    let selectedTeamId: Int?

    init(
        accessToken: String, refreshToken: String, accountIdentity: String,
        accountEmail: String?, expiresAt: Date, selectedTeamId: Int? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountIdentity = accountIdentity
        self.accountEmail = accountEmail
        self.expiresAt = expiresAt
        self.selectedTeamId = selectedTeamId
    }

    func validate() throws {
        _ = try CursorStoredTokenDecoder().decode(accessToken)
        _ = try CursorStoredTokenDecoder().decode(refreshToken)
        guard accountIdentity.hasPrefix("cursor-account:"), accountIdentity.utf8.count == 79,
              accountIdentity.dropFirst(15).allSatisfy({ $0.isHexDigit }),
              (accountEmail?.utf8.count ?? 0) <= 1_024,
              expiresAt.timeIntervalSince1970.isFinite,
              selectedTeamId.map({ $0 > 0 }) ?? true else {
            throw CursorUsageError.authenticationUnavailable
        }
    }
}

final class CursorCredentialStore {
    static let shared = CursorCredentialStore()
    static let didChange = Notification.Name("MonitorAgentCursorCredentialsDidChange")

    struct Snapshot {
        let credentials: CursorLoginCredentials?
        let revision: UInt64
    }

    let fileURL: URL
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var loaded = false
    private var credentials: CursorLoginCredentials?

    init(fileURL: URL = URL(fileURLWithPath: DatabasePaths.current.directory)
        .appendingPathComponent("cursor-auth.json")) {
        self.fileURL = fileURL
    }

    func snapshot() throws -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            credentials = try readFile()
            loaded = true
        }
        return Snapshot(credentials: credentials, revision: revision)
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    @discardableResult
    func replace(
        _ credentials: CursorLoginCredentials?,
        expectedRevision: UInt64? = nil,
        isRefresh: Bool = false
    ) throws -> Bool {
        try credentials?.validate()
        lock.lock()
        defer { lock.unlock() }
        if let expectedRevision, revision != expectedRevision { return false }
        let data = try JSONEncoder().encode(Contents(version: 1, credentials: credentials))
        try writeFile(data)
        self.credentials = credentials
        loaded = true
        if !isRefresh { revision &+= 1 }
        return true
    }

    private struct Contents: Codable {
        let version: Int
        let credentials: CursorLoginCredentials?
    }

    private func readFile() throws -> CursorLoginCredentials? {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CursorUsageError.authenticationUnavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= 65_536 else {
            throw CursorUsageError.authenticationUnavailable
        }
        do {
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw CursorUsageError.authenticationUnavailable }
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard contents.version == 1 else { throw CursorUsageError.authenticationUnavailable }
            try contents.credentials?.validate()
            return contents.credentials
        } catch {
            throw CursorUsageError.authenticationUnavailable
        }
    }

    private func writeFile(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var template = Array(directory.appendingPathComponent(".cursor-auth.XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw CursorUsageError.authenticationUnavailable }
            let temporaryPath = String(cString: template)
            defer {
                close(descriptor)
                unlink(temporaryPath)
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw CursorUsageError.authenticationUnavailable }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CursorUsageError.authenticationUnavailable }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0,
                  rename(temporaryPath, fileURL.path) == 0 else {
                throw CursorUsageError.authenticationUnavailable
            }
        } catch {
            throw CursorUsageError.authenticationUnavailable
        }
    }
}
