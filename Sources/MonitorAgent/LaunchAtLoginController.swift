import Combine
import Foundation
import ServiceManagement

final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

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

    var canControlLaunchAtLogin: Bool {
        Self.canRegisterLaunchAtLogin(
            bundlePath: Bundle.main.bundlePath,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func canRegisterLaunchAtLogin(bundlePath: String, bundleIdentifier: String?) -> Bool {
        bundleIdentifier != nil && bundlePath.hasSuffix(".app")
    }
}
