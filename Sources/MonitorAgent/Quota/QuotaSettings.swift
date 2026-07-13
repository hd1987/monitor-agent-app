import Combine
import Foundation

enum QuotaRefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case never = 0

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .never: return "Never"
        }
    }

    var minimumRequestInterval: TimeInterval {
        self == .never ? TimeInterval(Self.twoMinutes.rawValue) : TimeInterval(rawValue)
    }
}

final class QuotaSettings: ObservableObject {
    static let shared = QuotaSettings()

    @Published var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: Keys.claudeEnabled) }
    }

    @Published var codexEnabled: Bool {
        didSet { defaults.set(codexEnabled, forKey: Keys.codexEnabled) }
    }

    @Published var refreshInterval: QuotaRefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudeEnabled = defaults.object(forKey: Keys.claudeEnabled) as? Bool ?? true
        codexEnabled = defaults.object(forKey: Keys.codexEnabled) as? Bool ?? true
        if defaults.object(forKey: Keys.refreshInterval) == nil {
            refreshInterval = .twoMinutes
        } else {
            refreshInterval = QuotaRefreshInterval(
                rawValue: defaults.integer(forKey: Keys.refreshInterval)
            ) ?? .twoMinutes
        }
    }

    func isEnabled(_ provider: QuotaProviderID) -> Bool {
        switch provider {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        }
    }

    private enum Keys {
        static let claudeEnabled = "quotaClaudeEnabled"
        static let codexEnabled = "quotaCodexEnabled"
        static let refreshInterval = "quotaRefreshInterval"
    }
}
