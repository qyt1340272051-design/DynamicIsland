import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginWatchdogPersistenceTests: XCTestCase {
    private let alpha = "com.example.persist.alpha"
    private let beta = "com.example.persist.beta"

    func testThreeCurrentActionFailuresImmediatelyIsolateOnlyBadPluginAndPersistDisabledAcrossDiscovery() async throws {
        let fixture = try await makeFixture(ids: [alpha, beta])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        _ = try await fixture.manager.enable(id: beta)
        let bad = try fixture.context(alpha)
        let good = try fixture.context(beta)
        try publish("bad", context: bad)
        try publish("good", context: good)
        var goodCalls = 0
        try good.registerActionHandler { _ in goodCalls += 1 }
        XCTAssertTrue(bad.reportSeriousFailure(kind: .actionException))
        XCTAssertTrue(bad.reportSeriousFailure(kind: .actionRejection))
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertTrue(bad.reportSeriousFailure(kind: .actionException))
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.isEnabled, false)
        XCTAssertNil(fixture.activities.activity(id: "bad"))
        XCTAssertNotNil(fixture.activities.activity(id: "good"))
        XCTAssertThrowsError(try bad.perform {})
        let goodSnapshot = try XCTUnwrap(fixture.activities.currentSnapshot)
        XCTAssertEqual(fixture.router.dispatch(id: "good", source: good.source, instanceToken: goodSnapshot.instanceToken,
            action: .init(actionID: "run", value: .none)), .handled)
        XCTAssertEqual(goodCalls, 1)
        let beforePersistence = await fixture.manager.isEnabled(id: alpha)
        XCTAssertTrue(beforePersistence)
        let event = try XCTUnwrap(fixture.factory.events.first)
        XCTAssertEqual(fixture.factory.events.count, 1)
        let persisted = try await fixture.manager.disableIfCurrent(package: event.package, isIncidentCurrent: {
            fixture.watchdog.isCurrent(incident: event.incident, package: event.package)
        })
        XCTAssertEqual(persisted?.isEnabled, false)
        let fresh = PluginManager(configuration: fixture.configuration)
        let discovered = await fresh.discover()
        XCTAssertTrue(discovered.failures.isEmpty)
        XCTAssertEqual(discovered.plugins.first(where: { $0.id == self.alpha })?.isEnabled, false)
        XCTAssertEqual(discovered.plugins.first(where: { $0.id == self.beta })?.isEnabled, true)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: beta))
    }

    func testFatalStartReportsAcrossExplicitRestartsUseSameHistoryAndPersistThirdFailure() async throws {
        let fixture = try await makeFixture(ids: [alpha])
        defer { fixture.remove() }
        for attempt in 0..<3 {
            _ = try await fixture.manager.enable(id: alpha)
            let context = try fixture.context(alpha)
            try publish("attempt-\(attempt)", context: context)
            XCTAssertTrue(context.reportFailure(.startFailed))
            XCTAssertNil(fixture.activities.activity(id: "attempt-\(attempt)"))
            XCTAssertFalse(context.reportFailure(.startFailed), "A repeated old-token report counted twice.")
        }
        XCTAssertEqual(fixture.factory.contexts[alpha]?.count, 3)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .disabled)
        let event = try XCTUnwrap(fixture.factory.events.first)
        XCTAssertEqual(event.incident.kind, .runtimeStart)
        let persisted = try await fixture.manager.disableIfCurrent(package: event.package, isIncidentCurrent: {
            fixture.watchdog.isCurrent(incident: event.incident, package: event.package)
        })
        XCTAssertEqual(persisted?.isEnabled, false)
        let fresh = PluginManager(configuration: fixture.configuration)
        let discovery = await fresh.discover()
        XCTAssertEqual(discovery.plugins.first?.isEnabled, false)
    }

    func testFailedStateSaveKeepsExecutionQuarantinedWhileManagerRetainsLastCommittedEnablement() async throws {
        let store = PersistenceControlledStore()
        let fixture = try await makeFixture(ids: [alpha], stateStore: store)
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        let context = try fixture.context(alpha)
        try publish("private", context: context)
        for _ in 0..<3 { XCTAssertTrue(context.reportSeriousFailure(kind: .actionException)) }
        let event = try XCTUnwrap(fixture.factory.events.first)
        store.setFailure(true)
        do {
            _ = try await fixture.manager.disableIfCurrent(package: event.package, isIncidentCurrent: {
                fixture.watchdog.isCurrent(incident: event.incident, package: event.package)
            })
            XCTFail("Expected isolation persistence to fail.")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .stateWriteFailed)
            fixture.diagnostics.recordPersistenceFailure(pluginID: alpha)
        }
        let committedEnabled = await fixture.manager.isEnabled(id: alpha)
        XCTAssertTrue(committedEnabled)
        XCTAssertEqual(store.snapshot.plugins[alpha]?.isEnabled, true)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.isEnabled, false)
        XCTAssertNotNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertNil(fixture.activities.activity(id: "private"))
        XCTAssertThrowsError(try context.perform {})
        fixture.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).last?.code, "stateWriteFailed")
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).last?.category, .persistenceFailure)
    }

    func testClearedIncidentRejectsLatePersistenceWithoutWritingOrDisablingHostRestart() async throws {
        let store = PersistenceControlledStore()
        let fixture = try await makeFixture(ids: [alpha], stateStore: store)
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        let context = try fixture.context(alpha)
        for _ in 0..<3 { XCTAssertTrue(context.reportSeriousFailure(kind: .actionException)) }
        let event = try XCTUnwrap(fixture.factory.events.first)
        XCTAssertTrue(fixture.lifecycle.clearQuarantineForHostRestart(id: alpha, incident: event.incident))
        _ = try await fixture.manager.enable(id: alpha)
        let writes = store.writeAttempts
        let stale = try await fixture.manager.disableIfCurrent(package: event.package, isIncidentCurrent: {
            fixture.watchdog.isCurrent(incident: event.incident, package: event.package)
        })
        XCTAssertNil(stale)
        XCTAssertEqual(store.writeAttempts, writes)
        let enabled = await fixture.manager.isEnabled(id: alpha)
        XCTAssertTrue(enabled)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
    }

    func testChangedPackageAndWrongCanonicalRootNeverReachIncidentPredicateOrDisableReplacement() async throws {
        let store = PersistenceControlledStore()
        let fixture = try await makeFixture(ids: [alpha], stateStore: store)
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        let oldValue = await fixture.manager.validatedPackage(id: alpha)
        let old = try XCTUnwrap(oldValue)
        try writeManifest(at: old.canonicalRootURL, id: alpha, version: "2.0.0")
        try Data("replacement code".utf8).write(to: old.canonicalRootURL.appendingPathComponent("index.js"))
        _ = try await fixture.manager.reload(id: alpha)
        _ = try await fixture.manager.enable(id: alpha)
        let predicate = PersistencePredicateCounter()
        let before = store.writeAttempts
        let stale = try await fixture.manager.disableIfCurrent(package: old, isIncidentCurrent: {
            predicate.calls += 1; return true
        })
        XCTAssertNil(stale)
        let currentValue = await fixture.manager.validatedPackage(id: alpha)
        let current = try XCTUnwrap(currentValue)
        let wrongRoot = ValidatedPluginPackage(manifest: current.manifest,
            canonicalRootURL: fixture.root.appendingPathComponent("another-package", isDirectory: true),
            entryRelativePath: current.entryRelativePath, entrySource: current.entrySource,
            regularFileCount: current.regularFileCount, totalFileBytes: current.totalFileBytes)
        let wrong = try await fixture.manager.disableIfCurrent(package: wrongRoot, isIncidentCurrent: {
            predicate.calls += 1; return true
        })
        XCTAssertNil(wrong)
        XCTAssertEqual(predicate.calls, 0)
        XCTAssertEqual(store.writeAttempts, before)
        let enabled = await fixture.manager.isEnabled(id: alpha)
        XCTAssertTrue(enabled)
        XCTAssertEqual(current.manifest.version, try SemanticVersion("2.0.0"))
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
    }

    func testDisableQueuedDuringReloadLifecycleHopCannotCommitAgainstOldPackage() async throws {
        let fixture = try await makeFixture(ids: [alpha])
        defer { fixture.remove() }
        _ = try await fixture.manager.enable(id: alpha)
        let oldValue = await fixture.manager.validatedPackage(id: alpha)
        let old = try XCTUnwrap(oldValue)
        let manager = fixture.manager
        let holder = PersistenceTaskHolder()
        let observation = PersistenceRaceObservation()
        let predicate = PersistencePredicateCounter()
        fixture.factory.stopHook = { reason in
            guard reason == .unloaded else { return }
            let entered = DispatchSemaphore(value: 0)
            holder.task = Task.detached {
                // Manager reads are reentrant while reload owns its FIFO
                // transaction and awaits this MainActor lifecycle callback.
                let observed = await manager.validatedPackage(id: old.manifest.id)
                observation.record(observed == old)
                entered.signal()
                return try await manager.disableIfCurrent(package: old, isIncidentCurrent: {
                    predicate.calls += 1; return true
                })
            }
            XCTAssertEqual(entered.wait(timeout: .now() + .seconds(2)), .success)
        }
        try writeManifest(at: old.canonicalRootURL, id: alpha, version: "2.0.0")
        let reloaded = try await fixture.manager.reload(id: alpha)
        let task = try XCTUnwrap(holder.task)
        let stale = try await task.value
        XCTAssertTrue(observation.sawOldPackage)
        XCTAssertNil(stale)
        XCTAssertEqual(predicate.calls, 0)
        XCTAssertEqual(reloaded.manifest.version, try SemanticVersion("2.0.0"))
        _ = try await fixture.manager.enable(id: alpha)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
    }

    private func makeFixture(ids: [String], stateStore: PersistenceControlledStore? = nil) async throws -> WatchdogPersistenceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root.appendingPathComponent("Plugins", isDirectory: true), hostVersion: try SemanticVersion("0.6.0"))
        let factory = PersistenceRuntimeFactory()
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let diagnostics = PluginDiagnosticsStore()
        let activities = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 1_000)), configuration: .immediate)
        let router = ActionRouter(manager: activities)
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: router, watchdog: watchdog,
            diagnostics: diagnostics, onAutomaticDisable: { package, incident in factory.events.append(.init(package: package, incident: incident)) },
            runtimeFactory: { factory.make(package: $0) })
        let manager: PluginManager
        if let stateStore { manager = PluginManager(configuration: configuration, stateStore: stateStore, lifecycleHandler: lifecycle) }
        else { manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle) }
        _ = await manager.discover()
        for id in ids {
            let packageRoot = configuration.installedDirectoryURL.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try writeManifest(at: packageRoot, id: id, version: "1.0.0")
            try Data("function onStart() {}".utf8).write(to: packageRoot.appendingPathComponent("index.js"))
        }
        let report = await manager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        return .init(root: root, configuration: configuration, manager: manager, lifecycle: lifecycle,
                     watchdog: watchdog, diagnostics: diagnostics, activities: activities, router: router, factory: factory)
    }

    private func writeManifest(at root: URL, id: String, version: String) throws {
        let json: [String: Any] = ["schemaVersion": 1, "id": id, "name": "Persistence Test", "version": version,
            "engine": "javascriptcore", "entry": "index.js", "minimumHostVersion": "0.6.0", "permissions": [],
            "capabilities": ["activity.publish", "actions.handle"]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
    }

    private func publish(_ id: String, context: PluginExecutionContext) throws {
        try context.publish(.init(id: id, source: context.source, priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: id), createdAt: Date(timeIntervalSinceReferenceDate: 1_000), actions: [.init(id: "run", title: "Run")]))
    }
}

@MainActor
private struct PersistenceDisableEvent { let package: ValidatedPluginPackage; let incident: PluginCrashIncident }

@MainActor
private final class PersistenceRuntimeFactory {
    var contexts: [String: [PluginExecutionContext]] = [:]
    var events: [PersistenceDisableEvent] = []
    var stopHook: ((PluginStopReason) -> Void)?
    func make(package: ValidatedPluginPackage) -> PersistenceTestRuntime { .init(factory: self) }
}

@MainActor
private final class PersistenceTestRuntime: PluginLifecycleRuntime {
    private let factory: PersistenceRuntimeFactory
    init(factory: PersistenceRuntimeFactory) { self.factory = factory }
    func onStart(context: PluginExecutionContext) throws { factory.contexts[context.id, default: []].append(context) }
    func onStop(reason: PluginStopReason) throws { factory.stopHook?(reason) }
    func teardown() {}
}

@MainActor
private struct WatchdogPersistenceFixture {
    let root: URL
    let configuration: PluginManagerConfiguration
    let manager: PluginManager
    let lifecycle: PluginLifecycleBridge
    let watchdog: PluginCrashWatchdog
    let diagnostics: PluginDiagnosticsStore
    let activities: ActivityManager
    let router: ActionRouter
    let factory: PersistenceRuntimeFactory
    func context(_ id: String) throws -> PluginExecutionContext { try XCTUnwrap(factory.contexts[id]?.last) }
    func remove() { factory.stopHook = nil; lifecycle.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private nonisolated enum PersistenceStoreError: Error { case failed }
private nonisolated final class PersistenceControlledStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PluginManagerStateFile.empty
    private var fails = false
    private var attempts = 0
    var writeAttempts: Int { lock.withLock { attempts } }
    var snapshot: PluginManagerStateFile { lock.withLock { state } }
    func load() throws -> PluginManagerStateFile { snapshot }
    func save(_ state: PluginManagerStateFile) throws {
        try lock.withLock { attempts += 1; if fails { throw PersistenceStoreError.failed }; self.state = state }
    }
    func setFailure(_ value: Bool) { lock.withLock { fails = value } }
}

@MainActor
private final class PersistencePredicateCounter { var calls = 0 }
@MainActor
private final class PersistenceTaskHolder { var task: Task<PluginRecord?, Error>? }
private nonisolated final class PersistenceRaceObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var sawOldPackage: Bool { lock.withLock { observed } }
    func record(_ value: Bool) { lock.withLock { observed = value } }
}
