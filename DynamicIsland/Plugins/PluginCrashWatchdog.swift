import CryptoKit
import Foundation

/// Fixed categories reported by trusted Host runtime boundaries. Plugin logs,
/// requested Broker failures, and stop-hook diagnostics are never incidents.
public nonisolated enum PluginSeriousFailureKind: String, Equatable, Sendable {
    case runtimeStart
    case actionException
    case actionRejection
}

public nonisolated enum PluginCrashWatchdogError: Error, Equatable, LocalizedError, Sendable {
    case invalidPackage
    case quotaExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "The Host watchdog package registration is invalid."
        case .quotaExceeded: "The Host watchdog registration limit was reached."
        }
    }
}

/// A Host-owned quarantine generation. An asynchronous persistence callback
/// must still match both this incident and the immutable installed package.
public nonisolated struct PluginCrashIncident: Equatable, Sendable {
    public let id: UUID
    public let pluginID: String
    public let packageFingerprint: String
    public let kind: PluginSeriousFailureKind
}

/// Bounded, process-local crash history. Quarantine is sticky until an explicit
/// Host clear or package replacement; ordinary restart preserves failure times.
/// This watchdog observes exceptions, not a VM thread that is stuck forever.
@MainActor
public final class PluginCrashWatchdog {
    public nonisolated struct Snapshot: Equatable, Sendable {
        public let id: String
        public let recentFailureCount: Int
        public let quarantine: PluginCrashIncident?
    }

    private final class Entry {
        let fingerprint: String
        var failures: [TimeInterval] = []
        var quarantine: PluginCrashIncident?

        init(fingerprint: String) { self.fingerprint = fingerprint }
    }

    private let clock: @MainActor () -> TimeInterval
    private var lastInstant: TimeInterval = 0
    private var entries: [String: Entry] = [:]

    public init(clock: @escaping @MainActor () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.clock = clock
    }

    /// Register only a validated immutable Host package. Declaration ordering
    /// has no significance; code, version, or other metadata changes do.
    @discardableResult
    public func register(package: ValidatedPluginPackage) throws -> Snapshot {
        let id = package.manifest.id
        let fingerprint = try Self.fingerprint(package)
        if let current = entries[id], current.fingerprint == fingerprint {
            return snapshot(id: id)!
        }
        guard entries[id] != nil || entries.count < 128 else {
            throw PluginCrashWatchdogError.quotaExceeded
        }
        entries[id] = Entry(fingerprint: fingerprint)
        return Snapshot(id: id, recentFailureCount: 0, quarantine: nil)
    }

    public func snapshot(id: String) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        if let now = instant() { prune(entry, at: now) }
        return Snapshot(id: id, recentFailureCount: entry.failures.count,
                        quarantine: entry.quarantine)
    }

    public var registrationCount: Int { entries.count }

    /// Count only the Host's accepted current-session serious failure. The
    /// lifecycle validates its execution token before reaching this method.
    /// The third failure within 60 seconds creates exactly one new incident.
    @discardableResult
    public func recordFailure(kind: PluginSeriousFailureKind,
                              package: ValidatedPluginPackage) -> PluginCrashIncident? {
        let id = package.manifest.id
        guard let entry = entries[id], entry.quarantine == nil,
              let fingerprint = try? Self.fingerprint(package),
              entry.fingerprint == fingerprint, let now = instant() else { return nil }
        prune(entry, at: now)
        entry.failures.append(now)
        if entry.failures.count > 3 { entry.failures.removeFirst(entry.failures.count - 3) }
        guard entry.failures.count == 3 else { return nil }
        let incident = PluginCrashIncident(id: UUID(), pluginID: id,
                                          packageFingerprint: entry.fingerprint, kind: kind)
        entry.quarantine = incident
        return incident
    }

    /// Verify immediately before committing a delayed automatic-disable write.
    /// Clearing an incident or replacing code invalidates every old callback.
    public func isCurrent(incident: PluginCrashIncident,
                          package: ValidatedPluginPackage) -> Bool {
        guard incident.pluginID == package.manifest.id,
              let entry = entries[incident.pluginID], entry.quarantine == incident,
              let fingerprint = try? Self.fingerprint(package) else { return false }
        return entry.fingerprint == fingerprint && incident.packageFingerprint == fingerprint
    }

    /// Explicit Host retry clears this exact quarantine generation, retaining
    /// rolling failure history. Another failure inside the window re-isolates
    /// the same broken package instead of resetting its budget by toggling it.
    @discardableResult
    public func clearQuarantine(incident: PluginCrashIncident,
                                package: ValidatedPluginPackage) -> Bool {
        guard isCurrent(incident: incident, package: package) else { return false }
        entries[incident.pluginID]?.quarantine = nil
        return true
    }

    /// Forget only a confirmed uninstall. Unload/reload retains crash history.
    public func unregister(pluginID: String) {
        entries.removeValue(forKey: pluginID)
    }

    private func instant() -> TimeInterval? {
        let value = clock()
        guard value.isFinite, value >= 0 else { return nil }
        lastInstant = max(lastInstant, value)
        return lastInstant
    }

    private func prune(_ entry: Entry, at now: TimeInterval) {
        entry.failures.removeAll { now - $0 > 60 }
    }

    private nonisolated static func fingerprint(_ package: ValidatedPluginPackage) throws -> String {
        do {
            try package.manifest.validate()
            let manifest = package.manifest
            let metadata: [String: Any] = [
                "schemaVersion": manifest.schemaVersion,
                "id": manifest.id,
                "name": manifest.name,
                "developer": manifest.developer as Any? ?? NSNull(),
                "version": manifest.version.description,
                "engine": manifest.engine.rawValue,
                "entry": manifest.entry,
                "minimumHostVersion": manifest.minimumHostVersion.description,
                "permissions": manifest.permissions.map(\.rawValue).sorted(),
                "capabilities": manifest.capabilities.map(\.rawValue).sorted()
            ]
            let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            var hash = SHA256()
            hash.update(data: Data("DynamicIsland.PluginCrashWatchdog.v1\0".utf8))
            hash.update(data: bytes)
            hash.update(data: Data([0]))
            hash.update(data: Data(SHA256.hash(data: package.entrySource)))
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw PluginCrashWatchdogError.invalidPackage
        }
    }
}
