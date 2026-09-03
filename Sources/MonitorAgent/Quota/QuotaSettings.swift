import Combine
import Foundation

final class QuotaSettings: ObservableObject {
    static let shared = QuotaSettings()

    @Published var claudeExpirationDate: Date? {
        didSet { persist(claudeExpirationDate, forKey: Keys.claudeExpirationDate) }
    }

    @Published var codexExpirationDate: Date? {
        didSet { persist(codexExpirationDate, forKey: Keys.codexExpirationDate) }
    }

    @Published var cursorQuotaEnabled: Bool {
        didSet { defaults.set(cursorQuotaEnabled, forKey: Keys.cursorQuotaEnabled) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudeExpirationDate = defaults.object(forKey: Keys.claudeExpirationDate) as? Date
        codexExpirationDate = defaults.object(forKey: Keys.codexExpirationDate) as? Date
        cursorQuotaEnabled = defaults.object(forKey: Keys.cursorQuotaEnabled) as? Bool ?? false
    }

    func isEnabled(_ provider: QuotaProviderID) -> Bool {
        switch provider {
        case .claude, .codex: return expirationDate(for: provider) != nil
        case .cursor: return cursorQuotaEnabled
        }
    }

    func expirationDate(for provider: QuotaProviderID) -> Date? {
        switch provider {
        case .claude: return claudeExpirationDate
        case .codex: return codexExpirationDate
        case .cursor: return nil
        }
    }

    private func persist(_ date: Date?, forKey key: String) {
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Keys {
        static let claudeExpirationDate = "quotaClaudeExpirationDate"
        static let codexExpirationDate = "quotaCodexExpirationDate"
        static let cursorQuotaEnabled = "quotaCursorEnabled"
    }
}
