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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudeExpirationDate = defaults.object(forKey: Keys.claudeExpirationDate) as? Date
        codexExpirationDate = defaults.object(forKey: Keys.codexExpirationDate) as? Date
    }

    /// A provider is enabled when the user has set its subscription expiration date.
    func isEnabled(_ provider: QuotaProviderID) -> Bool {
        expirationDate(for: provider) != nil
    }

    func expirationDate(for provider: QuotaProviderID) -> Date? {
        switch provider {
        case .claude: return claudeExpirationDate
        case .codex: return codexExpirationDate
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
    }
}
