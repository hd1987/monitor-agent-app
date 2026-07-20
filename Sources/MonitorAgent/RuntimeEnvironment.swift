import Darwin
import Foundation

protocol PreferencesStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func data(forKey defaultName: String) -> Data?
    func integer(forKey defaultName: String) -> Int
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferencesStoring {}

final class InMemoryPreferencesStore: PreferencesStoring {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    func object(forKey defaultName: String) -> Any? {
        withLock { values[defaultName] }
    }

    func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    func integer(forKey defaultName: String) -> Int {
        (object(forKey: defaultName) as? NSNumber)?.intValue
            ?? (object(forKey: defaultName) as? Int)
            ?? 0
    }

    func set(_ value: Any?, forKey defaultName: String) {
        withLock {
            values[defaultName] = value
        }
    }

    func removeObject(forKey defaultName: String) {
        _ = withLock {
            values.removeValue(forKey: defaultName)
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

enum RuntimeMode: Equatable {
    case production
    case development
}

struct RuntimeFeaturePolicy: Equatable {
    let allowsGlobalShortcutRegistration: Bool
    let allowsUpdateChecks: Bool
    let allowsLiveQuotaRefresh: Bool
    let allowsLaunchAtLogin: Bool
    let allowsExternalConfigSaving: Bool
}

struct RuntimeEnvironment: Equatable {
    static let productionBundleIdentifier = "com.hd1987.monitor-agent"
    static let current = resolve()
    private static let developmentPreferences = InMemoryPreferencesStore()

    let mode: RuntimeMode
    let productionDataDirectory: String
    let featurePolicy: RuntimeFeaturePolicy

    var isProduction: Bool { mode == .production }
    var productionDatabasePath: String { productionDataDirectory + "/monitor.db" }
    var rebuildDatabasePath: String { productionDataDirectory + "/monitor-rebuild.tmp.db" }
    var instanceLockPath: String { productionDataDirectory + "/instance.lock" }

    var preferences: PreferencesStoring {
        switch mode {
        case .production:
            return UserDefaults.standard
        case .development:
            return Self.developmentPreferences
        }
    }

    static func resolve(
        bundlePath: String = Bundle.main.bundlePath,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RuntimeEnvironment {
        let requestedMode = environment["MONITOR_AGENT_RUNTIME"]?.lowercased()
        let isInstalledApplication = bundlePath.hasSuffix(".app")
            && bundleIdentifier == productionBundleIdentifier
        let mode: RuntimeMode
        if requestedMode == "development" {
            mode = .development
        } else if requestedMode == "production" && isInstalledApplication {
            mode = .production
        } else {
            mode = isInstalledApplication ? .production : .development
        }

        let liveQuotaEnabled = environment["MONITOR_AGENT_ENABLE_LIVE_QUOTA"] == "1"
        let policy = RuntimeFeaturePolicy(
            allowsGlobalShortcutRegistration: mode == .production,
            allowsUpdateChecks: mode == .production,
            allowsLiveQuotaRefresh: mode == .production || liveQuotaEnabled,
            allowsLaunchAtLogin: mode == .production,
            allowsExternalConfigSaving: mode == .production
        )
        return RuntimeEnvironment(
            mode: mode,
            productionDataDirectory: homeDirectory + "/.monitor-agent",
            featurePolicy: policy
        )
    }
}

enum ProcessInstanceLockError: Error, Equatable {
    case alreadyLocked
    case unavailable(Int32)
}

final class ProcessInstanceLock {
    private let fileDescriptor: Int32

    init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProcessInstanceLockError.unavailable(errno)
        }

        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK {
                throw ProcessInstanceLockError.alreadyLocked
            }
            throw ProcessInstanceLockError.unavailable(errno)
        }
        fileDescriptor = descriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }
}
