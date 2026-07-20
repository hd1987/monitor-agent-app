import XCTest
@testable import MonitorAgent

final class RuntimeEnvironmentTests: XCTestCase {
    func testInstalledApplicationUsesProductionMode() {
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/Applications/MonitorAgent.app",
            bundleIdentifier: RuntimeEnvironment.productionBundleIdentifier,
            homeDirectory: "/Users/test",
            environment: [:]
        )

        XCTAssertEqual(runtime.mode, .production)
        XCTAssertEqual(runtime.productionDatabasePath, "/Users/test/.monitor-agent/monitor.db")
        XCTAssertTrue(runtime.featurePolicy.allowsGlobalShortcutRegistration)
        XCTAssertTrue(runtime.featurePolicy.allowsUpdateChecks)
        XCTAssertTrue(runtime.featurePolicy.allowsLiveQuotaRefresh)
        XCTAssertTrue(runtime.featurePolicy.allowsLaunchAtLogin)
        XCTAssertTrue(runtime.featurePolicy.allowsExternalConfigSaving)
    }

    func testBareExecutableUsesIsolatedDevelopmentMode() {
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/workspace/.build/debug/MonitorAgent",
            bundleIdentifier: nil,
            homeDirectory: "/Users/test",
            environment: [:]
        )

        XCTAssertEqual(runtime.mode, .development)
        XCTAssertFalse(runtime.featurePolicy.allowsGlobalShortcutRegistration)
        XCTAssertFalse(runtime.featurePolicy.allowsUpdateChecks)
        XCTAssertFalse(runtime.featurePolicy.allowsLiveQuotaRefresh)
        XCTAssertFalse(runtime.featurePolicy.allowsLaunchAtLogin)
        XCTAssertFalse(runtime.featurePolicy.allowsExternalConfigSaving)
    }

    func testBareExecutableCannotForceProductionMode() {
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/workspace/.build/release/MonitorAgent",
            bundleIdentifier: nil,
            homeDirectory: "/Users/test",
            environment: ["MONITOR_AGENT_RUNTIME": "production"]
        )

        XCTAssertEqual(runtime.mode, .development)
    }

    func testInstalledApplicationCanBeForcedIntoRestrictedDevelopmentMode() {
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/Applications/MonitorAgent.app",
            bundleIdentifier: RuntimeEnvironment.productionBundleIdentifier,
            homeDirectory: "/Users/test",
            environment: ["MONITOR_AGENT_RUNTIME": "development"]
        )

        XCTAssertEqual(runtime.mode, .development)
        XCTAssertFalse(runtime.featurePolicy.allowsLaunchAtLogin)
    }

    func testDevelopmentModeCanExplicitlyEnableLiveQuota() {
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/workspace/.build/debug/MonitorAgent",
            bundleIdentifier: nil,
            homeDirectory: "/Users/test",
            environment: ["MONITOR_AGENT_ENABLE_LIVE_QUOTA": "1"]
        )

        XCTAssertTrue(runtime.featurePolicy.allowsLiveQuotaRefresh)
    }

    func testInMemoryPreferencesDoNotShareValuesAcrossInstances() {
        let first = InMemoryPreferencesStore()
        let second = InMemoryPreferencesStore()

        first.set("dark", forKey: "theme")

        XCTAssertEqual(first.string(forKey: "theme"), "dark")
        XCTAssertNil(second.string(forKey: "theme"))
    }

    func testDevelopmentDatabaseFailureFallsBackToAvailableMemoryStorage() {
        enum OpenError: Error { case expected }
        let homeDirectory = NSTemporaryDirectory() + "/monitor-agent-fallback-\(UUID().uuidString)"
        let runtime = RuntimeEnvironment.resolve(
            bundlePath: "/workspace/.build/debug/MonitorAgent",
            bundleIdentifier: nil,
            homeDirectory: homeDirectory,
            environment: [:]
        )

        let database = DatabaseManager.openForRuntime(
            runtime,
            opener: { _ in throw OpenError.expected },
            logError: { _ in }
        )

        XCTAssertTrue(database.isAvailable)
        XCTAssertFalse(database.isPersistent)
        XCTAssertNil(database.ownedRebuildDatabasePath)

        let productionTemporaryURL = URL(fileURLWithPath: runtime.rebuildDatabasePath)
        try? FileManager.default.createDirectory(
            at: productionTemporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertNoThrow(try Data("production".utf8).write(to: productionTemporaryURL))
        database.cleanUpTemporaryRebuildDatabase()
        XCTAssertTrue(FileManager.default.fileExists(atPath: productionTemporaryURL.path))
    }

    func testDevelopmentDatabaseSeedsAnIndependentInMemorySnapshot() throws {
        let homeDirectory = NSTemporaryDirectory() + "/monitor-agent-runtime-\(UUID().uuidString)"
        let productionDirectory = homeDirectory + "/.monitor-agent"
        let productionPath = productionDirectory + "/monitor.db"
        let productionDatabase = try DatabaseManager(path: productionPath)
        productionDatabase.insertRecords([
            ParsedRecord(
                requestId: "seed",
                appType: "claude",
                model: "test-model",
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                sessionId: "session",
                createdAt: Int(Date().timeIntervalSince1970)
            )
        ])
        productionDatabase.close()
        let productionDataBeforeDevelopment = try Data(contentsOf: URL(fileURLWithPath: productionPath))
        let runtime = RuntimeEnvironment(
            mode: .development,
            productionDataDirectory: productionDirectory,
            featurePolicy: RuntimeFeaturePolicy(
                allowsGlobalShortcutRegistration: false,
                allowsUpdateChecks: false,
                allowsLiveQuotaRefresh: false,
                allowsLaunchAtLogin: false,
                allowsExternalConfigSaving: false
            )
        )

        let developmentDatabase = try DatabaseManager(runtime: runtime)
        developmentDatabase.insertRecords([
            ParsedRecord(
                requestId: "development-only",
                appType: "claude",
                model: "test-model",
                inputTokens: 20,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                sessionId: "session",
                createdAt: Int(Date().timeIntervalSince1970)
            )
        ])

        XCTAssertFalse(developmentDatabase.isPersistent)
        XCTAssertEqual(
            developmentDatabase.fetchStats(app: .all, range: .allTime).totalRequests,
            2
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: productionPath)),
            productionDataBeforeDevelopment
        )

        let unchangedProductionDatabase = try DatabaseManager(path: productionPath)
        XCTAssertEqual(
            unchangedProductionDatabase.fetchStats(app: .all, range: .allTime).totalRequests,
            1
        )
    }

    func testProcessLockRejectsSecondOwnerAndReleasesOnDeinit() throws {
        let lockPath = NSTemporaryDirectory() + "/monitor-agent-lock-\(UUID().uuidString)/instance.lock"
        var firstLock: ProcessInstanceLock? = try ProcessInstanceLock(path: lockPath)

        XCTAssertThrowsError(try ProcessInstanceLock(path: lockPath)) { error in
            XCTAssertEqual(error as? ProcessInstanceLockError, .alreadyLocked)
        }

        firstLock = nil
        XCTAssertNoThrow(try ProcessInstanceLock(path: lockPath))
        XCTAssertNil(firstLock)
    }

    func testProcessLockRejectsOwnerInAnotherProcess() throws {
        let directory = NSTemporaryDirectory() + "/monitor-agent-process-lock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let lockPath = directory + "/instance.lock"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl, os, sys, time; f = open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); os.write(1, bytes([1])); time.sleep(10)",
            lockPath,
        ]
        process.standardOutput = output
        try process.run()
        let ready = output.fileHandleForReading.readData(ofLength: 1)
        XCTAssertEqual(ready, Data([1]))
        XCTAssertThrowsError(try ProcessInstanceLock(path: lockPath)) { error in
            XCTAssertEqual(error as? ProcessInstanceLockError, .alreadyLocked)
        }

        process.terminate()
        process.waitUntilExit()
        XCTAssertNoThrow(try ProcessInstanceLock(path: lockPath))
    }
}
