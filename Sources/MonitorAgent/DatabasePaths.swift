import Foundation

enum DatabaseEnvironment {
    static let productionBundleIdentifier = "com.hd1987.monitor-agent"

    case development
    case production

    static var current: DatabaseEnvironment {
        resolve(
            bundlePath: Bundle.main.bundlePath,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func resolve(
        bundlePath: String,
        bundleIdentifier: String?
    ) -> DatabaseEnvironment {
        guard bundlePath.hasSuffix(".app"),
              bundleIdentifier == productionBundleIdentifier else {
            return .development
        }
        return .production
    }
}

struct DatabasePaths: Equatable {
    let directory: String
    let database: String
    let rebuildDatabase: String

    static var current: DatabasePaths {
        make(homeDirectory: NSHomeDirectory(), environment: .current)
    }

    static func make(
        homeDirectory: String,
        environment: DatabaseEnvironment
    ) -> DatabasePaths {
        let rootDirectory = homeDirectory + "/.monitor-agent"
        let directory = switch environment {
        case .development:
            rootDirectory + "/development"
        case .production:
            rootDirectory
        }

        return DatabasePaths(
            directory: directory,
            database: directory + "/monitor.db",
            rebuildDatabase: directory + "/monitor-rebuild.tmp.db"
        )
    }
}
