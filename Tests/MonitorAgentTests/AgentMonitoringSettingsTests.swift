import XCTest
@testable import MonitorAgent

final class AgentMonitoringSettingsTests: XCTestCase {
    func testMonitoringDefaultsToEveryAgent() {
        let (defaults, suiteName) = makeDefaults()

        let settings = AgentMonitoringSettings(defaults: defaults)

        XCTAssertEqual(settings.enabledAgents, Set(AgentID.allCases))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMonitoringPersistsSelectedAgentsIncludingEmptySelection() {
        let (defaults, suiteName) = makeDefaults()
        let settings = AgentMonitoringSettings(defaults: defaults)

        settings.enabledAgents = [.claude, .cursor]
        XCTAssertEqual(
            AgentMonitoringSettings(defaults: defaults).enabledAgents,
            [.claude, .cursor]
        )

        settings.enabledAgents = []
        XCTAssertTrue(AgentMonitoringSettings(defaults: defaults).enabledAgents.isEmpty)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAvailableFiltersAndCyclingSkipDisabledAgents() {
        let filters = AppFilter.available(for: [.claude, .cursor])

        XCTAssertEqual(filters, [.all, .claude, .cursor])
        XCTAssertEqual(AppFilter.all.cycled(in: filters), .claude)
        XCTAssertEqual(AppFilter.claude.cycled(in: filters), .cursor)
        XCTAssertEqual(AppFilter.all.cycled(in: filters, reverse: true), .cursor)
        XCTAssertEqual(AppFilter.codex.cycled(in: filters), .all)
    }

    func testSyncCancellationOnlyRemovesAgentsAndGuardsCommit() {
        let cancellation = AgentSyncCancellation(enabledAgents: Set(AgentID.allCases))

        cancellation.disableAgents(notIn: [.claude, .codex])
        cancellation.disableAgents(notIn: Set(AgentID.allCases))

        XCTAssertFalse(cancellation.isEnabled(.cursor))
        XCTAssertTrue(cancellation.isEnabled(.claude))
        var didCommitCursor = false
        let result = cancellation.withEnabledAgent(.cursor) {
            didCommitCursor = true
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(didCommitCursor)
    }

    func testAppStoreUpdatesItsInjectedMonitoringSettings() {
        let (defaults, suiteName) = makeDefaults()
        let settings = AgentMonitoringSettings(defaults: defaults)
        let store = AppStore(
            database: DatabaseManager(inMemory: true),
            monitoringSettings: settings,
            observeRefreshIntervalChanges: false
        )

        store.updateEnabledAgents([.cursor])

        XCTAssertEqual(settings.enabledAgents, [.cursor])
        XCTAssertEqual(store.enabledAgents, [.cursor])
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AgentMonitoringSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
