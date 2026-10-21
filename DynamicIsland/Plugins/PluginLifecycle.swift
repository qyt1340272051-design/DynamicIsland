import Foundation

/// Host-owned execution state for one validated plugin. Enablement is persisted
/// separately; a restored preference never proves that plugin code is running.
public nonisolated enum PluginLifecycleState: String, CaseIterable, Codable, Equatable, Sendable {
    case installed
    case loaded
    case running
    case suspended
    case stopped
    case disabled

    /// Runtime entry points must consult this gate before invoking plugin code.
    public var allowsExecution: Bool { self == .running }
}

/// The small set of operations accepted by the plugin lifecycle state machine.
public nonisolated enum PluginLifecycleEvent: String, CaseIterable, Codable, Equatable, Sendable {
    case load
    case start
    case suspend
    case resume
    case stop
    case disable
    case enable
}

public nonisolated enum PluginLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition(from: PluginLifecycleState, event: PluginLifecycleEvent)

    public var code: String { "invalidLifecycleTransition" }

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let state, let event):
            "Plugin lifecycle cannot apply \(event.rawValue.debugDescription) while \(state.rawValue.debugDescription)."
        }
    }
}

/// Pure state machine shared by Manager and the future Runtime. It owns no
/// JavaScript context, Activity, system observer, or asynchronous work.
public nonisolated struct PluginLifecycle: Equatable, Sendable {
    public private(set) var state: PluginLifecycleState

    public init(state: PluginLifecycleState = .installed) {
        self.state = state
    }

    /// Invalid transitions throw without changing the current state. Repeated
    /// disable is safe so shutdown paths can revoke execution unconditionally.
    @discardableResult
    public mutating func transition(_ event: PluginLifecycleEvent) throws -> PluginLifecycleState {
        let nextState: PluginLifecycleState
        switch (state, event) {
        case (.installed, .load), (.stopped, .load):
            nextState = .loaded
        case (.loaded, .start), (.suspended, .resume):
            nextState = .running
        case (.running, .suspend):
            nextState = .suspended
        case (.loaded, .stop), (.running, .stop), (.suspended, .stop):
            nextState = .stopped
        case (_, .disable):
            nextState = .disabled
        case (.disabled, .enable):
            nextState = .installed
        default:
            throw PluginLifecycleError.invalidTransition(from: state, event: event)
        }
        state = nextState
        return nextState
    }
}
