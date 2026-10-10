import Foundation

/// PluginManager calls these synchronous Host hooks inside its serialized
/// mutation transaction. Hooks must not await or synchronously wait on Manager.
@MainActor
public protocol PluginManagerLifecycleHandling: AnyObject, Sendable {
    func pluginDidLoad(_ package: ValidatedPluginPackage, isEnabled: Bool)
    func pluginDidChangeEnablement(id: String, isEnabled: Bool)
    func pluginWillUnload(id: String)
}

public nonisolated enum PluginStopReason: String, Equatable, Sendable {
    case disabled, unloaded, suspended, stopped, startFailed, shutdown
}

public nonisolated enum PluginLifecycleFailure: String, Equatable, Sendable {
    case startFailed, stopFailed
}

public nonisolated enum PluginExecutionError: Error, Equatable, LocalizedError, Sendable {
    case pluginNotFound(String)
    case inactiveExecution
    case sourceMismatch

    public var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id): "Plugin \(id.debugDescription) has no lifecycle registration."
        case .inactiveExecution: "The plugin execution session is no longer active."
        case .sourceMismatch: "The Activity does not belong to this plugin execution session."
        }
    }
}

public nonisolated struct PluginLifecycleSnapshot: Equatable, Sendable {
    public let id: String
    public let state: PluginLifecycleState
    public let isEnabled: Bool
    public let lastFailure: PluginLifecycleFailure?
}

/// T21 defines the Host contract; T22 supplies an isolated JavaScriptCore
/// implementation. Teardown synchronously revokes admission and pending work;
/// already executing JavaScript releases its VM after returning on its worker.
@MainActor
public protocol PluginLifecycleRuntime: AnyObject {
    func onStart(context: PluginExecutionContext) throws
    func onStop(reason: PluginStopReason) throws
    func teardown()
}

/// A capability for one admission to running. Old Tasks and action handlers
/// keep an old token, even after the same plugin is enabled or resumed again.
@MainActor
public final class PluginExecutionContext {
    public let id: String
    public let source: ActivitySource
    private let token: UUID
    private weak var bridge: PluginLifecycleBridge?

    fileprivate init(id: String, token: UUID, bridge: PluginLifecycleBridge) {
        self.id = id
        source = ActivitySource(kind: .plugin, identifier: id)
        self.token = token
        self.bridge = bridge
    }

    public func perform(_ callback: () throws -> Void) throws {
        guard let bridge, bridge.accepts(id: id, token: token) else {
            throw PluginExecutionError.inactiveExecution
        }
        try callback()
    }

    public func publish(_ activity: IslandActivity, maximumActivities: Int? = nil) throws {
        try perform {
            guard activity.source == source else { throw PluginExecutionError.sourceMismatch }
            try bridge?.publish(activity, maximumActivities: maximumActivities)
        }
    }

    public func endActivity(id: String) throws {
        try perform { try bridge?.endActivity(id: id, source: source) }
    }

    /// Host-only lookup used to apply a validated partial update. A plugin
    /// cannot choose the source or obtain a native Activity reference in JS.
    func activity(id: String) throws -> IslandActivity? {
        var result: IslandActivity?
        try perform { result = bridge?.activity(id: id, source: source) }
        return result
    }

    func updateActivity(_ activity: IslandActivity) throws {
        try perform {
            guard activity.source == source else { throw PluginExecutionError.sourceMismatch }
            try bridge?.updateActivity(activity)
        }
    }

    public func registerActionHandler(_ handler: @escaping ActionRouter.Handler) throws {
        try perform {
            bridge?.registerHandler(source: source) { [self] action in
                try? perform { handler(action) }
            }
        }
    }

    /// Host-only delivery gate. The original render token must travel with
    /// the action; resolving a fresh token by ID would authorize stale clicks.
    func isActionActive(_ action: RoutedActivityAction) -> Bool {
        var result = false
        try? perform {
            guard action.source == source else { return }
            result = bridge?.isActionActive(action) ?? false
        }
        return result
    }

    /// Worker results carry this session's token. A late failure from a removed
    /// or restarted runtime must never stop the replacement execution.
    @discardableResult
    public func reportFailure(_ failure: PluginLifecycleFailure) -> Bool {
        bridge?.reportFailure(id: id, token: token, failure: failure) ?? false
    }
}

/// The production execution, Activity, and interaction boundary. Enablement
/// remains persisted in Manager; lifecycle state is recomputed in each launch.
@MainActor
public final class PluginLifecycleBridge: PluginManagerLifecycleHandling {
    public typealias RuntimeFactory = @MainActor (ValidatedPluginPackage) throws -> any PluginLifecycleRuntime

    private final class Entry {
        let package: ValidatedPluginPackage
        var lifecycle = PluginLifecycle()
        var isEnabled: Bool
        var token: UUID?
        var lastExecutionToken: UUID?
        var runtime: (any PluginLifecycleRuntime)?
        var lastFailure: PluginLifecycleFailure?
        var isTransitioning = false
        var isStarting = false

        init(package: ValidatedPluginPackage, isEnabled: Bool) {
            self.package = package
            self.isEnabled = isEnabled
        }

        var source: ActivitySource { .init(kind: .plugin, identifier: package.manifest.id) }
    }

    private let activityManager: ActivityManager
    private let actionRouter: ActionRouter
    private let runtimeFactory: RuntimeFactory?
    private var entries: [String: Entry] = [:]
    private var isSleeping = false
    private var isLowBattery = false
    private var isShutdown = false

    public init(
        activityManager: ActivityManager,
        actionRouter: ActionRouter,
        runtimeFactory: RuntimeFactory? = nil
    ) {
        self.activityManager = activityManager
        self.actionRouter = actionRouter
        self.runtimeFactory = runtimeFactory
        activityManager.requirePluginActivation()
    }

    public func snapshot(id: String) -> PluginLifecycleSnapshot? {
        guard let entry = entries[id] else { return nil }
        return .init(id: id, state: entry.lifecycle.state, isEnabled: entry.isEnabled, lastFailure: entry.lastFailure)
    }

    public func allowsExecution(id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return !isShutdown && entry.isEnabled && entry.lifecycle.state.allowsExecution && entry.token != nil
    }

    public func pluginDidLoad(_ package: ValidatedPluginPackage, isEnabled: Bool) {
        let id = package.manifest.id
        if entries[id] != nil { pluginWillUnload(id: id) }
        guard !isShutdown else { return }
        let entry = Entry(package: package, isEnabled: isEnabled)
        entries[id] = entry
        _ = try? entry.lifecycle.transition(.load)
        closeSource(entry.source)
        if isEnabled { startIfAllowed(entry) }
        else { _ = try? entry.lifecycle.transition(.disable) }
    }

    public func pluginDidChangeEnablement(id: String, isEnabled: Bool) {
        guard let entry = entries[id], !isShutdown else { return }
        entry.isEnabled = isEnabled
        if !isEnabled {
            endExecution(entry, event: .disable, reason: .disabled)
            return
        }
        if entry.lifecycle.state == .disabled {
            _ = try? entry.lifecycle.transition(.enable)
            _ = try? entry.lifecycle.transition(.load)
        } else if entry.lifecycle.state == .stopped {
            _ = try? entry.lifecycle.transition(.load)
        }
        startIfAllowed(entry)
    }

    public func pluginWillUnload(id: String) {
        guard let entry = entries[id] else { return }
        endExecution(entry, event: .disable, reason: .unloaded)
        entries.removeValue(forKey: id)
    }

    /// Multiple suspension reasons are evaluated together. A wake event alone
    /// cannot resume an execution while its low-battery condition remains.
    public func setEnvironment(isSleeping: Bool, isLowBattery: Bool) {
        self.isSleeping = isSleeping
        self.isLowBattery = isLowBattery
        guard !isShutdown else { return }
        for id in entries.keys.sorted() {
            guard let entry = entries[id] else { continue }
            if isSleeping || isLowBattery {
                if entry.lifecycle.state == .running {
                    endExecution(entry, event: .suspend, reason: .suspended)
                }
            } else {
                startIfAllowed(entry)
            }
        }
    }

    public func stop(id: String) throws {
        guard let entry = entries[id] else { throw PluginExecutionError.pluginNotFound(id) }
        guard [.loaded, .running, .suspended].contains(entry.lifecycle.state) else { return }
        endExecution(entry, event: .stop, reason: .stopped)
    }

    /// App termination closes admission synchronously. A late discovery or
    /// enablement callback cannot start new work after this point.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for id in entries.keys.sorted() {
            guard let entry = entries[id] else { continue }
            if [.loaded, .running, .suspended].contains(entry.lifecycle.state) {
                endExecution(entry, event: .stop, reason: .shutdown)
            } else {
                closeSource(entry.source)
            }
        }
    }

    fileprivate func accepts(id: String, token: UUID) -> Bool {
        allowsExecution(id: id) && entries[id]?.token == token
    }

    fileprivate func reportFailure(id: String, token: UUID, failure: PluginLifecycleFailure) -> Bool {
        guard let entry = entries[id], entry.lastExecutionToken == token else { return false }
        switch failure {
        case .startFailed:
            guard accepts(id: id, token: token) else { return false }
            entry.lastFailure = .startFailed
            endExecution(entry, event: .stop, reason: .startFailed)
        case .stopFailed:
            guard entry.token == nil else { return false }
            entry.lastFailure = .stopFailed
        }
        return true
    }

    fileprivate func publish(_ activity: IslandActivity, maximumActivities: Int?) throws {
        activityManager.processDeadlines()
        if let maximumActivities, activityManager.activity(id: activity.id) == nil,
           activityManager.activityCount(for: activity.source) >= maximumActivities {
            throw ActivityManagerError.quotaExceeded
        }
        try activityManager.publish(activity)
    }

    fileprivate func activity(id: String, source: ActivitySource) -> IslandActivity? {
        activityManager.processDeadlines()
        guard let activity = activityManager.activity(id: id), activity.source == source else { return nil }
        return activity
    }

    fileprivate func updateActivity(_ activity: IslandActivity) throws {
        try activityManager.update(activity)
    }

    fileprivate func endActivity(id: String, source: ActivitySource) throws {
        try activityManager.end(id: id, source: source)
    }

    fileprivate func registerHandler(source: ActivitySource, handler: @escaping ActionRouter.Handler) {
        actionRouter.register(source: source, handler: handler)
    }

    fileprivate func isActionActive(_ action: RoutedActivityAction) -> Bool {
        actionRouter.isAdmitted(action)
    }

    private func startIfAllowed(_ entry: Entry) {
        guard !isShutdown, !entry.isTransitioning, !entry.isStarting,
              entry.isEnabled, !isSleeping, !isLowBattery,
              [.loaded, .suspended].contains(entry.lifecycle.state), let runtimeFactory else { return }
        entry.isStarting = true
        defer { entry.isStarting = false }
        let runtime: any PluginLifecycleRuntime
        do {
            runtime = try runtimeFactory(entry.package)
        } catch {
            guard entries[entry.package.manifest.id] === entry else { return }
            entry.lastFailure = .startFailed
            endExecution(entry, event: .stop, reason: .startFailed)
            return
        }
        // Factories are Host callbacks and may synchronously alter lifecycle
        // or system conditions. Recheck admission before invoking onStart.
        guard entries[entry.package.manifest.id] === entry,
              !isShutdown, entry.isEnabled, !isSleeping, !isLowBattery,
              [.loaded, .suspended].contains(entry.lifecycle.state) else {
            runtime.teardown()
            return
        }
        let token = UUID()
        entry.runtime = runtime
        entry.token = token
        entry.lastExecutionToken = token
        entry.lastFailure = nil
        _ = try? entry.lifecycle.transition(entry.lifecycle.state == .suspended ? .resume : .start)
        activityManager.setPluginSourceEnabled(true, for: entry.source)
        actionRouter.setEnabled(true, for: entry.source)
        do {
            try runtime.onStart(context: .init(id: entry.package.manifest.id, token: token, bridge: self))
        } catch {
            guard entry.token == token else { return }
            entry.lastFailure = .startFailed
            endExecution(entry, event: .stop, reason: .startFailed)
        }
    }

    private func closeSource(_ source: ActivitySource) {
        activityManager.setPluginSourceEnabled(false, for: source)
        actionRouter.setEnabled(false, for: source)
        actionRouter.unregisterAll(for: source)
        activityManager.endAll(source: source)
    }

    private func endExecution(_ entry: Entry, event: PluginLifecycleEvent, reason: PluginStopReason) {
        entry.isTransitioning = true
        defer { entry.isTransitioning = false }
        entry.token = nil
        _ = try? entry.lifecycle.transition(event)
        closeSource(entry.source)
        guard let runtime = entry.runtime else { return }
        entry.runtime = nil
        do { try runtime.onStop(reason: reason) }
        catch { entry.lastFailure = .stopFailed }
        runtime.teardown()
        // A Host runtime cleanup callback also cannot retain plugin UI.
        activityManager.endAll(source: entry.source)
    }
}
