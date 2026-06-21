import Foundation
import Combine
import ServiceManagement

/// Sync interval options (seconds). `0` means manual-only (sync on panel open).
enum SyncInterval: Int, CaseIterable, Identifiable {
    case ten = 10
    case thirty = 30
    case sixty = 60
    case never = 0

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        default: return "\(rawValue)s"
        }
    }
}

/// Persists sync interval to UserDefaults and publishes changes.
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()

    @Published var interval: SyncInterval {
        didSet { UserDefaults.standard.set(interval.rawValue, forKey: "syncInterval") }
    }

    /// Keep running in background when Cmd+Q is pressed (default: true)
    @Published var keepInBackground: Bool {
        didSet { UserDefaults.standard.set(keepInBackground, forKey: "keepInBackground") }
    }

    /// Launch at login via SMAppService (only works for .app bundles)
    var launchAtLogin: Bool {
        get {
            guard canControlLaunchAtLogin else { return false }
            return SMAppService.mainApp.status == .enabled
        }
        set {
            objectWillChange.send()
            guard canControlLaunchAtLogin else { return }
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    /// Whether the app is running as a proper .app bundle (SMAppService requires it)
    var canControlLaunchAtLogin: Bool {
        Self.canRegisterLaunchAtLogin(
            bundlePath: Bundle.main.bundlePath,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func canRegisterLaunchAtLogin(bundlePath: String, bundleIdentifier: String?) -> Bool {
        bundleIdentifier != nil && bundlePath.hasSuffix(".app")
    }

    private init() {
        let raw = UserDefaults.standard.integer(forKey: "syncInterval")
        // Default to 30s if no saved value (0 is valid for "never", but fresh install has no key)
        if UserDefaults.standard.object(forKey: "syncInterval") == nil {
            self.interval = .thirty
        } else {
            self.interval = SyncInterval(rawValue: raw) ?? .thirty
        }

        if UserDefaults.standard.object(forKey: "keepInBackground") == nil {
            self.keepInBackground = true
        } else {
            self.keepInBackground = UserDefaults.standard.bool(forKey: "keepInBackground")
        }
    }
}
