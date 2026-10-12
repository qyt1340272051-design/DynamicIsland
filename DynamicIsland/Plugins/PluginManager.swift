import Darwin
import Foundation

/// Host-owned directories and compatibility limits used by `PluginManager`.
/// Installed packages, manager state, and uninstall quarantine stay in
/// separate directories so discovery never mistakes Host metadata for a plugin.
public nonisolated struct PluginManagerConfiguration: Equatable, Sendable {
    public let rootDirectoryURL: URL
    public let hostVersion: SemanticVersion
    public let limits: PluginPackageLimits

    public init(
        rootDirectoryURL: URL,
        hostVersion: SemanticVersion,
        limits: PluginPackageLimits = PluginPackageLimits()
    ) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
        self.hostVersion = hostVersion
        self.limits = limits
    }

    public var installedDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Installed", isDirectory: true)
    }

    public var stateDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("State", isDirectory: true)
    }

    public var stateFileURL: URL {
        stateDirectoryURL.appendingPathComponent("plugin-manager-v1.json", isDirectory: false)
    }

    public var trashDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Trash", isDirectory: true)
    }

    /// Uncommitted uninstall packages remain recoverable after a failed rollback.
    public var recoveryDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Production path planned for T20/T34. The Host version remains injected
    /// so tests, prereleases, and future migrations do not depend on Bundle state.
    public static func applicationSupport(hostVersion: SemanticVersion) throws -> Self {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(
            rootDirectoryURL: applicationSupport
                .appendingPathComponent("DynamicIsland", isDirectory: true)
                .appendingPathComponent("Plugins", isDirectory: true),
            hostVersion: hostVersion
        )
    }
}

/// Lightweight list item for Settings and diagnostics. Entry source bytes stay
/// inside the Manager and are exposed separately to the future T22 Runtime.
public nonisolated struct PluginRecord: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }
    public let manifest: PluginManifest
    public let canonicalRootURL: URL
    public let isEnabled: Bool
    public let regularFileCount: Int
    public let totalFileBytes: UInt64
}

public nonisolated enum PluginManagerError: Error, Equatable, LocalizedError, Sendable {
    case invalidManagedDirectory(String)
    case insecureManagedDirectory(String)
    case discoveryFailed
    case candidateUnreadable(String)
    case packageMustBeDirectChild(String)
    case insecurePackageDirectory(String)
    case pluginNotFound(String)
    case packageAlreadyLoaded(String)
    case manifestIDChanged(expected: String, actual: String)
    case packageRootChanged(String)
    case validation(PluginValidationError)
    case stateReadFailed
    case stateWriteFailed
    case uninstallFailed(String)
    case uninstallRollbackFailed(String)

    public var code: String {
        switch self {
        case .invalidManagedDirectory: "invalidManagedDirectory"
        case .insecureManagedDirectory: "insecureManagedDirectory"
        case .discoveryFailed: "discoveryFailed"
        case .candidateUnreadable: "candidateUnreadable"
        case .packageMustBeDirectChild: "packageMustBeDirectChild"
        case .insecurePackageDirectory: "insecurePackageDirectory"
        case .pluginNotFound: "pluginNotFound"
        case .packageAlreadyLoaded: "packageAlreadyLoaded"
        case .manifestIDChanged: "manifestIDChanged"
        case .packageRootChanged: "packageRootChanged"
        case .validation(let error): error.code
        case .stateReadFailed: "stateReadFailed"
        case .stateWriteFailed: "stateWriteFailed"
        case .uninstallFailed: "uninstallFailed"
        case .uninstallRollbackFailed: "uninstallRollbackFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidManagedDirectory(let name):
            "Plugin Manager directory \(name.debugDescription) is unavailable or has an invalid type."
        case .insecureManagedDirectory(let name):
            "Plugin Manager directory \(name.debugDescription) must be owned by the current user and not writable by other users."
        case .discoveryFailed:
            "The installed plugin directory could not be enumerated."
        case .candidateUnreadable(let name):
            "Plugin candidate \(name.debugDescription) could not be inspected."
        case .packageMustBeDirectChild(let name):
            "Plugin package \(name.debugDescription) must be a direct child of the Installed directory."
        case .insecurePackageDirectory(let name):
            "Plugin package \(name.debugDescription) must be owned by the current user and not writable by other users."
        case .pluginNotFound(let id):
            "Plugin \(id.debugDescription) is not loaded."
        case .packageAlreadyLoaded(let id):
            "Plugin package is already loaded as \(id.debugDescription)."
        case .manifestIDChanged(let expected, let actual):
            "Reloaded plugin changed its ID from \(expected.debugDescription) to \(actual.debugDescription)."
        case .packageRootChanged(let id):
            "Plugin \(id.debugDescription) changed its package root during reload."
        case .validation(let error):
            error.localizedDescription
        case .stateReadFailed:
            "Plugin enablement state could not be read; plugins remain disabled."
        case .stateWriteFailed:
            "Plugin enablement state could not be saved."
        case .uninstallFailed(let id):
            "Plugin \(id.debugDescription) could not be moved to the uninstall quarantine."
        case .uninstallRollbackFailed(let id):
            "Plugin \(id.debugDescription) could not be restored after a failed state write; its package is preserved in Recovery."
        }
    }
}

/// One rejected candidate or one Manager-level recovery issue. A report can
/// contain failures and valid plugins at the same time.
public nonisolated struct PluginDiscoveryFailure: Equatable, Sendable {
    public let candidateName: String?
    public let pluginID: String?
    public let error: PluginManagerError

    public init(candidateName: String?, pluginID: String? = nil, error: PluginManagerError) {
        self.candidateName = candidateName
        self.pluginID = pluginID
        self.error = error
    }
}

public nonisolated struct PluginDiscoveryReport: Equatable, Sendable {
    public let plugins: [PluginRecord]
    public let failures: [PluginDiscoveryFailure]
}

/// Serial ownership boundary for installed plugin identity and enablement.
/// T20 "load" means validating and retaining an immutable package snapshot;
/// JavaScript execution and lifecycle callbacks begin in T21/T22.
public actor PluginManager {
    public let configuration: PluginManagerConfiguration

    private let validator: PluginValidator
    private let stateStore: any PluginManagerStatePersisting
    private let lifecycleHandler: (any PluginManagerLifecycleHandling)?
    private var entries: [String: LoadedPlugin] = [:]
    private var persistedState = PluginManagerStateFile.empty
    private var hasLoadedState = false
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: PluginManagerConfiguration,
        validator: PluginValidator = PluginValidator(),
        lifecycleHandler: (any PluginManagerLifecycleHandling)? = nil
    ) {
        self.configuration = configuration
        self.validator = validator
        stateStore = PluginManagerFileStateStore(fileURL: configuration.stateFileURL)
        self.lifecycleHandler = lifecycleHandler
    }

    init(
        configuration: PluginManagerConfiguration,
        validator: PluginValidator = PluginValidator(),
        stateStore: any PluginManagerStatePersisting,
        lifecycleHandler: (any PluginManagerLifecycleHandling)? = nil
    ) {
        self.configuration = configuration
        self.validator = validator
        self.stateStore = stateStore
        self.lifecycleHandler = lifecycleHandler
    }

    /// Rebuilds the registry from direct children of `Installed`. Every
    /// candidate is isolated; a malformed package never hides valid siblings.
    /// Duplicate IDs in one discovery batch are all rejected so filesystem
    /// enumeration order cannot choose which code wins.
    public func discover() async -> PluginDiscoveryReport {
        await beginMutation()
        defer { endMutation() }
        var failures: [PluginDiscoveryFailure] = []
        do {
            try prepareManagedDirectories()
        } catch let error as PluginManagerError {
            failures.append(.init(candidateName: nil, error: error))
            return makeReport(failures: failures)
        } catch {
            failures.append(.init(candidateName: nil, error: .discoveryFailed))
            return makeReport(failures: failures)
        }

        let recoveredState: PluginManagerStateFile
        do {
            recoveredState = try stateStore.load()
        } catch {
            recoveredState = .empty
            failures.append(.init(candidateName: nil, error: .stateReadFailed))
        }
        persistedState = recoveredState
        hasLoadedState = true

        let candidateURLs: [URL]
        do {
            let discovery = try discoveryCandidates()
            candidateURLs = discovery.urls
            failures.append(contentsOf: discovery.failures)
        } catch {
            failures.append(.init(candidateName: nil, error: .discoveryFailed))
            return makeReport(failures: failures)
        }

        var validatedCandidates: [ValidatedCandidate] = []
        for candidateURL in candidateURLs {
            let candidateName = candidateURL.lastPathComponent
            do {
                let package = try validator.validateExpandedPackage(
                    at: candidateURL,
                    context: validationContext(occupiedPluginIDs: [])
                )
                try validatePackageOwnership(package.canonicalRootURL, candidateName: candidateName)
                validatedCandidates.append(.init(candidateName: candidateName, package: package))
            } catch let error as PluginValidationError {
                failures.append(.init(
                    candidateName: candidateName,
                    error: .validation(error)
                ))
            } catch let error as PluginManagerError {
                failures.append(.init(candidateName: candidateName, error: error))
            } catch {
                failures.append(.init(
                    candidateName: candidateName,
                    error: .candidateUnreadable(candidateName)
                ))
            }
        }

        let candidatesByID = Dictionary(grouping: validatedCandidates) { $0.package.manifest.id }
        var nextEntries: [String: LoadedPlugin] = [:]
        var nextState = PluginManagerStateFile.empty

        for pluginID in candidatesByID.keys.sorted(by: Self.utf8Less) {
            guard let group = candidatesByID[pluginID] else { continue }
            guard group.count == 1, let candidate = group.first else {
                for duplicate in group.sorted(by: { Self.utf8Less($0.candidateName, $1.candidateName) }) {
                    failures.append(.init(
                        candidateName: duplicate.candidateName,
                        pluginID: pluginID,
                        error: .validation(.duplicatePluginID(pluginID))
                    ))
                }
                continue
            }

            let restored = recoveredState.plugins[pluginID]
            let isEnabled = restored?.version == candidate.package.manifest.version
                && restored?.isEnabled == true
            nextEntries[pluginID] = LoadedPlugin(package: candidate.package, isEnabled: isEnabled)
            nextState.plugins[pluginID] = .init(
                version: candidate.package.manifest.version,
                isEnabled: isEnabled
            )
        }

        for id in entries.keys.sorted() {
            await lifecycleHandler?.pluginWillUnload(id: id)
        }
        entries = nextEntries
        persistedState = nextState
        do {
            try stateStore.save(nextState)
        } catch {
            failures.append(.init(candidateName: nil, error: .stateWriteFailed))
        }

        for id in entries.keys.sorted() {
            guard let entry = entries[id] else { continue }
            await lifecycleHandler?.pluginDidLoad(entry.package, isEnabled: entry.isEnabled)
        }

        return makeReport(failures: failures)
    }

    /// Validates and registers one package already committed to `Installed`.
    /// The mutation guard covers registration and the lifecycle callback, even
    /// while the actor awaits the MainActor Host boundary.
    @discardableResult
    public func load(at packageURL: URL) async throws -> PluginRecord {
        await beginMutation()
        defer { endMutation() }
        try prepareManagedDirectories()
        try ensureStateLoaded()
        try requireDirectInstalledChild(packageURL)

        let package = try validateForOperation(
            packageURL,
            occupiedPluginIDs: Set(entries.keys)
        )
        try validatePackageOwnership(package.canonicalRootURL, candidateName: packageURL.lastPathComponent)

        guard entries[package.manifest.id] == nil else {
            throw PluginManagerError.validation(.duplicatePluginID(package.manifest.id))
        }
        if let existing = entries.values.first(where: {
            $0.package.canonicalRootURL == package.canonicalRootURL
        }) {
            throw PluginManagerError.packageAlreadyLoaded(existing.package.manifest.id)
        }

        let stored = persistedState.plugins[package.manifest.id]
        let isEnabled = stored?.version == package.manifest.version && stored?.isEnabled == true
        let loaded = LoadedPlugin(package: package, isEnabled: isEnabled)
        var nextState = persistedState
        nextState.plugins[package.manifest.id] = .init(
            version: package.manifest.version,
            isEnabled: isEnabled
        )
        try saveStateForOperation(nextState)

        persistedState = nextState
        entries[package.manifest.id] = loaded
        await lifecycleHandler?.pluginDidLoad(package, isEnabled: isEnabled)
        return loaded.record
    }

    @discardableResult
    public func enable(id pluginID: String) async throws -> PluginRecord {
        await beginMutation()
        defer { endMutation() }
        return try await setEnabled(true, id: pluginID)
    }

    @discardableResult
    public func disable(id pluginID: String) async throws -> PluginRecord {
        await beginMutation()
        defer { endMutation() }
        return try await setEnabled(false, id: pluginID)
    }

    /// A delayed watchdog write cannot target replacement code or an incident
    /// the Host has explicitly cleared. Manager's FIFO also serializes user
    /// restart (disable/reload/enable) against this persistence transaction.
    public func disableIfCurrent(package: ValidatedPluginPackage,
                                 isIncidentCurrent: @escaping @MainActor @Sendable () -> Bool) async throws -> PluginRecord? {
        await beginMutation()
        defer { endMutation() }
        guard let current = entries[package.manifest.id],
              current.package.manifest == package.manifest,
              current.package.entrySource == package.entrySource,
              current.package.entryRelativePath == package.entryRelativePath,
              current.package.canonicalRootURL == package.canonicalRootURL,
              await isIncidentCurrent() else { return nil }
        return try await setEnabled(false, id: package.manifest.id)
    }

    /// Revalidates the package and atomically replaces its immutable snapshot.
    /// A failed validation or state write leaves the previous record untouched.
    /// Manifest changes disable the plugin until the user enables it again.
    @discardableResult
    public func reload(id pluginID: String) async throws -> PluginRecord {
        await beginMutation()
        defer { endMutation() }
        try prepareManagedDirectories()
        try ensureStateLoaded()
        guard let existing = entries[pluginID] else {
            throw PluginManagerError.pluginNotFound(pluginID)
        }

        let occupied = Set(entries.keys).subtracting([pluginID])
        let package = try validateForOperation(
            existing.package.canonicalRootURL,
            occupiedPluginIDs: occupied
        )
        guard package.manifest.id == pluginID else {
            throw PluginManagerError.manifestIDChanged(
                expected: pluginID,
                actual: package.manifest.id
            )
        }
        guard package.canonicalRootURL == existing.package.canonicalRootURL else {
            throw PluginManagerError.packageRootChanged(pluginID)
        }
        try validatePackageOwnership(package.canonicalRootURL, candidateName: package.canonicalRootURL.lastPathComponent)

        let isEnabled = existing.isEnabled && existing.package.manifest == package.manifest
        let reloaded = LoadedPlugin(package: package, isEnabled: isEnabled)
        var nextState = persistedState
        nextState.plugins[pluginID] = .init(
            version: package.manifest.version,
            isEnabled: isEnabled
        )
        try saveStateForOperation(nextState)

        await lifecycleHandler?.pluginWillUnload(id: pluginID)
        persistedState = nextState
        entries[pluginID] = reloaded
        await lifecycleHandler?.pluginDidLoad(package, isEnabled: isEnabled)
        return reloaded.record
    }

    /// Removes only a package already registered by ID. Moving it to the
    /// Host-owned quarantine first makes it disappear from discovery without
    /// traversing a caller-supplied path.
    @discardableResult
    public func uninstall(id pluginID: String) async throws -> PluginRecord {
        await beginMutation()
        defer { endMutation() }
        try prepareManagedDirectories()
        try ensureStateLoaded()
        guard let existing = entries[pluginID] else {
            throw PluginManagerError.pluginNotFound(pluginID)
        }

        let sourceURL = existing.package.canonicalRootURL
        try requireDirectInstalledChild(sourceURL)
        let quarantineURL = configuration.recoveryDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var movedToQuarantine = false

        // Stop execution and remove every owned Activity before touching the
        // installed package. Direct Manager calls cannot bypass this boundary.
        await lifecycleHandler?.pluginWillUnload(id: pluginID)

        if Self.pathExistsWithoutFollowingSymlinks(sourceURL) {
            do {
                try FileManager.default.moveItem(at: sourceURL, to: quarantineURL)
                movedToQuarantine = true
            } catch {
                await lifecycleHandler?.pluginDidLoad(existing.package, isEnabled: existing.isEnabled)
                throw PluginManagerError.uninstallFailed(pluginID)
            }
        }

        var nextState = persistedState
        nextState.plugins.removeValue(forKey: pluginID)
        do {
            try stateStore.save(nextState)
        } catch {
            if movedToQuarantine {
                do {
                    try FileManager.default.moveItem(at: quarantineURL, to: sourceURL)
                } catch {
                    // The validated package no longer occupies its registered
                    // path. Stop exposing it, but keep its bytes in Recovery.
                    entries.removeValue(forKey: pluginID)
                    persistedState.plugins.removeValue(forKey: pluginID)
                    throw PluginManagerError.uninstallRollbackFailed(pluginID)
                }
            }
            await lifecycleHandler?.pluginDidLoad(existing.package, isEnabled: existing.isEnabled)
            throw PluginManagerError.stateWriteFailed
        }

        persistedState = nextState
        entries.removeValue(forKey: pluginID)
        if movedToQuarantine {
            do {
                try FileManager.default.removeItem(at: quarantineURL)
            } catch {
                let trashURL = configuration.trashDirectoryURL
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.moveItem(at: quarantineURL, to: trashURL)
            }
        }
        return existing.record
    }

    public func plugins() -> [PluginRecord] {
        entries.values.map(\.record).sorted { Self.utf8Less($0.id, $1.id) }
    }

    public func plugin(id pluginID: String) -> PluginRecord? {
        entries[pluginID]?.record
    }

    public func isEnabled(id pluginID: String) -> Bool {
        entries[pluginID]?.isEnabled == true
    }

    /// The future Runtime must execute this immutable `entrySource` snapshot,
    /// never reopen `entryRelativePath` after validation.
    public func validatedPackage(id pluginID: String) -> ValidatedPluginPackage? {
        entries[pluginID]?.package
    }

    private func setEnabled(_ enabled: Bool, id pluginID: String) async throws -> PluginRecord {
        try prepareManagedDirectories()
        try ensureStateLoaded()
        guard let current = entries[pluginID] else {
            throw PluginManagerError.pluginNotFound(pluginID)
        }
        guard current.isEnabled != enabled else {
            await lifecycleHandler?.pluginDidChangeEnablement(id: pluginID, isEnabled: enabled)
            return current.record
        }

        let updated = LoadedPlugin(package: current.package, isEnabled: enabled)
        var nextState = persistedState
        nextState.plugins[pluginID] = .init(
            version: current.package.manifest.version,
            isEnabled: enabled
        )
        try saveStateForOperation(nextState)

        persistedState = nextState
        entries[pluginID] = updated
        await lifecycleHandler?.pluginDidChangeEnablement(id: pluginID, isEnabled: enabled)
        return updated.record
    }

    /// A plain actor is reentrant at the MainActor lifecycle hop. FIFO ownership
    /// keeps all mutations serial until their runtime/UI effects are complete.
    private func beginMutation() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func endMutation() {
        if mutationWaiters.isEmpty { mutationInProgress = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    private func ensureStateLoaded() throws {
        guard !hasLoadedState else { return }
        do {
            persistedState = try stateStore.load()
            hasLoadedState = true
        } catch {
            throw PluginManagerError.stateReadFailed
        }
    }

    private func saveStateForOperation(_ state: PluginManagerStateFile) throws {
        do {
            try stateStore.save(state)
        } catch {
            throw PluginManagerError.stateWriteFailed
        }
    }

    private func validateForOperation(
        _ packageURL: URL,
        occupiedPluginIDs: Set<String>
    ) throws -> ValidatedPluginPackage {
        do {
            return try validator.validateExpandedPackage(
                at: packageURL,
                context: validationContext(occupiedPluginIDs: occupiedPluginIDs)
            )
        } catch let error as PluginValidationError {
            throw PluginManagerError.validation(error)
        }
    }

    private func validationContext(occupiedPluginIDs: Set<String>) -> PluginValidationContext {
        PluginValidationContext(
            hostVersion: configuration.hostVersion,
            occupiedPluginIDs: occupiedPluginIDs,
            limits: configuration.limits,
            allowedContainerURL: configuration.installedDirectoryURL
        )
    }

    private func makeReport(failures: [PluginDiscoveryFailure]) -> PluginDiscoveryReport {
        PluginDiscoveryReport(
            plugins: entries.values.map(\.record).sorted { Self.utf8Less($0.id, $1.id) },
            failures: failures.sorted(by: Self.failurePrecedes)
        )
    }

    private func discoveryCandidates() throws -> (
        urls: [URL],
        failures: [PluginDiscoveryFailure]
    ) {
        let urls = try FileManager.default.contentsOfDirectory(
            at: configuration.installedDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        var candidates: [URL] = []
        var failures: [PluginDiscoveryFailure] = []
        for url in urls {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                failures.append(.init(
                    candidateName: url.lastPathComponent,
                    error: .candidateUnreadable(url.lastPathComponent)
                ))
                continue
            }
            let kind = status.st_mode & S_IFMT
            if kind == S_IFDIR || kind == S_IFLNK {
                candidates.append(url)
            }
        }
        return (
            candidates.sorted { Self.utf8Less($0.lastPathComponent, $1.lastPathComponent) },
            failures
        )
    }

    private func prepareManagedDirectories() throws {
        for (url, name) in [
            (configuration.rootDirectoryURL, "Plugins"),
            (configuration.installedDirectoryURL, "Installed"),
            (configuration.stateDirectoryURL, "State"),
            (configuration.recoveryDirectoryURL, "Recovery"),
            (configuration.trashDirectoryURL, "Trash")
        ] {
            try ensureManagedDirectory(at: url, name: name)
        }
        cleanupQuarantine()
    }

    private func ensureManagedDirectory(at url: URL, name: String) throws {
        guard Self.isStrictLocalFileURL(url) else {
            throw PluginManagerError.invalidManagedDirectory(name)
        }
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else {
                throw PluginManagerError.invalidManagedDirectory(name)
            }
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                guard chmod(url.path, S_IRWXU) == 0, lstat(url.path, &status) == 0 else {
                    throw PluginManagerError.invalidManagedDirectory(name)
                }
            } catch let error as PluginManagerError {
                throw error
            } catch {
                throw PluginManagerError.invalidManagedDirectory(name)
            }
        }

        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw PluginManagerError.invalidManagedDirectory(name)
        }
        guard status.st_uid == geteuid(),
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw PluginManagerError.insecureManagedDirectory(name)
        }
    }

    private func validatePackageOwnership(_ url: URL, candidateName: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw PluginManagerError.insecurePackageDirectory(candidateName)
        }
    }

    private func requireDirectInstalledChild(_ packageURL: URL) throws {
        let package = packageURL.standardizedFileURL
        let installed = configuration.installedDirectoryURL.standardizedFileURL
        guard Self.isStrictLocalFileURL(package),
              package.deletingLastPathComponent() == installed,
              !package.lastPathComponent.isEmpty else {
            throw PluginManagerError.packageMustBeDirectChild(packageURL.lastPathComponent)
        }
    }

    private func cleanupQuarantine() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: configuration.trashDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isStrictLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let host = url.host(percentEncoded: false)
        return host == nil || host?.isEmpty == true
    }

    fileprivate static func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func failurePrecedes(
        _ lhs: PluginDiscoveryFailure,
        _ rhs: PluginDiscoveryFailure
    ) -> Bool {
        let leftName = lhs.candidateName ?? ""
        let rightName = rhs.candidateName ?? ""
        if leftName != rightName { return utf8Less(leftName, rightName) }
        if lhs.error.code != rhs.error.code { return utf8Less(lhs.error.code, rhs.error.code) }
        return utf8Less(lhs.pluginID ?? "", rhs.pluginID ?? "")
    }
}

private nonisolated struct LoadedPlugin: Sendable {
    let package: ValidatedPluginPackage
    let isEnabled: Bool

    var record: PluginRecord {
        PluginRecord(
            manifest: package.manifest,
            canonicalRootURL: package.canonicalRootURL,
            isEnabled: isEnabled,
            regularFileCount: package.regularFileCount,
            totalFileBytes: package.totalFileBytes
        )
    }
}

private nonisolated struct ValidatedCandidate: Sendable {
    let candidateName: String
    let package: ValidatedPluginPackage
}

nonisolated struct PluginManagerStateFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let empty = PluginManagerStateFile(schemaVersion: currentSchemaVersion, plugins: [:])

    var schemaVersion: Int
    var plugins: [String: PluginManagerPersistedPlugin]

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              plugins.count <= 4_096,
              plugins.keys.allSatisfy(PluginManifest.isValidPluginID) else {
            throw PluginManagerStateStoreFailure.invalidState
        }
    }
}

nonisolated struct PluginManagerPersistedPlugin: Codable, Equatable, Sendable {
    let version: SemanticVersion
    let isEnabled: Bool
}

nonisolated protocol PluginManagerStatePersisting: Sendable {
    func load() throws -> PluginManagerStateFile
    func save(_ state: PluginManagerStateFile) throws
}

private nonisolated enum PluginManagerStateStoreFailure: Error {
    case invalidState
    case readFailed
    case writeFailed
}

/// Implementations must either throw before replacing the destination or return
/// after the replacement. No fallible work may follow a successful commit.
nonisolated protocol PluginManagerStateFileReplacing: Sendable {
    func replace(preparedFile: URL, destination: URL) throws
}

private nonisolated struct PluginManagerAtomicStateFileReplacer: PluginManagerStateFileReplacing {
    func replace(preparedFile: URL, destination: URL) throws {
        guard Darwin.rename(preparedFile.path, destination.path) == 0 else {
            throw PluginManagerStateStoreFailure.writeFailed
        }
    }
}

nonisolated struct PluginManagerFileStateStore: PluginManagerStatePersisting {
    static let maximumBytes = 1_048_576
    let fileURL: URL
    private let replacer: any PluginManagerStateFileReplacing

    init(
        fileURL: URL,
        replacer: any PluginManagerStateFileReplacing = PluginManagerAtomicStateFileReplacer()
    ) {
        self.fileURL = fileURL
        self.replacer = replacer
    }

    func load() throws -> PluginManagerStateFile {
        var initial = stat()
        if lstat(fileURL.path, &initial) != 0 {
            if errno == ENOENT { return .empty }
            throw PluginManagerStateStoreFailure.readFailed
        }
        guard initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(),
              initial.st_nlink == 1,
              initial.st_mode & (S_IWGRP | S_IWOTH) == 0,
              initial.st_size >= 0,
              initial.st_size <= Self.maximumBytes else {
            throw PluginManagerStateStoreFailure.invalidState
        }

        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw PluginManagerStateStoreFailure.readFailed }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == initial.st_dev,
              opened.st_ino == initial.st_ino,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size == initial.st_size else {
            throw PluginManagerStateStoreFailure.readFailed
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw PluginManagerStateStoreFailure.readFailed
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else {
                throw PluginManagerStateStoreFailure.invalidState
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var ending = stat()
        guard fstat(descriptor, &ending) == 0,
              ending.st_dev == opened.st_dev,
              ending.st_ino == opened.st_ino,
              ending.st_size == opened.st_size else {
            throw PluginManagerStateStoreFailure.readFailed
        }

        let state: PluginManagerStateFile
        do {
            state = try JSONDecoder().decode(PluginManagerStateFile.self, from: data)
            try state.validate()
        } catch {
            throw PluginManagerStateStoreFailure.invalidState
        }
        return state
    }

    func save(_ state: PluginManagerStateFile) throws {
        do {
            try state.validate()
            if PluginManager.pathExistsWithoutFollowingSymlinks(fileURL) {
                var existing = stat()
                guard lstat(fileURL.path, &existing) == 0,
                      existing.st_mode & S_IFMT == S_IFREG,
                      existing.st_uid == geteuid(),
                      existing.st_nlink == 1,
                      existing.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                    throw PluginManagerStateStoreFailure.invalidState
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            guard data.count <= Self.maximumBytes else {
                throw PluginManagerStateStoreFailure.invalidState
            }
            let temporaryURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".plugin-manager-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(
                temporaryURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw PluginManagerStateStoreFailure.writeFailed
            }
            defer {
                Darwin.close(descriptor)
                // rename removes the temporary name on success; cleanup is
                // best effort and cannot turn a committed save into failure.
                Darwin.unlink(temporaryURL.path)
            }

            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw PluginManagerStateStoreFailure.writeFailed
            }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw PluginManagerStateStoreFailure.writeFailed }
                    offset += written
                }
            }
            var prepared = stat()
            guard fsync(descriptor) == 0,
                  fstat(descriptor, &prepared) == 0,
                  prepared.st_mode & S_IFMT == S_IFREG,
                  prepared.st_mode & 0o777 == 0o600,
                  prepared.st_uid == geteuid(),
                  prepared.st_nlink == 1,
                  prepared.st_size == data.count else {
                throw PluginManagerStateStoreFailure.writeFailed
            }
            try replacer.replace(preparedFile: temporaryURL, destination: fileURL)
        } catch let error as PluginManagerStateStoreFailure {
            throw error
        } catch {
            throw PluginManagerStateStoreFailure.writeFailed
        }
    }
}
