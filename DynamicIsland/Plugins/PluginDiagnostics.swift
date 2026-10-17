import Foundation

public nonisolated enum PluginDiagnosticCategory: String, Equatable, Sendable {
    case pluginMessage, runtimeFailure, lifecycleFailure
    case actionFailure, actionLimit, watchdogIsolation, persistenceFailure, restart
    case compatibilityFailure
}

/// Diagnostic text is chosen from Host constants. This type has no arbitrary
/// string case, so JS messages, exception values, URLs and user data cannot
/// become retained diagnostic text or codes.
public nonisolated enum PluginDiagnosticCode: Equatable, Sendable {
    case pluginMessage
    case runtime(PluginRuntimeErrorCode)
    case startFailed, stopFailed, actionHandlerFailed, actionHandlerLimitExceeded
    case automaticDisable, stateWriteFailed, restartRequested, restarted

    public var value: String {
        switch self {
        case .pluginMessage: "pluginMessage"
        case .runtime(let code): code.rawValue
        case .startFailed: "startFailed"
        case .stopFailed: "stopFailed"
        case .actionHandlerFailed: "actionHandlerFailed"
        case .actionHandlerLimitExceeded: "actionHandlerLimitExceeded"
        case .automaticDisable: "automaticDisable"
        case .stateWriteFailed: "stateWriteFailed"
        case .restartRequested: "restartRequested"
        case .restarted: "restarted"
        }
    }

    public var message: String {
        switch self {
        case .pluginMessage: "Plugin log message omitted."
        case .runtime: "Plugin Runtime failed."
        case .startFailed: "Plugin execution could not start."
        case .stopFailed: "Plugin cleanup failed."
        case .actionHandlerFailed: "Action handler failed."
        case .actionHandlerLimitExceeded: "Action handler limit exceeded."
        case .automaticDisable: "The Host disabled this plugin after repeated serious failures."
        case .stateWriteFailed: "The Host could not persist plugin isolation."
        case .restartRequested: "The Host received a plugin restart request."
        case .restarted: "The Host restarted this plugin."
        }
    }
}

public nonisolated struct PluginDiagnosticEntry: Equatable, Sendable {
    public let pluginID: String
    public let level: PluginLogLevel
    public let category: PluginDiagnosticCategory
    public let phase: PluginRuntimePhase?
    public let code: String
    public let message: String
    public let timestamp: Date
    public let sequence: UInt64

    fileprivate init(pluginID: String, level: PluginLogLevel, category: PluginDiagnosticCategory,
                     phase: PluginRuntimePhase?, code: PluginDiagnosticCode, timestamp: Date, sequence: UInt64) {
        self.pluginID = pluginID
        self.level = level
        self.category = category
        self.phase = phase
        self.code = code.value
        message = code.message
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

/// One Host-owned, process-only diagnostic inventory. It retains at most 100
/// records per plugin, 1,000 records globally, and 128 plugin IDs. Reading a
/// snapshot does not expose JavaScript or native resource objects.
@MainActor
public final class PluginDiagnosticsStore {
    public nonisolated static let maximumRecordsPerPlugin = 100
    public nonisolated static let maximumRecords = 1_000
    public nonisolated static let maximumPluginIDs = 128

    private let clock: @MainActor () -> Date
    private var entries: [PluginDiagnosticEntry] = []
    private var sequence: UInt64 = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]

    public init(clock: @escaping @MainActor () -> Date = { Date() }) { self.clock = clock }

    @discardableResult
    public func recordPluginMessage(pluginID: String, level: PluginLogLevel) -> PluginDiagnosticEntry? {
        record(pluginID: pluginID, level: level, category: .pluginMessage, code: .pluginMessage)
    }

    @discardableResult
    public func recordRuntimeFailure(pluginID: String, failure: PluginRuntimeFailure) -> PluginDiagnosticEntry? {
        // The failure's message is intentionally never read or retained.
        record(pluginID: pluginID, level: .error, category: .runtimeFailure,
               code: .runtime(failure.code), phase: failure.phase)
    }

    @discardableResult
    public func recordLifecycleFailure(pluginID: String, failure: PluginLifecycleFailure) -> PluginDiagnosticEntry? {
        record(pluginID: pluginID, level: .error, category: .lifecycleFailure,
               code: failure == .startFailed ? .startFailed : .stopFailed,
               phase: failure == .stopFailed ? .stop : nil)
    }

    @discardableResult
    public func recordWatchdogIsolation(pluginID: String) -> PluginDiagnosticEntry? {
        record(pluginID: pluginID, level: .error, category: .watchdogIsolation, code: .automaticDisable)
    }

    @discardableResult
    public func recordPersistenceFailure(pluginID: String) -> PluginDiagnosticEntry? {
        record(pluginID: pluginID, level: .error, category: .persistenceFailure, code: .stateWriteFailed)
    }

    @discardableResult
    public func record(pluginID: String, level: PluginLogLevel, category: PluginDiagnosticCategory,
                       code: PluginDiagnosticCode, phase: PluginRuntimePhase? = nil) -> PluginDiagnosticEntry? {
        guard PluginManifest.isValidPluginID(pluginID) else { return nil }
        // Sequence is process-scoped and survives clearing. Saturation avoids
        // wraparound; reaching UInt64.max cannot occur in a practical lifetime.
        if sequence < UInt64.max { sequence += 1 }
        let entry = PluginDiagnosticEntry(pluginID: pluginID, level: level, category: category,
            phase: phase, code: code, timestamp: clock(), sequence: sequence)
        entries.append(entry)

        let excessForPlugin = entries.filter { $0.pluginID == pluginID }.count - Self.maximumRecordsPerPlugin
        if excessForPlugin > 0 {
            var remaining = excessForPlugin
            entries.removeAll { entry in
                guard entry.pluginID == pluginID, remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        }
        if entries.count > Self.maximumRecords { entries.removeFirst(entries.count - Self.maximumRecords) }

        var lastSequences: [String: UInt64] = [:]
        for entry in entries { lastSequences[entry.pluginID] = entry.sequence }
        if lastSequences.count > Self.maximumPluginIDs,
           let oldest = lastSequences.min(by: { $0.value < $1.value })?.key {
            entries.removeAll { $0.pluginID == oldest }
        }
        notifyChanges()
        return entry
    }

    public func records(for pluginID: String) -> [PluginDiagnosticEntry] { entries.filter { $0.pluginID == pluginID } }
    public func allRecords() -> [PluginDiagnosticEntry] { entries }
    public func clear(for pluginID: String) {
        let count = entries.count
        entries.removeAll { $0.pluginID == pluginID }
        if entries.count != count { notifyChanges() }
    }
    public func clearAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        notifyChanges()
    }

    /// Host UI observers should enqueue a short refresh task, capture their
    /// owner weakly, and unregister when the panel/model is released.
    @discardableResult
    public func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func removeChangeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notifyChanges() {
        // Registration changes during a callback affect the next event.
        let callbacks = Array(observers.values)
        callbacks.forEach { $0() }
    }
}
