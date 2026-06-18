import Foundation
import Combine

/// Sync interval options (seconds). `0` means manual-only (sync on panel open).
enum SyncInterval: Int, CaseIterable, Identifiable {
    case ten = 10
    case twenty = 20
    case thirty = 30
    case forty = 40
    case fifty = 50
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

    private init() {
        let raw = UserDefaults.standard.integer(forKey: "syncInterval")
        // Default to 30s if no saved value (0 is valid for "never", but fresh install has no key)
        if UserDefaults.standard.object(forKey: "syncInterval") == nil {
            self.interval = .thirty
        } else {
            self.interval = SyncInterval(rawValue: raw) ?? .thirty
        }
    }
}
