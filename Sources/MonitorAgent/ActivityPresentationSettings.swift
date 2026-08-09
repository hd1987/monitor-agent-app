import Foundation

enum ActivityChartStyle: String, Equatable {
    case line
    case bar

    var toggled: ActivityChartStyle {
        self == .line ? .bar : .line
    }

    var displayName: String {
        self == .line ? "Line Chart" : "Bar Chart"
    }
}

protocol ActivityPresentationPersisting: AnyObject {
    var isPresented: Bool { get set }
    var chartStyle: ActivityChartStyle { get set }
}

final class ActivityPresentationSettings: ActivityPresentationPersisting {
    static let shared = ActivityPresentationSettings()

    private let defaults: UserDefaults
    private let presentationKey: String
    private let chartStyleKey: String

    init(
        defaults: UserDefaults = .standard,
        environment: DatabaseEnvironment = .current
    ) {
        self.defaults = defaults
        switch environment {
        case .development:
            presentationKey = "activityDetailPresented.development"
            chartStyleKey = "activityDetailChartStyle.development"
        case .production:
            presentationKey = "activityDetailPresented.production"
            chartStyleKey = "activityDetailChartStyle.production"
        }
    }

    var isPresented: Bool {
        get { defaults.bool(forKey: presentationKey) }
        set { defaults.set(newValue, forKey: presentationKey) }
    }

    var chartStyle: ActivityChartStyle {
        get {
            defaults.string(forKey: chartStyleKey)
                .flatMap(ActivityChartStyle.init(rawValue:)) ?? .line
        }
        set { defaults.set(newValue.rawValue, forKey: chartStyleKey) }
    }
}
