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
    case notGranted, denied, revoked, undeclared, staleReview

    public var code: String {
        switch self {
        case .notGranted: "permissionNotGranted"
        case .denied: "permissionDenied"
        case .revoked: "permissionRevoked"
        case .undeclared: "permissionRequired"
        case .staleReview: "stalePermissionReview"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notGranted: "The Host has not granted the requested permission."
        case .denied: "The Host denied the requested permission."
        case .revoked: "The Host revoked the permission or its previous authorization."
        case .undeclared: "The permission is unknown or is not declared by this plugin."
        case .staleReview: "The permission review does not belong to the current plugin package."
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
}

/// Central Host authorization for the current process only. A new manager has
/// no grants, and every package begins requested after App restart. T33 supplies
/// a user approval UI and a separately reviewed persistence policy.
@MainActor
public final class PermissionManager {
    private final class Entry {
        let fingerprint: PluginPermissionFingerprint
        let manifest: PluginManifest
        let entrySource: Data
        let review: PluginPermissionReview
        let gates: [PluginPermission: PluginPermissionGate]

        init(package: ValidatedPluginPackage, fingerprint: PluginPermissionFingerprint) {
            self.fingerprint = fingerprint
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

    public init() {}

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
        entries[id]?.revoke()
        let entry = Entry(package: package, fingerprint: fingerprint)
        entries[id] = entry
        return entry.review
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
    }

    /// Synchronous shutdown/revocation boundary shared with outstanding leases.
    public func revokeAll() {
        entries.values.forEach { $0.revoke() }
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
        version = manifest.version
        engine = manifest.engine
        entry = manifest.entry
        minimumHostVersion = manifest.minimumHostVersion
        permissions = manifest.permissions.map(\.rawValue).sorted()
        capabilities = manifest.capabilities.map(\.rawValue).sorted()
        entrySourceSHA256 = Data(SHA256.hash(data: package.entrySource))
    }

    func matches(manifest: PluginManifest) -> Bool {
        schemaVersion == manifest.schemaVersion && id == manifest.id && name == manifest.name
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

    var state: PluginPermissionState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    func update(_ state: PluginPermissionState) {
        lock.lock()
        defer { lock.unlock() }
        currentState = state
        generation = UUID()
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
