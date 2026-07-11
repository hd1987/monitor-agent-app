import Combine
import Foundation

final class QuotaSettings: ObservableObject {
    static let shared = QuotaSettings()

    @Published var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: Keys.claudeEnabled) }
    }

    @Published var codexEnabled: Bool {
        didSet { defaults.set(codexEnabled, forKey: Keys.codexEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudeEnabled = defaults.object(forKey: Keys.claudeEnabled) as? Bool ?? true
        codexEnabled = defaults.object(forKey: Keys.codexEnabled) as? Bool ?? true
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
    }
}
