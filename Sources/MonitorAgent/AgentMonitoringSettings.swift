import Combine
import Foundation

protocol CursorOperationCancellation: AnyObject {
    var isCursorCancelled: Bool { get }

    func withActiveCursor<T>(
        perform operation: () throws -> T
    ) rethrows -> T?
}

final class AgentMonitoringSettings: ObservableObject {
    static let shared = AgentMonitoringSettings()

    @Published var enabledAgents: Set<AgentID> {
        didSet {
            guard enabledAgents != oldValue else { return }
            persist()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let rawValues = defaults.stringArray(forKey: Keys.enabledAgents) else {
            enabledAgents = Set(AgentID.allCases)
            return
        }
        enabledAgents = Set(rawValues.compactMap(AgentID.init(rawValue:)))
    }

    func isEnabled(_ agent: AgentID) -> Bool {
        enabledAgents.contains(agent)
    }

    private func persist() {
        let rawValues = AgentID.allCases
            .filter(enabledAgents.contains)
            .map(\.rawValue)
        defaults.set(rawValues, forKey: Keys.enabledAgents)
    }

    private enum Keys {
        static let enabledAgents = "monitoredAgents"
    }
}

final class AgentSyncCancellation {
    private let lock = NSLock()
    private var enabledAgents: Set<AgentID>

    init(enabledAgents: Set<AgentID>) {
        self.enabledAgents = enabledAgents
    }

    func disableAgents(notIn enabledAgents: Set<AgentID>) {
        lock.lock()
        self.enabledAgents.formIntersection(enabledAgents)
        lock.unlock()
    }

    func isEnabled(_ agent: AgentID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledAgents.contains(agent)
    }

    func withEnabledAgent<T>(
        _ agent: AgentID,
        perform operation: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard enabledAgents.contains(agent) else { return nil }
        return try operation()
    }
}

extension AgentSyncCancellation: CursorOperationCancellation {
    var isCursorCancelled: Bool {
        !isEnabled(.cursor)
    }

    func withActiveCursor<T>(
        perform operation: () throws -> T
    ) rethrows -> T? {
        try withEnabledAgent(.cursor, perform: operation)
    }
}
