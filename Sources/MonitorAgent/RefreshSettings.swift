import Combine
import Foundation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case never = 0

    static let defaultValue: RefreshInterval = .oneMinute

    var id: Int { rawValue }

    var effectiveInterval: TimeInterval {
        TimeInterval((self == .never ? Self.defaultValue : self).rawValue)
    }

    var displayName: String {
        switch self {
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .never: return "Never"
        }
    }
}

final class RefreshSettings: ObservableObject {
    static let shared = RefreshSettings()

    @Published var interval: RefreshInterval {
        didSet { defaults.set(interval.rawValue, forKey: Keys.refreshInterval) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interval = Self.loadInterval(from: defaults)
        defaults.set(interval.rawValue, forKey: Keys.refreshInterval)
    }

    private static func loadInterval(from defaults: UserDefaults) -> RefreshInterval {
        if let interval = storedInterval(forKey: Keys.refreshInterval, in: defaults) {
            return interval
        }
        if let interval = storedInterval(forKey: Keys.quotaRefreshInterval, in: defaults) {
            return interval
        }
        if defaults.object(forKey: Keys.syncInterval) != nil {
            return defaults.integer(forKey: Keys.syncInterval) == 0 ? .never : .oneMinute
        }
        return .defaultValue
    }

    private static func storedInterval(
        forKey key: String,
        in defaults: UserDefaults
    ) -> RefreshInterval? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return RefreshInterval(rawValue: defaults.integer(forKey: key))
    }

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let quotaRefreshInterval = "quotaRefreshInterval"
        static let syncInterval = "syncInterval"
    }
}
