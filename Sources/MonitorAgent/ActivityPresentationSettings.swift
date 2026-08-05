import Foundation

protocol ActivityPresentationPersisting: AnyObject {
    var isPresented: Bool { get set }
}

final class ActivityPresentationSettings: ActivityPresentationPersisting {
    static let shared = ActivityPresentationSettings()

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        environment: DatabaseEnvironment = .current
    ) {
        self.defaults = defaults
        key = switch environment {
        case .development: "activityDetailPresented.development"
        case .production: "activityDetailPresented.production"
        }
    }

    var isPresented: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
