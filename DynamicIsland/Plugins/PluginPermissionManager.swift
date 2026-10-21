import CryptoKit
import Foundation

/// A declaration starts as requested. Only an explicit Host decision can grant
/// access; registration, enablement and Runtime startup never grant permissions.
public nonisolated enum PluginPermissionState: String, Codable, CaseIterable, Equatable, Sendable {
    case requested, granted, denied, revoked
}

public nonisolated enum PluginPermissionDecision: String, CaseIterable, Equatable, Sendable {
    case granted, denied, revoked

    fileprivate var state: PluginPermissionState {
        switch self {
        case .granted: .granted
        case .denied: .denied
        case .revoked: .revoked
        }
    }
}

public nonisolated enum PluginPermissionError: Error, Equatable, LocalizedError, Sendable {
    case notGranted, denied, revoked, undeclared, staleReview, persistenceFailed

    public var code: String {
        switch self {
        case .notGranted: "permissionNotGranted"
        case .denied: "permissionDenied"
        case .revoked: "permissionRevoked"
        case .undeclared: "permissionRequired"
        case .staleReview: "stalePermissionReview"
        case .persistenceFailed: "permissionPersistenceFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notGranted: "The Host has not granted the requested permission."
        case .denied: "The Host denied the requested permission."
        case .revoked: "The Host revoked the permission or its previous authorization."
        case .undeclared: "The permission is unknown or is not declared by this plugin."
        case .staleReview: "The permission review does not belong to the current plugin package."
        case .persistenceFailed: "The Host could not save the permission decision."
        }
    }
}

/// Immutable Host metadata for one package review. The scope prevents an old
/// approval from authorizing replacement code, even when the plugin ID matches.
/// Plugin JavaScript receives no review object or approval entry point.
public nonisolated struct PluginPermissionReview: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: SemanticVersion
    public let permissions: [PluginPermission]
    public let capabilities: [PluginCapability]
    public let scope: UUID

    fileprivate init(manifest: PluginManifest, scope: UUID) {
        id = manifest.id
        name = manifest.name
        version = manifest.version
        permissions = manifest.permissions.sorted { $0.rawValue < $1.rawValue }
        capabilities = manifest.capabilities.sorted { $0.rawValue < $1.rawValue }
        self.scope = scope
    }
}

public nonisolated struct PluginPermissionSnapshot: Equatable, Sendable {
    public let review: PluginPermissionReview
    public let states: [PluginPermission: PluginPermissionState]
}

/// One Broker call's authorization. A lease is checked again at the final
/// side effect or data delivery, independently of the Runtime lifecycle gate.
/// Regranting never reactivates a lease issued under an older generation.
public nonisolated struct PluginPermissionLease: Sendable {
    public let pluginID: String
    public let permission: PluginPermission
    private let gate: PluginPermissionGate
    private let generation: UUID

    fileprivate init(gate: PluginPermissionGate, generation: UUID,
                     pluginID: String, permission: PluginPermission) {
        self.gate = gate
        self.generation = generation
        self.pluginID = pluginID
        self.permission = permission
    }

    /// Keep this synchronous operation short; it must not reenter this lease,
    /// alter permissions or wait for the MainActor. Storage preparation happens
    /// before this gate; its final atomic replacement happens inside it.
    public func perform<T>(_ operation: () throws -> T) throws -> T {
        try gate.perform(generation: generation, operation)
    }

    /// Brokers bind the grant to the exact owner and permission they serve.
    public func perform<T>(pluginID: String, permission: PluginPermission,
                           _ operation: () throws -> T) throws -> T {
        guard self.pluginID == pluginID, self.permission == permission else {
            throw PluginPermissionError.undeclared
        }
        return try perform(operation)
    }

    /// Broker cancellation is notified after the permission lock is released.
    public func observeRevocation(_ callback: @escaping @Sendable () -> Void) -> PluginPermissionObservation {
        gate.observe(generation: generation, callback: callback)
    }
}

public nonisolated final class PluginPermissionObservation: @unchecked Sendable {
    private weak var gate: PluginPermissionGate?
    private let id: UUID

    fileprivate init(gate: PluginPermissionGate, id: UUID) {
        self.gate = gate
        self.id = id
    }

    public func cancel() { gate?.removeObserver(id) }
    deinit { cancel() }
}

/// Host authorization. Memory-only instances start requested; production loads
/// saved decisions for the exact immutable package before Runtime startup.
@MainActor
public final class PermissionManager {
    private final class Entry {
        let fingerprint: PluginPermissionFingerprint
        let manifest: PluginManifest
        let entrySource: Data
        let review: PluginPermissionReview
        let gates: [PluginPermission: PluginPermissionGate]
        let mayRestore: Bool
        var decisionGenerations: [PluginPermission: UUID] = [:]

        init(package: ValidatedPluginPackage, fingerprint: PluginPermissionFingerprint, mayRestore: Bool) {
            self.fingerprint = fingerprint
            self.mayRestore = mayRestore
            manifest = package.manifest
            entrySource = package.entrySource
            review = PluginPermissionReview(manifest: package.manifest, scope: UUID())
            gates = Dictionary(uniqueKeysWithValues: package.manifest.permissions.map {
                ($0, PluginPermissionGate())
            })
        }

        func revoke() {
            gates.values.forEach { $0.update(.revoked) }
        }

        func matches(package: ValidatedPluginPackage) -> Bool {
            // Runtime copies share these immutable bytes. Data equality can
            // accept that shared storage without hashing on the Broker path.
            (manifest == package.manifest || fingerprint.matches(manifest: package.manifest))
                && entrySource == package.entrySource
        }
    }

    private var entries: [String: Entry] = [:]
    private let decisionStore: PluginPermissionDecisionStore?
    private var preparedScopes: [String: UUID] = [:]
    private var forgottenIDs = Set<String>()
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var persistenceError: String?

    public init(decisionStore: PluginPermissionDecisionStore? = nil) { self.decisionStore = decisionStore }

    public func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }

    public func removeChangeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notifyObservers() { Array(observers.values).forEach { $0() } }

    /// The input is the Host's immutable validated package, never JS metadata.
    /// Repeated registration preserves this package's current decisions. Any
    /// manifest or entry-source change closes old gates before registering a
    /// new requested scope; returning to earlier bytes does not restore grants.
    @discardableResult
    public func request(package: ValidatedPluginPackage) -> PluginPermissionReview {
        let id = package.manifest.id
        if let current = entries[id], current.matches(package: package) {
            return current.review
        }
        let fingerprint = PluginPermissionFingerprint(package: package)
        let previous = entries[id]
        previous?.revoke()
        let entry = Entry(package: package, fingerprint: fingerprint,
                          mayRestore: previous == nil && !forgottenIDs.contains(id))
        entries[id] = entry
        preparedScopes.removeValue(forKey: id)
        notifyObservers()
        return entry.review
    }

    /// Manager awaits this step before starting JS. Returning to earlier code
    /// within this process cannot restore a previous authorization scope.
    public func prepare(package: ValidatedPluginPackage) async {
        let review = request(package: package)
        guard let decisionStore, preparedScopes[review.id] != review.scope,
              let entry = entries[review.id] else { return }
        await beginMutation()
        defer { endMutation() }
        guard entries[review.id] === entry, preparedScopes[review.id] != review.scope else { return }
        let decisionGenerations = entry.decisionGenerations
        do {
            let fingerprint = try Self.persistenceFingerprint(package: package)
            let saved = try await decisionStore.load()[review.id]
            guard entries[review.id] === entry else { return }
            if entry.mayRestore, let saved, saved.fingerprint == fingerprint,
               Set(saved.states.keys) == Set(entry.gates.keys) {
                for (permission, state) in saved.states
                    where decisionGenerations[permission] == nil && entry.decisionGenerations[permission] == nil {
                    entry.gates[permission]?.update(state)
                }
            } else {
                let requested = PluginPermissionDecisionRecord(pluginID: review.id, fingerprint: fingerprint,
                                                               states: entry.gates.mapValues { _ in .requested })
                try await decisionStore.replace(record: requested)
                guard entries[review.id] === entry else { return }
            }
            preparedScopes[review.id] = review.scope
            persistenceError = nil
        } catch {
            // No grant is restored on unreadable, corrupt or unwritable state.
            persistenceError = "授权记录无法读取或保存。未保存的批准不会生效。"
        }
        notifyObservers()
    }

    /// Approval commits to disk before becoming effective. Denial/revocation
    /// closes existing leases synchronously, even while disk work is queued.
    public func applyPersistentHostDecision(decision: PluginPermissionDecision,
                                            review: PluginPermissionReview,
                                            permission: PluginPermission) async throws {
        guard let entry = entries[review.id], entry.review == review else { throw PluginPermissionError.staleReview }
        guard let gate = entry.gates[permission] else { throw PluginPermissionError.undeclared }
        guard let decisionStore else {
            try applyHostDecision(decision: decision, review: review, permission: permission)
            return
        }
        let generation = UUID()
        entry.decisionGenerations[permission] = generation
        if decision != .granted {
            gate.update(decision.state)
            notifyObservers()
        }
        await beginMutation()
        defer { endMutation() }
        guard entries[review.id] === entry, entry.decisionGenerations[permission] == generation else {
            throw PluginPermissionError.staleReview
        }
        guard preparedScopes[review.id] == review.scope else { throw PluginPermissionError.persistenceFailed }
        do {
            let fingerprint = try Self.persistenceFingerprint(manifest: entry.manifest, entrySource: entry.entrySource)
            try await decisionStore.setDecision(pluginID: review.id, fingerprint: fingerprint,
                                                 permission: permission, state: decision.state)
            guard entries[review.id] === entry else { throw PluginPermissionError.staleReview }
            guard entry.decisionGenerations[permission] == generation else {
                // A synchronous administrative revoke may have superseded a
                // pending grant. Persist its current state before releasing FIFO.
                try await decisionStore.setDecision(pluginID: review.id, fingerprint: fingerprint,
                                                     permission: permission, state: gate.state)
                throw PluginPermissionError.staleReview
            }
            if decision == .granted { gate.update(.granted) }
            persistenceError = nil
            notifyObservers()
        } catch let error as PluginPermissionError { throw error }
        catch {
            persistenceError = decision == .granted
                ? "授权记录保存失败，批准未生效。" : "本次授权已撤销，授权记录保存失败。"
            notifyObservers()
            throw PluginPermissionError.persistenceFailed
        }
    }

    public func forgetPersisted(pluginID: String) async throws {
        unregister(pluginID: pluginID)
        guard let decisionStore else { return }
        await beginMutation()
        defer { endMutation() }
        do {
            try await decisionStore.remove(pluginID: pluginID)
            persistenceError = nil
        } catch {
            persistenceError = "本次授权已撤销，授权记录移除失败。"
            notifyObservers()
            throw PluginPermissionError.persistenceFailed
        }
        notifyObservers()
    }

    public nonisolated static func persistenceFingerprint(package: ValidatedPluginPackage) throws -> String {
        try persistenceFingerprint(manifest: package.manifest, entrySource: package.entrySource)
    }

    private nonisolated static func persistenceFingerprint(manifest m: PluginManifest, entrySource: Data) throws -> String {
        let canonical = try PluginManifest(schemaVersion: m.schemaVersion, id: m.id, name: m.name,
            version: m.version, engine: m.engine, entry: m.entry, minimumHostVersion: m.minimumHostVersion,
            permissions: m.permissions.sorted { $0.rawValue < $1.rawValue },
            capabilities: m.capabilities.sorted { $0.rawValue < $1.rawValue }, developer: m.developer)
        var hash = SHA256()
        hash.update(data: Data("DynamicIsland.PluginPermissionDecision.v1\0".utf8))
        hash.update(data: try canonical.encodeJSON())
        hash.update(data: Data([0]))
        hash.update(data: Data(SHA256.hash(data: entrySource)))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func beginMutation() async {
        if !mutationInProgress { mutationInProgress = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func endMutation() {
        if mutationWaiters.isEmpty { mutationInProgress = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    /// Called only after a Host approval or denial action. No default policy
    /// converts a declaration or plugin enablement into user consent.
    public func applyHostDecision(decision: PluginPermissionDecision,
                                  review: PluginPermissionReview,
                                  permission: PluginPermission) throws {
        guard let entry = entries[review.id], entry.review == review else {
            throw PluginPermissionError.staleReview
        }
        guard let gate = entry.gates[permission] else {
            throw PluginPermissionError.undeclared
        }
        gate.update(decision.state)
        entry.decisionGenerations[permission] = UUID()
        notifyObservers()
    }

    public func require(permission: PluginPermission,
                        package: ValidatedPluginPackage) throws -> PluginPermissionLease {
        try gate(permission: permission, package: package).lease(pluginID: package.manifest.id, permission: permission)
    }

    /// Raw names fail closed, including future high-risk permissions outside
    /// the V1 Manifest enum. Unknown values are never silently filtered out.
    public func require(permission: String,
                        package: ValidatedPluginPackage) throws -> PluginPermissionLease {
        guard let known = PluginPermission(rawValue: permission) else {
            throw PluginPermissionError.undeclared
        }
        return try require(permission: known, package: package)
    }

    public func state(permission: PluginPermission,
                      package: ValidatedPluginPackage) throws -> PluginPermissionState {
        try gate(permission: permission, package: package).state
    }

    public func state(permission: String,
                      package: ValidatedPluginPackage) throws -> PluginPermissionState {
        guard let known = PluginPermission(rawValue: permission) else {
            throw PluginPermissionError.undeclared
        }
        return try state(permission: known, package: package)
    }

    public func snapshot(package: ValidatedPluginPackage) throws -> PluginPermissionSnapshot {
        let entry = try currentEntry(package: package)
        return PluginPermissionSnapshot(review: entry.review, states: entry.gates.mapValues(\.state))
    }

    /// Deliberately forgets a registration and its approvals. Ordinary reload
    /// calls request again instead, preserving decisions for unchanged code.
    public func unregister(pluginID: String) {
        entries.removeValue(forKey: pluginID)?.revoke()
        preparedScopes.removeValue(forKey: pluginID)
        forgottenIDs.insert(pluginID)
        notifyObservers()
    }

    /// Synchronous shutdown/revocation boundary shared with outstanding leases.
    public func revokeAll() {
        entries.values.forEach { $0.revoke() }
        entries.values.forEach { entry in
            for permission in entry.gates.keys { entry.decisionGenerations[permission] = UUID() }
        }
        notifyObservers()
    }

    private func gate(permission: PluginPermission,
                      package: ValidatedPluginPackage) throws -> PluginPermissionGate {
        guard package.manifest.permissions.contains(permission) else {
            throw PluginPermissionError.undeclared
        }
        let entry = try currentEntry(package: package)
        guard let gate = entry.gates[permission] else {
            throw PluginPermissionError.undeclared
        }
        return gate
    }

    private func currentEntry(package: ValidatedPluginPackage) throws -> Entry {
        guard let entry = entries[package.manifest.id],
              entry.matches(package: package) else {
            throw PluginPermissionError.staleReview
        }
        return entry
    }
}

/// Declarations are sets: reordering them cannot create a different approval
/// scope. Include the remaining Manifest metadata conservatively as well.
private nonisolated struct PluginPermissionFingerprint: Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let developer: String?
    let version: SemanticVersion
    let engine: PluginEngine
    let entry: String
    let minimumHostVersion: SemanticVersion
    let permissions: [String]
    let capabilities: [String]
    let entrySourceSHA256: Data

    init(package: ValidatedPluginPackage) {
        let manifest = package.manifest
        schemaVersion = manifest.schemaVersion
        id = manifest.id
        name = manifest.name
        developer = manifest.developer
        version = manifest.version
        engine = manifest.engine
        entry = manifest.entry
        minimumHostVersion = manifest.minimumHostVersion
        permissions = manifest.permissions.map(\.rawValue).sorted()
        capabilities = manifest.capabilities.map(\.rawValue).sorted()
        entrySourceSHA256 = Data(SHA256.hash(data: package.entrySource))
    }

    func matches(manifest: PluginManifest) -> Bool {
        schemaVersion == manifest.schemaVersion && id == manifest.id && name == manifest.name && developer == manifest.developer
            && version == manifest.version && engine == manifest.engine && entry == manifest.entry
            && minimumHostVersion == manifest.minimumHostVersion
            && permissions == manifest.permissions.map(\.rawValue).sorted()
            && capabilities == manifest.capabilities.map(\.rawValue).sorted()
    }
}

/// State changes and final Broker commits share a lock. If a commit wins the
/// lock it finishes before revoke returns; if revoke wins the commit fails.
fileprivate nonisolated final class PluginPermissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState = PluginPermissionState.requested
    private var generation = UUID()
    private var observers: [UUID: @Sendable () -> Void] = [:]

    var state: PluginPermissionState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    func update(_ state: PluginPermissionState) {
        lock.lock()
        currentState = state
        generation = UUID()
        let callbacks = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func observe(generation expected: UUID, callback: @escaping @Sendable () -> Void) -> PluginPermissionObservation {
        let id = UUID()
        lock.lock()
        let active = currentState == .granted && generation == expected
        if active { observers[id] = callback }
        lock.unlock()
        if !active { callback() }
        return PluginPermissionObservation(gate: self, id: id)
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func lease(pluginID: String, permission: PluginPermission) throws -> PluginPermissionLease {
        lock.lock()
        defer { lock.unlock() }
        try requireGranted()
        return PluginPermissionLease(gate: self, generation: generation, pluginID: pluginID, permission: permission)
    }

    func perform<T>(generation expected: UUID, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { throw PluginPermissionError.revoked }
        try requireGranted()
        return try operation()
    }

    private func requireGranted() throws {
        switch currentState {
        case .requested: throw PluginPermissionError.notGranted
        case .granted: return
        case .denied: throw PluginPermissionError.denied
        case .revoked: throw PluginPermissionError.revoked
        }
    }
}
