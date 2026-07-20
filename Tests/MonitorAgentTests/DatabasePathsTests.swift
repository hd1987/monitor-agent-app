import XCTest
@testable import MonitorAgent

final class DatabasePathsTests: XCTestCase {
    func testDevelopmentPathsAreIsolatedFromProduction() {
        let development = DatabasePaths.make(
            homeDirectory: "/Users/test",
            environment: .development
        )
        let production = DatabasePaths.make(
            homeDirectory: "/Users/test",
            environment: .production
        )

        XCTAssertEqual(development.directory, "/Users/test/.monitor-agent/development")
        XCTAssertEqual(development.database, "/Users/test/.monitor-agent/development/monitor.db")
        XCTAssertEqual(
            development.rebuildDatabase,
            "/Users/test/.monitor-agent/development/monitor-rebuild.tmp.db"
        )
        XCTAssertNotEqual(development.database, production.database)
        XCTAssertNotEqual(development.rebuildDatabase, production.rebuildDatabase)
    }

    func testProductionPathsPreserveExistingLocations() {
        let paths = DatabasePaths.make(
            homeDirectory: "/Users/test",
            environment: .production
        )

        XCTAssertEqual(paths.directory, "/Users/test/.monitor-agent")
        XCTAssertEqual(paths.database, "/Users/test/.monitor-agent/monitor.db")
        XCTAssertEqual(paths.rebuildDatabase, "/Users/test/.monitor-agent/monitor-rebuild.tmp.db")
    }

    func testInstalledApplicationUsesProductionEnvironment() {
        XCTAssertEqual(
            DatabaseEnvironment.resolve(
                bundlePath: "/Applications/MonitorAgent.app",
                bundleIdentifier: DatabaseEnvironment.productionBundleIdentifier
            ),
            .production
        )
    }

    func testBareExecutablesUseDevelopmentEnvironmentRegardlessOfBuildConfiguration() {
        for bundlePath in [
            "/workspace/.build/debug/MonitorAgent",
            "/workspace/.build/release/MonitorAgent",
        ] {
            XCTAssertEqual(
                DatabaseEnvironment.resolve(
                    bundlePath: bundlePath,
                    bundleIdentifier: nil
                ),
                .development
            )
        }
    }

    func testApplicationWithUnexpectedBundleIdentifierUsesDevelopmentEnvironment() {
        XCTAssertEqual(
            DatabaseEnvironment.resolve(
                bundlePath: "/Applications/MonitorAgent.app",
                bundleIdentifier: "com.example.monitor-agent"
            ),
            .development
        )
    }

    func testCurrentTestRunnerUsesDevelopmentPaths() {
        XCTAssertTrue(DatabasePaths.current.directory.hasSuffix("/.monitor-agent/development"))
    }
}
