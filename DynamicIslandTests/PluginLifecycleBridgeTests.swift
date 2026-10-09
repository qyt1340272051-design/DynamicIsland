import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginLifecycleBridgeTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 50_000)

    func testDiscoveredPluginStaysDisabledUntilEnableStartsRuntime() async throws {
        let fixture = try await makeFixture(ids: ["com.example.alpha"])
        defer { fixture.remove() }
        let id = "com.example.alpha"

        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .disabled)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertTrue(fixture.factory.runtimes.isEmpty)

        _ = try await fixture.manager.enable(id: id)

        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .running)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.isEnabled, true)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: id))
        XCTAssertEqual(fixture.factory.startCount(id: id), 1)
    }

    func testFactoryUpdatingEnvironmentSynchronouslyDoesNotReenterStart() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        let bridge = fixture.bridge
        fixture.factory.factoryHook = {
            bridge.setEnvironment(isSleeping: false, isLowBattery: false)
        }

        _ = try await fixture.manager.enable(id: id)

        XCTAssertEqual(fixture.factory.factoryInvocationCount, 1)
        XCTAssertEqual(fixture.factory.startCount(id: id), 1)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .running)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: id))
    }

    func testFactoryShutdownCancelsAdmissionAndTearsDownReturnedRuntimeOnce() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        let bridge = fixture.bridge
        fixture.factory.factoryHook = { bridge.shutdown() }

        _ = try await fixture.manager.enable(id: id)

        XCTAssertEqual(fixture.factory.factoryInvocationCount, 1)
        XCTAssertEqual(fixture.factory.startCount(id: id), 0)
        XCTAssertEqual(fixture.factory.teardownCount(id: id), 1)
        XCTAssertTrue(fixture.factory.stopReasons(id: id).isEmpty)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertEqual(fixture.activities.diagnostics.activityCount, 0)
    }

    func testRuntimeCanDiscardContextAfterRegisteringAnActionThatStillExecutes() async throws {
        let id = "com.example.alpha"
        var actionsHandled = 0
        let runtime = ContextDiscardingBridgeTestRuntime(
            activity: IslandActivity(
                id: "alpha.context-discarded",
                source: .init(kind: .plugin, identifier: id),
                priority: .normal,
                lifecycle: .init(policy: .persistent),
                presentation: .init(title: "Context discarded"),
                createdAt: start,
                actions: [.init(id: "plugin.action", title: "Run")]
            ),
            actionHandler: { _ in actionsHandled += 1 }
        )
        let fixture = try await makeFixture(ids: [id], runtimeFactory: { _ in runtime })
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let snapshot = try XCTUnwrap(fixture.activities.currentSnapshot)

        XCTAssertEqual(dispatch(fixture.router, snapshot), .handled)
        XCTAssertEqual(actionsHandled, 1)

        _ = try await fixture.manager.disable(id: id)
        XCTAssertEqual(dispatch(fixture.router, snapshot), .inactiveActivity)
        XCTAssertEqual(actionsHandled, 1)
        XCTAssertEqual(runtime.stopReasons, [.disabled])
        XCTAssertEqual(runtime.teardownCount, 1)
    }

    func testDirectLoadAndReloadReplaceExecutionUsingLatestValidatedEntrySnapshot() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [])
        defer { fixture.remove() }
        let packageURL = try makePackage(
            in: fixture.configuration.installedDirectoryURL,
            directoryName: "DirectLoad",
            id: id
        )
        _ = try await fixture.manager.load(at: packageURL)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .disabled)
        _ = try await fixture.manager.enable(id: id)
        let oldContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        try oldContext.publish(activity("alpha.before-reload", context: oldContext))
        let updatedSource = Data("throw new Error('validated updated snapshot')".utf8)
        try updatedSource.write(to: packageURL.appendingPathComponent("index.js"))

        _ = try await fixture.manager.reload(id: id)

        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .running)
        XCTAssertEqual(fixture.factory.startCount(id: id), 2)
        XCTAssertEqual(fixture.factory.stopReasons(id: id), [.unloaded])
        XCTAssertEqual(fixture.factory.teardownCount(id: id), 1)
        XCTAssertEqual(fixture.factory.runtimes.last?.entrySource, updatedSource)
        XCTAssertNil(fixture.activities.activity(id: "alpha.before-reload"))
        assertRevoked(oldContext)
        let newContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        XCTAssertFalse(oldContext === newContext)
        try newContext.publish(activity("alpha.after-reload", context: newContext))
        XCTAssertNotNil(fixture.activities.activity(id: "alpha.after-reload"))
    }

    func testDisableRemovesPresentedBackgroundQueuedAndDismissedActivitiesOnlyForOwner() async throws {
        let alpha = "com.example.alpha"
        let beta = "com.example.beta"
        let fixture = try await makeFixture(ids: [alpha, beta])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        _ = try await fixture.manager.enable(id: beta)
        let alphaContext = try XCTUnwrap(fixture.factory.contexts(id: alpha).last)
        let betaContext = try XCTUnwrap(fixture.factory.contexts(id: beta).last)

        try alphaContext.publish(activity("alpha.dismissed", context: alphaContext))
        try fixture.activities.dismiss(id: "alpha.dismissed", source: alphaContext.source)
        try alphaContext.publish(activity("alpha.background", context: alphaContext, priority: .background))
        try alphaContext.publish(activity("alpha.current", context: alphaContext, priority: .important))
        try alphaContext.publish(activity("alpha.queued", context: alphaContext, policy: .transient))
        try betaContext.publish(activity("beta.retained", context: betaContext, priority: .background))
        XCTAssertEqual(fixture.activities.activity(id: "alpha.dismissed")?.lifecycle.state, .dismissed)
        XCTAssertEqual(fixture.activities.activity(id: "alpha.background")?.lifecycle.state, .background)
        XCTAssertEqual(fixture.activities.activity(id: "alpha.current")?.lifecycle.state, .presented)
        XCTAssertEqual(fixture.activities.activity(id: "alpha.queued")?.lifecycle.state, .queued)

        _ = try await fixture.manager.disable(id: alpha)

        for id in ["alpha.dismissed", "alpha.background", "alpha.current", "alpha.queued"] {
            XCTAssertNil(fixture.activities.activity(id: id), id)
        }
        XCTAssertNotNil(fixture.activities.activity(id: "beta.retained"))
        XCTAssertEqual(fixture.activities.diagnostics.activityCount, 1)
        XCTAssertEqual(fixture.activities.diagnostics.instanceTokenCount, 1)
        XCTAssertEqual(fixture.bridge.snapshot(id: alpha)?.state, .disabled)
        XCTAssertEqual(fixture.bridge.snapshot(id: beta)?.state, .running)
        var betaCallbackRan = false
        try betaContext.perform { betaCallbackRan = true }
        XCTAssertTrue(betaCallbackRan)
    }

    func testDisableAndReenableNeverRevivesOldContextOrRenderedAction() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let oldContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        var handled = 0
        try oldContext.registerActionHandler { _ in handled += 1 }
        try oldContext.publish(activity("alpha.same-id", context: oldContext))
        let oldSnapshot = try XCTUnwrap(fixture.activities.currentSnapshot)
        XCTAssertEqual(dispatch(fixture.router, oldSnapshot), .handled)
        XCTAssertEqual(handled, 1)

        _ = try await fixture.manager.disable(id: id)
        XCTAssertEqual(dispatch(fixture.router, oldSnapshot), .inactiveActivity)
        assertRevoked(oldContext)
        XCTAssertThrowsError(try fixture.activities.publish(activity("alpha.bypass", context: oldContext)))

        _ = try await fixture.manager.enable(id: id)
        let newContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        XCTAssertFalse(oldContext === newContext)
        try newContext.registerActionHandler { _ in handled += 1 }
        try newContext.publish(activity("alpha.same-id", context: newContext))
        let newSnapshot = try XCTUnwrap(fixture.activities.currentSnapshot)
        XCTAssertNotEqual(oldSnapshot.instanceToken, newSnapshot.instanceToken)
        XCTAssertEqual(dispatch(fixture.router, oldSnapshot), .inactiveActivity)
        assertRevoked(oldContext)
        XCTAssertEqual(dispatch(fixture.router, newSnapshot), .handled)
        XCTAssertEqual(handled, 2)
    }

    func testSleepAndLowBatteryReasonsMustBothClearBeforeResuming() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let oldContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        try oldContext.publish(activity("alpha.running", context: oldContext))

        fixture.bridge.setEnvironment(isSleeping: true, isLowBattery: false)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .suspended)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertNil(fixture.activities.activity(id: "alpha.running"))
        XCTAssertEqual(fixture.factory.stopReasons(id: id), [.suspended])
        assertRevoked(oldContext)

        fixture.bridge.setEnvironment(isSleeping: true, isLowBattery: true)
        fixture.bridge.setEnvironment(isSleeping: false, isLowBattery: true)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .suspended)
        XCTAssertEqual(fixture.factory.startCount(id: id), 1)
        XCTAssertEqual(fixture.factory.stopReasons(id: id), [.suspended])

        fixture.bridge.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .running)
        XCTAssertEqual(fixture.factory.startCount(id: id), 2)
        let resumedContext = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        XCTAssertFalse(oldContext === resumedContext)
        assertRevoked(oldContext)
        var callbackRan = false
        try resumedContext.perform { callbackRan = true }
        XCTAssertTrue(callbackRan)
    }

    func testStartFailureRevokesPartiallyPublishedActivityAndTearsDownRuntime() async throws {
        let id = "com.example.alpha"
        let factory = BridgeTestRuntimeFactory()
        factory.startHook = { context in
            try context.registerActionHandler { _ in XCTFail("Failed startup must not receive actions") }
            try context.publish(self.activity("alpha.partial-start", context: context))
            throw BridgeTestError.callbackFailed
        }
        let fixture = try await makeFixture(ids: [id], factory: factory)
        defer { fixture.remove() }

        _ = try await fixture.manager.enable(id: id)

        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertNotNil(fixture.bridge.snapshot(id: id)?.lastFailure)
        XCTAssertNil(fixture.activities.activity(id: "alpha.partial-start"))
        XCTAssertEqual(factory.startCount(id: id), 1)
        XCTAssertEqual(factory.teardownCount(id: id), 1)
        assertRevoked(try XCTUnwrap(factory.contexts(id: id).last))
    }

    func testStopFailureStillDisablesRevokesActivitiesAndTearsDownRuntime() async throws {
        let id = "com.example.alpha"
        let factory = BridgeTestRuntimeFactory()
        factory.stopHook = { _ in throw BridgeTestError.callbackFailed }
        let fixture = try await makeFixture(ids: [id], factory: factory)
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let context = try XCTUnwrap(factory.contexts(id: id).last)
        try context.publish(activity("alpha.before-stop", context: context))

        _ = try await fixture.manager.disable(id: id)

        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .disabled)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertNotNil(fixture.bridge.snapshot(id: id)?.lastFailure)
        XCTAssertNil(fixture.activities.activity(id: "alpha.before-stop"))
        XCTAssertEqual(factory.stopReasons(id: id), [.disabled])
        XCTAssertEqual(factory.teardownCount(id: id), 1)
        assertRevoked(context)
    }

    func testUninstallRevokesActivitiesAndStopsBeforeMovingPackageDirectory() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let context = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        try context.publish(activity("alpha.before-uninstall", context: context))
        let packageURL = try XCTUnwrap(fixture.packageURLs[id])
        let activities = fixture.activities
        let bridge = fixture.bridge
        var observedStop = false
        fixture.factory.stopHook = { reason in
            XCTAssertEqual(reason, .unloaded)
            XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
            XCTAssertNil(activities.activity(id: "alpha.before-uninstall"))
            XCTAssertFalse(bridge.allowsExecution(id: id))
            observedStop = true
        }

        try await fixture.manager.uninstall(id: id)

        XCTAssertTrue(observedStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertNil(fixture.bridge.snapshot(id: id))
        XCTAssertNil(fixture.activities.activity(id: "alpha.before-uninstall"))
        XCTAssertEqual(fixture.factory.teardownCount(id: id), 1)
        assertRevoked(context)
    }

    func testConcurrentEnableDisableCompletesWithConsistentManagerAndBridgeState() async throws {
        let id = "com.example.alpha"
        let fixture = try await makeFixture(ids: [id])
        defer { fixture.remove() }
        let manager = fixture.manager

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try await manager.enable(id: id)
                    } else {
                        _ = try await manager.disable(id: id)
                    }
                }
            }
            try await group.waitForAll()
        }
        let persistedEnabled = await manager.isEnabled(id: id)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.isEnabled, persistedEnabled)
        XCTAssertEqual(fixture.bridge.allowsExecution(id: id), persistedEnabled)

        _ = try await manager.disable(id: id)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .disabled)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: id))
        XCTAssertEqual(fixture.factory.startCount(id: id), fixture.factory.teardownCount(id: id))
        for context in fixture.factory.contexts(id: id) { assertRevoked(context) }
    }

    func testFailedEnablementStateWritePreservesCurrentRuntimeActivityAndActions() async throws {
        let id = "com.example.alpha"
        let stateStore = BridgeTestStateStore()
        let fixture = try await makeFixture(ids: [id], stateStore: stateStore)
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: id)
        let context = try XCTUnwrap(fixture.factory.contexts(id: id).last)
        var actionsHandled = 0
        try context.registerActionHandler { _ in actionsHandled += 1 }
        try context.publish(activity("alpha.keep-running", context: context))
        let snapshot = try XCTUnwrap(fixture.activities.currentSnapshot)
        stateStore.setSaveFailure(true)

        do {
            _ = try await fixture.manager.disable(id: id)
            XCTFail("Disable must report the failed state write")
        } catch {
            XCTAssertEqual(error as? PluginManagerError, .stateWriteFailed)
        }

        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.state, .running)
        XCTAssertEqual(fixture.bridge.snapshot(id: id)?.isEnabled, true)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: id))
        XCTAssertNotNil(fixture.activities.activity(id: "alpha.keep-running"))
        XCTAssertTrue(fixture.factory.stopReasons(id: id).isEmpty)
        XCTAssertEqual(fixture.factory.teardownCount(id: id), 0)
        XCTAssertEqual(dispatch(fixture.router, snapshot), .handled)
        XCTAssertEqual(actionsHandled, 1)
        var performed = false
        try context.perform { performed = true }
        XCTAssertTrue(performed)

        stateStore.setSaveFailure(false)
        _ = try await fixture.manager.disable(id: id)
        assertRevoked(context)
    }

    func testStopAndShutdownClearActivityAndRevokeExecutionCredentials() async throws {
        let alpha = "com.example.alpha"
        let beta = "com.example.beta"
        let fixture = try await makeFixture(ids: [alpha, beta])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        _ = try await fixture.manager.enable(id: beta)
        let alphaContext = try XCTUnwrap(fixture.factory.contexts(id: alpha).last)
        let betaContext = try XCTUnwrap(fixture.factory.contexts(id: beta).last)
        try alphaContext.publish(activity("alpha.stop", context: alphaContext))
        try betaContext.publish(activity("beta.shutdown", context: betaContext))

        try fixture.bridge.stop(id: alpha)

        XCTAssertEqual(fixture.bridge.snapshot(id: alpha)?.state, .stopped)
        XCTAssertNil(fixture.activities.activity(id: "alpha.stop"))
        XCTAssertNotNil(fixture.activities.activity(id: "beta.shutdown"))
        XCTAssertEqual(fixture.factory.stopReasons(id: alpha), [.stopped])
        assertRevoked(alphaContext)

        fixture.bridge.shutdown()

        XCTAssertFalse(fixture.bridge.allowsExecution(id: beta))
        XCTAssertNil(fixture.activities.current)
        XCTAssertEqual(fixture.activities.diagnostics.activityCount, 0)
        XCTAssertEqual(fixture.factory.stopReasons(id: beta), [.shutdown])
        assertRevoked(betaContext)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let configuration: PluginManagerConfiguration
        let manager: PluginManager
        let activities: ActivityManager
        let router: ActionRouter
        let bridge: PluginLifecycleBridge
        let factory: BridgeTestRuntimeFactory
        let packageURLs: [String: URL]

        func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
    }

    private func makeFixture(
        ids: [String],
        factory: BridgeTestRuntimeFactory? = nil,
        stateStore: BridgeTestStateStore? = nil,
        runtimeFactory: PluginLifecycleBridge.RuntimeFactory? = nil
    ) async throws -> Fixture {
        let factory = factory ?? BridgeTestRuntimeFactory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginLifecycleBridgeTests-\(UUID().uuidString)", isDirectory: true)
        let configuration = PluginManagerConfiguration(
            rootDirectoryURL: root,
            hostVersion: try SemanticVersion("0.6.0")
        )
        let activities = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: activities)
        let makeRuntime: PluginLifecycleBridge.RuntimeFactory
        if let runtimeFactory { makeRuntime = runtimeFactory }
        else { makeRuntime = { package in factory.make(package: package) } }
        let bridge = PluginLifecycleBridge(
            activityManager: activities,
            actionRouter: router,
            runtimeFactory: makeRuntime
        )
        let manager: PluginManager
        if let stateStore {
            manager = PluginManager(configuration: configuration, stateStore: stateStore, lifecycleHandler: bridge)
        } else {
            manager = PluginManager(configuration: configuration, lifecycleHandler: bridge)
        }
        let initial = await manager.discover()
        XCTAssertTrue(initial.failures.isEmpty)
        var packageURLs: [String: URL] = [:]
        for (index, id) in ids.enumerated() {
            packageURLs[id] = try makePackage(
                in: configuration.installedDirectoryURL,
                directoryName: "Plugin\(index)",
                id: id
            )
        }
        let discovered = await manager.discover()
        XCTAssertTrue(discovered.failures.isEmpty)
        XCTAssertEqual(discovered.plugins.map(\.id), ids.sorted())
        return Fixture(
            configuration: configuration,
            manager: manager,
            activities: activities,
            router: router,
            bridge: bridge,
            factory: factory,
            packageURLs: packageURLs
        )
    }

    private func makePackage(in installedDirectory: URL, directoryName: String, id: String) throws -> URL {
        let packageURL = installedDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(packageURL.path, S_IRWXU), 0)
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "name": "Lifecycle Test Plugin",
            "version": "1.0.0",
            "engine": "javascriptcore",
            "entry": "index.js",
            "minimumHostVersion": "0.6.0",
            "permissions": [],
            "capabilities": []
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: packageURL.appendingPathComponent("manifest.json"))
        try Data("throw new Error('T21 does not execute JavaScript')".utf8)
            .write(to: packageURL.appendingPathComponent("index.js"))
        return packageURL
    }

    private func activity(
        _ id: String,
        context: PluginExecutionContext,
        priority: ActivityPriority = .normal,
        policy: ActivityLifecycle.Policy = .persistent
    ) -> IslandActivity {
        IslandActivity(
            id: id,
            source: context.source,
            priority: priority,
            lifecycle: ActivityLifecycle(policy: policy),
            presentation: ActivityPresentation(title: id),
            createdAt: start,
            actions: [.init(id: "plugin.action", title: "Plugin action")]
        )
    }

    private func assertRevoked(
        _ context: PluginExecutionContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var callbackRan = false
        XCTAssertThrowsError(try context.perform { callbackRan = true }, file: file, line: line)
        XCTAssertFalse(callbackRan, file: file, line: line)
        XCTAssertThrowsError(try context.publish(activity("revoked.\(UUID().uuidString)", context: context)), file: file, line: line)
        XCTAssertThrowsError(try context.registerActionHandler { _ in XCTFail("Revoked handler executed") }, file: file, line: line)
    }

    private func dispatch(_ router: ActionRouter, _ snapshot: ActivitySnapshot) -> ActionDispatchResult {
        router.dispatch(
            id: snapshot.activity.id,
            source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken,
            action: IslandRenderAction(actionID: "plugin.action", value: .none)
        )
    }
}

private enum BridgeTestError: Error {
    case callbackFailed
    case stateWriteFailed
}

@MainActor
private final class BridgeTestRuntimeFactory {
    private(set) var runtimes: [BridgeTestRuntime] = []
    private(set) var factoryInvocationCount = 0
    var factoryHook: (() -> Void)?
    var startHook: ((PluginExecutionContext) throws -> Void)?
    var stopHook: ((PluginStopReason) throws -> Void)?

    func make(package: ValidatedPluginPackage) -> BridgeTestRuntime {
        factoryInvocationCount += 1
        let runtime = BridgeTestRuntime(id: package.manifest.id, entrySource: package.entrySource, factory: self)
        runtimes.append(runtime)
        factoryHook?()
        return runtime
    }

    func contexts(id: String) -> [PluginExecutionContext] {
        runtimes.filter { $0.id == id }.flatMap(\.contexts)
    }

    func startCount(id: String) -> Int { contexts(id: id).count }
    func stopReasons(id: String) -> [PluginStopReason] { runtimes.filter { $0.id == id }.flatMap(\.stopReasons) }
    func teardownCount(id: String) -> Int { runtimes.filter { $0.id == id }.reduce(0) { $0 + $1.teardownCount } }
}

@MainActor
private final class BridgeTestRuntime: PluginLifecycleRuntime {
    let id: String
    let entrySource: Data
    private unowned let factory: BridgeTestRuntimeFactory
    private(set) var contexts: [PluginExecutionContext] = []
    private(set) var stopReasons: [PluginStopReason] = []
    private(set) var teardownCount = 0

    init(id: String, entrySource: Data, factory: BridgeTestRuntimeFactory) {
        self.id = id
        self.entrySource = entrySource
        self.factory = factory
    }

    func onStart(context: PluginExecutionContext) throws {
        contexts.append(context)
        try factory.startHook?(context)
    }

    func onStop(reason: PluginStopReason) throws {
        stopReasons.append(reason)
        try factory.stopHook?(reason)
    }

    func teardown() { teardownCount += 1 }
}

/// This runtime deliberately retains neither the execution context nor a
/// callback capturing it. ActionRouter must keep its registered session alive.
@MainActor
private final class ContextDiscardingBridgeTestRuntime: PluginLifecycleRuntime {
    private let activity: IslandActivity
    private let actionHandler: ActionRouter.Handler
    private(set) var stopReasons: [PluginStopReason] = []
    private(set) var teardownCount = 0

    init(activity: IslandActivity, actionHandler: @escaping ActionRouter.Handler) {
        self.activity = activity
        self.actionHandler = actionHandler
    }

    func onStart(context: PluginExecutionContext) throws {
        try context.publish(activity)
        try context.registerActionHandler(actionHandler)
    }

    func onStop(reason: PluginStopReason) throws { stopReasons.append(reason) }
    func teardown() { teardownCount += 1 }
}

private final class BridgeTestStateStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PluginManagerStateFile.empty
    private var failsSave = false

    func load() throws -> PluginManagerStateFile {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ state: PluginManagerStateFile) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsSave { throw BridgeTestError.stateWriteFailed }
        self.state = state
    }

    func setSaveFailure(_ shouldFail: Bool) {
        lock.lock()
        failsSave = shouldFail
        lock.unlock()
    }
}
