import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginExtensionsModelTests: XCTestCase {
    func testRefreshUsesRegisteredPackageWithoutStartingOrGranting() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.refresh()

        XCTAssertEqual(fixture.model.selectedID, fixture.id)
        XCTAssertEqual(fixture.model.selectedPlugin?.manifest.name, "Extensions Test")
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)
        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot, .profile(for: .javaScriptCore))
        XCTAssertTrue(fixture.runtimes.values.isEmpty)
        XCTAssertFalse(fixture.model.isBusy)
        let firstReview = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.permissionReview(id: fixture.id), firstReview)
        XCTAssertTrue(fixture.runtimes.values.isEmpty)
    }

    func testCompatibleLayoutObservationsRefreshWithoutRestartAndResetOnDisable() async throws {
        let fixture = try await makeFixture(engine: .superIsland, source: Self.compatibleSource)
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot, .profile(for: .superIsland))
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        try await waitUntil { fixture.model.selectedCompatibilitySnapshot?.observation == .rendered }
        let first = try XCTUnwrap(fixture.model.selectedCompatibilitySnapshot)
        XCTAssertEqual(first.level, .limited)
        XCTAssertEqual(first.profileLimitations, Set(PluginCompatibilityProfileLimitation.allCases))
        XCTAssertTrue(first.layoutLimitations.contains(.hostButtonAppearance))
        XCTAssertEqual(fixture.runtimes.values.count, 1)

        let activity = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertTrue(fixture.activities.selectTool(activity))
        XCTAssertEqual(fixture.router.dispatch(id: activity.activity.id, source: activity.activity.source,
            instanceToken: activity.instanceToken, action: .init(actionID: "change", value: .none)), .handled)
        try await waitUntil {
            fixture.model.selectedCompatibilitySnapshot?.observation == .rendered &&
                fixture.model.selectedCompatibilitySnapshot?.layoutLimitations.isEmpty == true
        }
        XCTAssertEqual(fixture.runtimes.values.count, 1, "Observing compatibility must not restart JavaScript.")
        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot?.level, .limited)
        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot?.profileLimitations, first.profileLimitations)

        await fixture.model.setEnabled(id: fixture.id, isEnabled: false)
        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot, .profile(for: .superIsland))
    }

    func testSameIDDifferentPackageUsesStaticProfileInsteadOfForeignLayoutReport() async throws {
        let fixture = try await makeFixture(engine: .superIsland, source: Self.compatibleSource)
        defer { fixture.cleanup() }
        let currentValue = await fixture.manager.validatedPackage(id: fixture.id)
        let current = try XCTUnwrap(currentValue)
        let foreign = ValidatedPluginPackage(manifest: current.manifest,
            canonicalRootURL: current.canonicalRootURL.appendingPathComponent("replacement"),
            entryRelativePath: current.entryRelativePath,
            entrySource: Data(Self.compatibleSource.utf8), regularFileCount: 2,
            totalFileBytes: UInt64(Self.compatibleSource.utf8.count))
        // A lifecycle/Manager handoff may briefly expose a same-ID execution
        // with different immutable package identity. It is never this review.
        fixture.lifecycle.pluginWillUnload(id: fixture.id)
        fixture.lifecycle.pluginDidLoad(foreign, isEnabled: true)
        try await waitUntil { fixture.lifecycle.compatibilitySnapshot(for: foreign)?.observation == .rendered }
        await fixture.model.refresh()

        XCTAssertEqual(fixture.model.selectedCompatibilitySnapshot, .profile(for: .superIsland))
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: current))
        XCTAssertFalse(fixture.lifecycle.compatibilitySnapshot(for: foreign)?.layoutLimitations.isEmpty == true)
        XCTAssertEqual(fixture.runtimes.values.count, 1)
    }

    func testEnableRunsRealJavaScriptAndDisableClosesActivityAndOldContext() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        let first = try XCTUnwrap(fixture.runtimes.values.last)
        try await marker(first, "published")
        let oldContext = try XCTUnwrap(fixture.runtimes.contexts.last)
        XCTAssertEqual(fixture.activities.current?.presentation.title, "Extensions running")
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)

        await fixture.model.setEnabled(id: fixture.id, isEnabled: false)

        XCTAssertNil(fixture.model.error)
        XCTAssertNil(fixture.activities.current)
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertFalse(fixture.model.selectedPlugin?.isEnabled == true)
        XCTAssertThrowsError(try oldContext.perform {}) {
            XCTAssertEqual($0 as? PluginExecutionError, .inactiveExecution)
        }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        XCTAssertEqual(fixture.runtimes.values.count, 2)
        try await marker(try XCTUnwrap(fixture.runtimes.values.last), "published")
        XCTAssertThrowsError(try oldContext.perform {})
    }

    func testDisableImmediatelyStopsExecutionEvenWhenStateWriteFails() async throws {
        let stateStore = ExtensionsModelStateStore()
        let fixture = try await makeFixture(stateStore: stateStore)
        defer { fixture.cleanup() }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        let runtime = try XCTUnwrap(fixture.runtimes.values.last)
        try await marker(runtime, "published")
        let context = try XCTUnwrap(fixture.runtimes.contexts.last)
        stateStore.setFailure(true)

        await fixture.model.setEnabled(id: fixture.id, isEnabled: false)

        XCTAssertEqual(fixture.model.error, PluginExtensionsModel.disableFailedMessage)
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertTrue(fixture.model.selectedPlugin?.isEnabled == true)
        XCTAssertNil(fixture.activities.current)
        XCTAssertThrowsError(try context.perform {})
        XCTAssertEqual(fixture.diagnostics.records(for: fixture.id).last?.code, "stateWriteFailed")
        XCTAssertFalse(fixture.model.error?.contains("SECRET") == true)
    }

    func testOldPermissionConfirmationCannotGrantReplacementCode() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let review = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        try Data((Self.source + "\nconst replacement = true;").utf8).write(to: fixture.entryURL)
        _ = try await fixture.manager.reload(id: fixture.id)

        await fixture.model.setPermission(decision: .granted, review: review, permission: .localStorage)

        XCTAssertEqual(fixture.model.error, PluginExtensionsModel.staleReviewMessage)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)
        XCTAssertNotEqual(fixture.model.selectedPermissionSnapshot?.review.scope, review.scope)
        let currentPackage = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(currentPackage)
        XCTAssertThrowsError(try fixture.permissions.require(permission: .localStorage, package: package))
    }

    func testOldUninstallConfirmationCannotRemoveReplacementPackage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let review = try XCTUnwrap(fixture.model.managementReview(id: fixture.id))
        try Data((Self.source + "\nconst replacement = 2;").utf8).write(to: fixture.entryURL)
        _ = try await fixture.manager.reload(id: fixture.id)

        await fixture.model.uninstall(review)

        XCTAssertEqual(fixture.model.error, PluginExtensionsModel.staleReviewMessage)
        XCTAssertEqual(fixture.model.plugins.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.entryURL.path))
        XCTAssertNotNil(fixture.lifecycle.snapshot(id: fixture.id))
    }

    func testClipboardReadAndWriteDecisionsAreIndependentAndRevokeActiveLease() async throws {
        let fixture = try await makeFixture(permissions: [.readClipboard, .writeClipboard])
        defer { fixture.cleanup() }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        let runtime = try XCTUnwrap(fixture.runtimes.values.last)
        try await marker(runtime, "published")
        let review = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        await fixture.model.setPermission(decision: .granted, review: review, permission: .writeClipboard)
        await fixture.model.setPermission(decision: .denied, review: review, permission: .readClipboard)
        let currentPackage = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(currentPackage)
        let writeLease = try fixture.permissions.require(permission: .writeClipboard, package: package)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.writeClipboard], .granted)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.readClipboard], .denied)
        XCTAssertThrowsError(try fixture.permissions.require(permission: .readClipboard, package: package)) {
            XCTAssertEqual($0 as? PluginPermissionError, .denied)
        }

        await fixture.model.setPermission(decision: .revoked, review: review, permission: .writeClipboard)

        XCTAssertThrowsError(try writeLease.perform { XCTFail("A revoked write authorization reached its side effect.") }) {
            XCTAssertEqual($0 as? PluginPermissionError, .revoked)
        }
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.readClipboard], .denied)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.writeClipboard], .revoked)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: fixture.id))
        let alive = try await runtime.evaluateForTesting("1 + 1")
        XCTAssertEqual(alive, .number(2))
    }

    func testUnsupportedDeclaredPermissionCannotBeGrantedButCanBeDenied() async throws {
        let fixture = try await makeFixture(permissions: [.readCalendar, .publishNotifications])
        defer { fixture.cleanup() }
        let review = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        for permission in [PluginPermission.readCalendar, .publishNotifications] {
            XCTAssertFalse(PluginExtensionsModel.supports(permission))
            await fixture.model.setPermission(decision: .granted, review: review, permission: permission)
            XCTAssertEqual(fixture.model.error, PluginExtensionsModel.unsupportedPermissionMessage)
            XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[permission], .requested)
            await fixture.model.setPermission(decision: .denied, review: review, permission: permission)
            XCTAssertNil(fixture.model.error)
            XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[permission], .denied)
        }
    }

    func testUninstallRetainsKVButForgetsAuthorizationAndCrashHistory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let permissionReview = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        await fixture.model.setPermission(decision: .granted, review: permissionReview, permission: .localStorage)
        let currentPackage = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(currentPackage)
        let lease = try fixture.permissions.require(permission: .localStorage, package: package)
        try await fixture.storage.set(pluginID: fixture.id, key: "retained", value: .string("saved KV"))
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        let runtime = try XCTUnwrap(fixture.runtimes.values.last)
        try await marker(runtime, "published")
        let context = try XCTUnwrap(fixture.runtimes.contexts.last)
        XCTAssertTrue(context.reportSeriousFailure(kind: .actionException))
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 1)
        let managementReview = try XCTUnwrap(fixture.model.managementReview(id: fixture.id))

        await fixture.model.uninstall(managementReview)

        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.plugins.isEmpty)
        XCTAssertNil(fixture.model.selectedID)
        XCTAssertNil(fixture.activities.current)
        XCTAssertNil(fixture.watchdog.snapshot(id: fixture.id))
        XCTAssertThrowsError(try fixture.permissions.snapshot(package: package))
        XCTAssertThrowsError(try lease.perform {})
        let saved = try await fixture.storage.get(pluginID: fixture.id, key: "retained")
        XCTAssertEqual(saved, .string("saved KV"))
        let freshURL = try makePackage(in: fixture.configuration.installedDirectoryURL,
                                       id: fixture.id, permissions: [.localStorage])
        _ = try await fixture.manager.load(at: freshURL)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 0)
    }

    func testBusyOperationsQueueUntilEnablementSaveCompletes() async throws {
        let stateStore = ExtensionsModelStateStore()
        let fixture = try await makeFixture(stateStore: stateStore)
        defer { stateStore.releaseSave(); fixture.cleanup() }
        let review = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        stateStore.pauseNextSave()
        let enable = Task { await fixture.model.setEnabled(id: fixture.id, isEnabled: true) }
        try await waitUntil { stateStore.isSavePaused }
        XCTAssertTrue(fixture.model.isBusy)
        let grant = Task { await fixture.model.setPermission(decision: .granted, review: review, permission: .localStorage) }
        await Task.yield()
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)

        stateStore.releaseSave()
        await enable.value
        await grant.value

        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.model.error)
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .granted)
    }

    func testQueuedSameIDInstallationStartsAfterUninstallAuthorizationCleanup() async throws {
        let stateStore = ExtensionsModelStateStore()
        let fixture = try await makeFixture(stateStore: stateStore)
        defer { stateStore.releaseSave(); fixture.cleanup() }
        let oldPermissionReview = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        await fixture.model.setPermission(decision: .granted, review: oldPermissionReview, permission: .localStorage)
        let oldPackageValue = await fixture.manager.validatedPackage(id: fixture.id)
        let oldPackage = try XCTUnwrap(oldPackageValue)
        let oldLease = try fixture.permissions.require(permission: .localStorage, package: oldPackage)
        let uninstallReview = try XCTUnwrap(fixture.model.managementReview(id: fixture.id))
        let replacementURL = try makePackage(in: fixture.configuration.installedDirectoryURL,
                                            id: fixture.id, permissions: [.localStorage], directoryName: "Replacement")
        // Identical manifest/code with a different package root is intentional:
        // uninstall must forget prior authorization even for identical bytes.
        stateStore.pauseNextSave()
        let uninstall = Task { await fixture.model.uninstall(uninstallReview) }
        try await waitUntil { stateStore.isSavePaused }
        let installation = Task { try await fixture.manager.load(at: replacementURL) }
        await Task.yield()
        stateStore.releaseSave()
        await uninstall.value
        _ = try await installation.value
        await fixture.model.refresh()

        XCTAssertNil(fixture.model.error)
        XCTAssertEqual(fixture.model.selectedPlugin?.canonicalRootURL, replacementURL.resolvingSymlinksInPath())
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.localStorage], .requested)
        XCTAssertNotEqual(fixture.model.selectedPermissionSnapshot?.review.scope, oldPermissionReview.scope)
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 0)
        XCTAssertThrowsError(try oldLease.perform {})
    }

    func testUninstallReportsDurableCleanupFailureWhileCurrentGrantsStayRevoked() async throws {
        let fixture = try await makeFixture(durablePermissions: true)
        defer { fixture.cleanup() }
        let permissionReview = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        await fixture.model.setPermission(decision: .granted, review: permissionReview, permission: .localStorage)
        XCTAssertNil(fixture.model.error)
        let packageValue = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(packageValue)
        let lease = try fixture.permissions.require(permission: .localStorage, package: package)
        let managementReview = try XCTUnwrap(fixture.model.managementReview(id: fixture.id))
        let decisionsURL = fixture.configuration.stateDirectoryURL.appendingPathComponent("plugin-permissions-v1.json")
        try Data("SECRET-MALFORMED-PERMISSIONS".utf8).write(to: decisionsURL)

        await fixture.model.uninstall(managementReview)

        XCTAssertEqual(fixture.model.error, PluginExtensionsModel.uninstallCleanupFailedMessage)
        XCTAssertEqual(fixture.model.persistenceError, "本次授权已撤销，授权记录移除失败。")
        XCTAssertTrue(fixture.model.plugins.isEmpty)
        XCTAssertNil(fixture.watchdog.snapshot(id: fixture.id))
        XCTAssertThrowsError(try fixture.permissions.snapshot(package: package))
        XCTAssertThrowsError(try lease.perform {})
        XCTAssertFalse(fixture.model.error?.contains("SECRET") == true)
    }

    func testPermissionAndLifecycleObserversRefreshWithoutPollingOrVMRestart() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        try await marker(try XCTUnwrap(fixture.runtimes.values.last), "published")
        let review = try XCTUnwrap(fixture.model.permissionReview(id: fixture.id))
        try fixture.permissions.applyHostDecision(decision: .denied, review: review, permission: .localStorage)
        try await waitUntil { fixture.model.selectedPermissionSnapshot?.states[.localStorage] == .denied }
        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        try await waitUntil { fixture.model.selectedSnapshot?.state == .suspended }
        XCTAssertEqual(fixture.runtimes.values.count, 1)
    }

    func testEnableDoesNotClearCurrentQuarantine() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)
        try await marker(try XCTUnwrap(fixture.runtimes.values.last), "published")
        let context = try XCTUnwrap(fixture.runtimes.contexts.last)
        for _ in 0..<3 { XCTAssertTrue(context.reportSeriousFailure(kind: .actionException)) }
        let incident = try XCTUnwrap(fixture.lifecycle.snapshot(id: fixture.id)?.quarantine)
        await fixture.model.refresh()

        await fixture.model.setEnabled(id: fixture.id, isEnabled: true)

        XCTAssertEqual(fixture.model.error, PluginExtensionsModel.quarantineMessage)
        XCTAssertEqual(fixture.model.selectedSnapshot?.quarantine, incident)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: fixture.id))
        XCTAssertEqual(fixture.runtimes.values.count, 1)
    }

    func testDiscoveryIssuesAreFixedCodesAndShowLogUsesSharedDiagnosticsModel() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        fixture.model.setDiscoveryReport(.init(plugins: fixture.model.plugins, failures: [
            .init(candidateName: "SECRET-CANDIDATE", error: .candidateUnreadable("SECRET-PATH")),
            .init(candidateName: nil, error: .stateReadFailed)
        ]))
        XCTAssertEqual(fixture.model.discoveryFailures.map(\.code), ["candidateUnreadable", "stateReadFailed"])
        fixture.diagnostics.recordPluginMessage(pluginID: fixture.id, level: .warning)
        await fixture.model.showLog(id: fixture.id)
        XCTAssertEqual(fixture.diagnosticsModel.selectedID, fixture.id)
        XCTAssertEqual(fixture.diagnosticsModel.selectedRecords.count, 1)
        XCTAssertFalse(fixture.model.isBusy)
    }

    private func makeFixture(permissions: [PluginPermission] = [.localStorage],
                             stateStore: ExtensionsModelStateStore? = nil,
                             durablePermissions: Bool = false,
                             engine: PluginEngine = .javaScriptCore,
                             source: String? = nil) async throws -> ExtensionsModelFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Extensions-SECRET-\(UUID().uuidString)")
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let decisionStore = durablePermissions
            ? PluginPermissionDecisionStore(configuration: .init(rootDirectoryURL: root)) : nil
        let permissionManager = PermissionManager(decisionStore: decisionStore)
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root))
        let activities = ActivityManager(configuration: .immediate)
        let diagnostics = PluginDiagnosticsStore()
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let runtimes = ExtensionsModelRuntimes()
        let bridge = PluginJSBridge(storage: storage, permissions: permissionManager, diagnostics: diagnostics)
        let router = ActionRouter(manager: activities)
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: router,
                                              permissions: permissionManager, watchdog: watchdog, diagnostics: diagnostics,
                                              runtimeFactory: { package in
            let runtime = PluginRuntime(package: package, bridge: bridge)
            runtimes.values.append(runtime)
            return ExtensionsModelRuntime(runtime: runtime, collect: { runtimes.contexts.append($0) })
        })
        let manager: PluginManager
        if let stateStore {
            manager = PluginManager(configuration: configuration, stateStore: stateStore, lifecycleHandler: lifecycle)
        } else {
            manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        }
        let initial = await manager.discover()
        XCTAssertTrue(initial.failures.isEmpty)
        let id = "com.example.extensions.model"
        let packageURL = try makePackage(in: configuration.installedDirectoryURL, id: id, permissions: permissions,
                                         engine: engine, source: source)
        _ = try await manager.load(at: packageURL)
        let diagnosticsModel = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: diagnostics)
        let model = PluginExtensionsModel(manager: manager, lifecycle: lifecycle, permissions: permissionManager,
                                          diagnostics: diagnostics, diagnosticsModel: diagnosticsModel)
        await model.refresh()
        return .init(id: id, configuration: configuration, entryURL: packageURL.appendingPathComponent("main.js"),
                     manager: manager, lifecycle: lifecycle, permissions: permissionManager, storage: storage,
                     activities: activities, router: router, watchdog: watchdog, diagnostics: diagnostics,
                     diagnosticsModel: diagnosticsModel, model: model, runtimes: runtimes)
    }

    private func makePackage(in installed: URL, id: String, permissions: [PluginPermission],
                             directoryName: String? = nil, engine: PluginEngine = .javaScriptCore,
                             source: String? = nil) throws -> URL {
        let packageURL = installed.appendingPathComponent(directoryName ?? id, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let manifest = try PluginManifest(id: id, name: "Extensions Test", version: SemanticVersion("1.0.0"),
                                          engine: engine, entry: "main.js", minimumHostVersion: SemanticVersion("0.6.0"),
                                          permissions: permissions, capabilities: engine == .superIsland
                                            ? [.publishActivity, .updateActivity, .islandNodeUI, .handleActions, .localStorage]
                                            : [.publishActivity, .localStorage])
        try manifest.encodeJSON().write(to: packageURL.appendingPathComponent("manifest.json"))
        try Data((source ?? Self.source).utf8).write(to: packageURL.appendingPathComponent("main.js"))
        return packageURL
    }

    private static let source = """
        function onStart() {
            island.activity.publish({id:'extensions', presentation:{title:'Extensions running'}})
              .then(() => { globalThis.published = true; });
        }
        """

    private static let compatibleSource = """
        globalThis.changed = false;
        SuperIsland.registerModule({
            compact: function() {
                return changed ? View.progress(1) : View.button(View.text('Original'), 'change');
            },
            onAction: function(id) { if (id === 'change') changed = true; }
        });
        """

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { throw ExtensionsModelTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionsModelTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private struct ExtensionsModelFixture {
    let id: String
    let configuration: PluginManagerConfiguration
    let entryURL: URL
    let manager: PluginManager
    let lifecycle: PluginLifecycleBridge
    let permissions: PermissionManager
    let storage: PluginStorage
    let activities: ActivityManager
    let router: ActionRouter
    let watchdog: PluginCrashWatchdog
    let diagnostics: PluginDiagnosticsStore
    let diagnosticsModel: PluginDiagnosticsModel
    let model: PluginExtensionsModel
    let runtimes: ExtensionsModelRuntimes

    func cleanup() {
        lifecycle.shutdown()
        try? FileManager.default.removeItem(at: configuration.rootDirectoryURL)
    }
}

@MainActor
private final class ExtensionsModelRuntimes {
    var values: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
}

@MainActor
private final class ExtensionsModelRuntime: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let collect: (PluginExecutionContext) -> Void
    init(runtime: PluginRuntime, collect: @escaping (PluginExecutionContext) -> Void) {
        self.runtime = runtime
        self.collect = collect
    }
    func onStart(context: PluginExecutionContext) throws { collect(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated final class ExtensionsModelStateStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let saveGate = DispatchSemaphore(value: 0)
    private var state = PluginManagerStateFile.empty
    private var fail = false
    private var pause = false
    private var paused = false

    var isSavePaused: Bool { lock.withLock { paused } }
    func load() throws -> PluginManagerStateFile { lock.withLock { state } }
    func save(_ next: PluginManagerStateFile) throws {
        let shouldPause = lock.withLock {
            let value = pause
            pause = false
            paused = value
            return value
        }
        if shouldPause { saveGate.wait(); lock.withLock { paused = false } }
        try lock.withLock {
            if fail { throw PluginManagerError.stateWriteFailed }
            state = next
        }
    }
    func setFailure(_ value: Bool) { lock.withLock { fail = value } }
    func pauseNextSave() { lock.withLock { pause = true } }
    func releaseSave() { saveGate.signal() }
}

private nonisolated enum ExtensionsModelTestError: Error { case timedOut }
