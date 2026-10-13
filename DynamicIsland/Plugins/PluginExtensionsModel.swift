import Foundation
import Observation

/// An uninstall confirmation retains the Host's immutable package, so an old
/// alert cannot uninstall replacement code that happens to reuse its ID.
public nonisolated struct PluginManagementReview: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: SemanticVersion
    fileprivate let package: ValidatedPluginPackage

    fileprivate init(package: ValidatedPluginPackage) {
        id = package.manifest.id
        name = package.manifest.name
        version = package.manifest.version
        self.package = package
    }
}

/// Only fixed Host error codes are exposed for rejected discovery candidates.
/// Candidate names, paths and validation exception text never enter the UI.
public nonisolated struct PluginExtensionsDiscoveryIssue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let code: String

    fileprivate init(code: String) {
        id = UUID()
        self.code = code
    }
}

@MainActor
@Observable
public final class PluginExtensionsModel {
    public nonisolated static let refreshFailedMessage = "无法读取插件状态，请稍后刷新。"
    public nonisolated static let enableFailedMessage = "插件启用失败，请查看诊断记录后再试。"
    public nonisolated static let disableFailedMessage = "插件已停止，但停用状态未能保存，请稍后重试。"
    public nonisolated static let permissionFailedMessage = "权限设置未能保存，请刷新状态后重试。"
    public nonisolated static let staleReviewMessage = "插件内容已变化，请刷新后重新确认。"
    public nonisolated static let unsupportedPermissionMessage = "当前版本尚未支持此权限。"
    public nonisolated static let uninstallFailedMessage = "插件卸载未完成，请刷新状态后重试。"
    public nonisolated static let uninstallCleanupFailedMessage = "插件已卸载，本次授权已撤销，但授权记录移除失败。"
    public nonisolated static let quarantineMessage = "插件已被隔离，请在诊断界面确认后重启。"

    public private(set) var plugins: [PluginRecord] = []
    public private(set) var snapshots: [String: PluginLifecycleSnapshot] = [:]
    public private(set) var permissionSnapshots: [String: PluginPermissionSnapshot] = [:]
    public private(set) var discoveryFailures: [PluginExtensionsDiscoveryIssue] = []
    public var selectedID: String?
    public private(set) var isBusy = false
    public private(set) var error: String?
    public private(set) var persistenceError: String?

    @ObservationIgnored private let manager: PluginManager
    @ObservationIgnored private let lifecycle: PluginLifecycleBridge
    @ObservationIgnored private let permissions: PermissionManager
    @ObservationIgnored private let diagnostics: PluginDiagnosticsStore
    @ObservationIgnored private let diagnosticsModel: PluginDiagnosticsModel?
    @ObservationIgnored private var packages: [String: ValidatedPluginPackage] = [:]
    @ObservationIgnored private var lifecycleObservationID: UUID?
    @ObservationIgnored private var permissionObservationID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var snapshotGeneration: UInt64 = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(manager: PluginManager, lifecycle: PluginLifecycleBridge,
                permissions: PermissionManager, diagnostics: PluginDiagnosticsStore,
                diagnosticsModel: PluginDiagnosticsModel? = nil) {
        self.manager = manager
        self.lifecycle = lifecycle
        self.permissions = permissions
        self.diagnostics = diagnostics
        self.diagnosticsModel = diagnosticsModel
        lifecycleObservationID = lifecycle.observeChanges { [weak self] in
            self?.requestSnapshotRefresh()
        }
        permissionObservationID = permissions.observeChanges { [weak self] in
            self?.requestSnapshotRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
        if let lifecycleObservationID {
            let lifecycle = lifecycle
            Task { @MainActor in lifecycle.removeChangeObserver(lifecycleObservationID) }
        }
        if let permissionObservationID {
            let permissions = permissions
            Task { @MainActor in permissions.removeChangeObserver(permissionObservationID) }
        }
    }

    public var selectedPlugin: PluginRecord? { plugins.first { $0.id == selectedID } }
    public var selectedSnapshot: PluginLifecycleSnapshot? { selectedID.flatMap { snapshots[$0] } }
    public var selectedPermissionSnapshot: PluginPermissionSnapshot? {
        selectedID.flatMap { permissionSnapshots[$0] }
    }

    /// Permissions without a working Host Broker remain visible but cannot be
    /// granted. Denial and revocation remain available for every declaration.
    public nonisolated static func supports(_ permission: PluginPermission) -> Bool {
        switch permission {
        case .network, .localStorage, .readClipboard, .writeClipboard, .userSelectedFiles: true
        case .publishNotifications, .readCalendar: false
        }
    }

    public func permissionReview(id: String) -> PluginPermissionReview? {
        permissionSnapshots[id]?.review
    }

    public func managementReview(id: String) -> PluginManagementReview? {
        packages[id].map(PluginManagementReview.init(package:))
    }

    public func setDiscoveryReport(_ report: PluginDiscoveryReport) {
        discoveryFailures = report.failures.map { PluginExtensionsDiscoveryIssue(code: $0.error.code) }
    }

    /// Refresh reads Manager snapshots without rediscovery or Runtime restart.
    public func refresh() async {
        await waitUntilIdle()
        await performRefresh(clearError: true)
    }

    public func setEnabled(id: String, isEnabled: Bool) async {
        // Capture the click's package before queueing. A later refresh must not
        // silently retarget an already requested user action to new code.
        let expectedPackage = packages[id]
        await waitUntilIdle()
        beginBusyOperation()
        defer { finishBusyOperation() }
        error = nil
        do {
            guard let expectedPackage,
                  await manager.validatedPackage(id: id) == expectedPackage else {
                throw ManagementFailure.staleReview
            }
            if isEnabled {
                guard lifecycle.snapshot(id: id)?.quarantine == nil else {
                    throw ManagementFailure.quarantined
                }
                guard try await manager.enableIfCurrent(package: expectedPackage) != nil else {
                    throw ManagementFailure.staleReview
                }
                if let current = lifecycle.snapshot(id: id),
                   current.quarantine != nil || current.lastFailure == .startFailed {
                    throw ManagementFailure.startFailed
                }
            } else {
                // Closing execution and Activities is synchronous. Even a
                // failing enablement save must leave this execution stopped.
                lifecycle.pluginDidChangeEnablement(id: id, isEnabled: false)
                guard try await manager.disableIfCurrent(package: expectedPackage,
                                                          isIncidentCurrent: { true }) != nil else {
                    throw ManagementFailure.staleReview
                }
            }
        } catch {
            recordPersistenceFailure(error, pluginID: id)
            self.error = managementMessage(error, fallback: isEnabled ? Self.enableFailedMessage : Self.disableFailedMessage)
        }
        await readSnapshot()
    }

    public func setPermission(decision: PluginPermissionDecision,
                              review: PluginPermissionReview,
                              permission: PluginPermission) async {
        let expectedPackage = permissionSnapshots[review.id]?.review == review ? packages[review.id] : nil
        await waitUntilIdle()
        beginBusyOperation()
        defer { finishBusyOperation() }
        error = nil
        do {
            guard let expectedPackage,
                  await manager.validatedPackage(id: review.id) == expectedPackage,
                  try permissions.snapshot(package: expectedPackage).review == review else {
                throw ManagementFailure.staleReview
            }
            guard decision != .granted || Self.supports(permission) else {
                throw ManagementFailure.unsupportedPermission
            }
            try await permissions.applyPersistentHostDecision(decision: decision, review: review, permission: permission)
        } catch {
            self.error = managementMessage(error, fallback: Self.permissionFailedMessage)
        }
        await readSnapshot()
    }

    public func uninstall(_ review: PluginManagementReview) async {
        await waitUntilIdle()
        beginBusyOperation()
        defer { finishBusyOperation() }
        error = nil
        do {
            guard try await manager.uninstallIfCurrent(package: review.package) != nil else {
                throw ManagementFailure.staleReview
            }
            // The Manager holds its mutation transaction while the Host hook
            // forgets grants/history, so a concurrent same-ID installation
            // cannot be caught by this package's cleanup. KV remains retained.
            if permissions.persistenceError != nil { error = Self.uninstallCleanupFailedMessage }
        } catch {
            recordPersistenceFailure(error, pluginID: review.id)
            self.error = managementMessage(error, fallback: Self.uninstallFailedMessage)
        }
        await readSnapshot()
    }

    public func showLog(id: String) async {
        await waitUntilIdle()
        beginBusyOperation()
        defer { finishBusyOperation() }
        diagnosticsModel?.selectedID = id
        await diagnosticsModel?.refresh()
    }

    private func performRefresh(clearError: Bool) async {
        guard !isBusy else { needsRefresh = true; return }
        beginBusyOperation()
        defer { finishBusyOperation() }
        if clearError { error = nil }
        await readSnapshot()
    }

    private func readSnapshot() async {
        let startingGeneration = snapshotGeneration
        let listed = await manager.plugins()
        var currentPackages: [String: ValidatedPluginPackage] = [:]
        var currentPlugins: [PluginRecord] = []
        for plugin in listed {
            guard let package = await manager.validatedPackage(id: plugin.id),
                  package.manifest == plugin.manifest,
                  package.canonicalRootURL == plugin.canonicalRootURL else { continue }
            currentPlugins.append(plugin)
            currentPackages[plugin.id] = package
        }
        packages = currentPackages
        plugins = currentPlugins
        var currentLifecycle: [String: PluginLifecycleSnapshot] = [:]
        var currentPermissions: [String: PluginPermissionSnapshot] = [:]
        for plugin in plugins {
            currentLifecycle[plugin.id] = lifecycle.snapshot(id: plugin.id)
            if let package = currentPackages[plugin.id] {
                currentPermissions[plugin.id] = try? permissions.snapshot(package: package)
            }
        }
        snapshots = currentLifecycle
        permissionSnapshots = currentPermissions
        persistenceError = permissions.persistenceError
        if !plugins.contains(where: { $0.id == selectedID }) { selectedID = plugins.first?.id }
        // Manager reads cross actor boundaries. A change to an earlier item
        // during a later read requires another coalesced pass.
        needsRefresh = startingGeneration != snapshotGeneration
    }

    private func requestSnapshotRefresh() {
        snapshotGeneration &+= 1
        needsRefresh = true
        guard !isBusy, refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            await self.performRefresh(clearError: false)
        }
    }

    private func beginBusyOperation() {
        isBusy = true
        needsRefresh = false
    }

    private func finishBusyOperation() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if waiters.isEmpty, needsRefresh { requestSnapshotRefresh() }
    }

    private func waitUntilIdle() async {
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    private func recordPersistenceFailure(_ error: Error, pluginID: String) {
        if let managerError = error as? PluginManagerError, managerError == .stateWriteFailed {
            diagnostics.recordPersistenceFailure(pluginID: pluginID)
        }
    }

    private func managementMessage(_ error: Error, fallback: String) -> String {
        if let failure = error as? ManagementFailure {
            switch failure {
            case .staleReview: return Self.staleReviewMessage
            case .quarantined: return Self.quarantineMessage
            case .unsupportedPermission: return Self.unsupportedPermissionMessage
            case .startFailed: break
            }
        }
        if let permissionError = error as? PluginPermissionError, permissionError == .staleReview {
            return Self.staleReviewMessage
        }
        return fallback
    }

    private enum ManagementFailure: Error {
        case staleReview, quarantined, unsupportedPermission, startFailed
    }
}
