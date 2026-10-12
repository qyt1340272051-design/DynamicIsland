import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginWatchdogIntegrationTests: XCTestCase {
    private let alpha = "com.example.watchdog.alpha"
    private let beta = "com.example.watchdog.beta"

    func testThirdRealJavaScriptActionExceptionQuarantinesOnlyOffenderAndKeepsOtherVMInteractive() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let bad = try fixture.load(package(source: actionSource(handler: "throw {message:'private-user-action-secret'};")))
        try await marker(bad, "ready")
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        let good = try fixture.load(package(id: beta, source: actionSource(handler: "globalThis.goodCalls++;", globals: "globalThis.goodCalls=0;")))
        try await marker(good, "ready")
        for count in 1...3 {
            XCTAssertEqual(fixture.dispatch(original), .handled)
            try await waitUntil { fixture.watchdog.snapshot(id: self.alpha)?.recentFailureCount == count }
            if count < 3 {
                XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
                XCTAssertEqual(bad.snapshot.state, .running)
                XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, original.instanceToken)
            }
        }
        let snapshot = try XCTUnwrap(fixture.lifecycle.snapshot(id: alpha))
        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.quarantine?.kind, .actionException)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertNil(fixture.manager.activity(id: original.activity.id))
        XCTAssertEqual(fixture.manager.activityCount(for: original.activity.source), 0)
        XCTAssertNotEqual(fixture.dispatch(original), .handled)
        XCTAssertEqual(fixture.disableWrites.count, 1)
        XCTAssertEqual(fixture.disableWrites.first?.pluginID, alpha)
        try await waitUntil { bad.snapshot.state == .tornDown }
        let survivor = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(survivor.activity.source.identifier, beta)
        XCTAssertEqual(fixture.dispatch(survivor), .handled)
        try await predicate(good, "goodCalls === 1")
        XCTAssertEqual(good.snapshot.state, .running)
        XCTAssertNil(good.snapshot.lastFailure)
        XCTAssertEqual(fixture.watchdog.snapshot(id: beta)?.recentFailureCount, 0)
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).filter { $0.category == .actionFailure }.count, 3)
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).filter { $0.category == .watchdogIsolation }.count, 1)
    }

    func testMixedRealThrownValuesAndPromiseRejectionsNeverInspectOrRetainExceptionPayloads() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let source = actionSource(handler: """
            calls++;
            const privateError = {secret:'https://user:password@example.com/private?clipboard=secret',
                get message(){inspections++;return '/Users/private/secret-file';},
                toString(){inspections++;return 'PRIVATE_ACTION_EXCEPTION_TEXT';},
                toJSON(){inspections++;return 'PRIVATE_ACTION_EXCEPTION_JSON';}};
            if(calls === 2) return Promise.reject(privateError);
            throw privateError;
            """, globals: "globalThis.calls=0;globalThis.inspections=0;")
        let runtime = try fixture.load(package(source: source))
        try await marker(runtime, "ready")
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        for count in 1...2 {
            XCTAssertEqual(fixture.dispatch(original), .handled)
            try await waitUntil { fixture.watchdog.snapshot(id: self.alpha)?.recentFailureCount == count }
            try await assertJavaScript(runtime, "inspections", equals: .number(0))
        }
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil { fixture.lifecycle.snapshot(id: self.alpha)?.quarantine != nil }
        let failures = fixture.diagnostics.records(for: alpha).filter { $0.category == .actionFailure }
        XCTAssertEqual(failures.count, 3)
        XCTAssertTrue(failures.allSatisfy { $0.code == "actionHandlerFailed" && $0.message == "Action handler failed." })
        let retained = fixture.diagnostics.allRecords().map { $0.message + $0.code }.joined()
        for secret in ["password", "clipboard=secret", "/Users/private", "PRIVATE_ACTION_EXCEPTION"] {
            XCTAssertFalse(retained.contains(secret))
        }
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 3)
        XCTAssertEqual(fixture.disableWrites.count, 1)
    }

    func testOrdinaryErrorLogsCannotForgeSeriousFailuresAndSDKHasNoRuntimeReportingAPI() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            function onStart(){Promise.all([
                island.log('Action handler failed.','error'),
                island.log('runtime.actionFailure exception','error'),
                island.log('PRIVATE_PLUGIN_LOG_URL=https://secret.example/token','error')
            ]).then(()=>{globalThis.noPrivateAPI=typeof island.runtime==='undefined';globalThis.done=true;});}
            """))
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "noPrivateAPI", equals: .boolean(true))
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
        XCTAssertNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
        let records = fixture.diagnostics.records(for: alpha)
        XCTAssertEqual(records.filter { $0.category == .pluginMessage }.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.code == "pluginMessage" && $0.message == "Plugin log message omitted." })
        XCTAssertEqual(fixture.disableWrites.count, 0)
    }

    func testPendingActionPromiseLimitReportsNonSeriousDiagnosticsAndRemainsUsable() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: actionSource(
            handler: "calls++;return new Promise(resolve=>resolvers.push(resolve));",
            globals: "globalThis.calls=0;globalThis.resolvers=[];")))
        try await marker(runtime, "ready")
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        for _ in 0..<64 { XCTAssertEqual(fixture.dispatch(original), .handled) }
        try await predicate(runtime, "calls === 64")
        for count in 1...3 {
            XCTAssertEqual(fixture.dispatch(original), .handled)
            try await waitUntil {
                fixture.diagnostics.records(for: self.alpha).filter { $0.category == .actionLimit }.count == count
            }
        }
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
        XCTAssertNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        XCTAssertEqual(runtime.snapshot.state, .running)
        try await assertJavaScript(runtime, "calls", equals: .number(64))
        _ = try await runtime.evaluateForTesting("resolvers[0]();void 0")
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await predicate(runtime, "calls === 65")
        XCTAssertTrue(fixture.diagnostics.records(for: alpha).allSatisfy {
            $0.category == .actionLimit && $0.code == "actionHandlerLimitExceeded"
        })
    }

    func testStaleContextAndPrivateWireCannotCountAgainstReplacementSession() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let package = try package(source: "function onStart(){globalThis.ready=true;}")
        let oldRuntime = try fixture.load(package)
        try await marker(oldRuntime, "ready")
        let oldContext = try XCTUnwrap(fixture.contexts.last)
        XCTAssertTrue(oldContext.reportSeriousFailure(kind: .actionException))
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 1)
        fixture.lifecycle.pluginWillUnload(id: alpha)
        let replacement = try fixture.load(package)
        try await marker(replacement, "ready")
        XCTAssertFalse(oldContext.reportSeriousFailure(kind: .actionRejection))
        let response = await fixture.bridge.handle(try wire(kind: "exception"), package: package, context: oldContext)
        XCTAssertEqual(try errorCode(response), "inactiveExecution")
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 1)
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).filter { $0.category == .actionFailure }.count, 0)
        let current = try XCTUnwrap(fixture.contexts.last)
        XCTAssertTrue(current.reportSeriousFailure(kind: .actionRejection))
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 2)
        XCTAssertEqual(replacement.snapshot.state, .running)
        XCTAssertEqual(fixture.disableWrites.count, 0)
    }

    func testPrivateWireRejectsUnknownKindsUnexpectedFieldsAndWrongPackageWithoutRetainingData() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let package = try package(source: "function onStart(){globalThis.ready=true;}")
        let runtime = try fixture.load(package)
        try await marker(runtime, "ready")
        let context = try XCTUnwrap(fixture.contexts.last)
        let invalid: [PluginBridgeJSON] = [
            .null, .array([]), .object([:]), .object(["kind": .number(1)]),
            .object(["kind": .string("runtimeStart")]), .object(["kind": .string("PRIVATE")]),
            .object(["kind": .string("exception"), "message": .string("PRIVATE_ACTION_EXCEPTION_TEXT")])
        ]
        for params in invalid {
            let response = await fixture.bridge.handle(try wire(params: params), package: package, context: context)
            XCTAssertEqual(try errorCode(response), "invalidArguments")
        }
        let oversized = await fixture.bridge.handle(try wire(kind: "PRIVATE_ACTION_EXCEPTION_TEXT"), package: package, context: context)
        XCTAssertEqual(try errorCode(oversized), "quotaExceeded")
        let other = try self.package(id: beta, source: "")
        let mismatch = await fixture.bridge.handle(try wire(kind: "exception"), package: other, context: context)
        XCTAssertEqual(try errorCode(mismatch), "coreRejected")
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).count, 0)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
    }

    func testQuarantineBlocksOrdinaryEnableAndReloadUntilExactHostRetry() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let package = try package(source: "function onStart(){globalThis.ready=true;}")
        let runtime = try fixture.load(package)
        try await marker(runtime, "ready")
        let context = try XCTUnwrap(fixture.contexts.last)
        for _ in 0..<3 { XCTAssertTrue(context.reportSeriousFailure(kind: .actionException)) }
        let incident = try XCTUnwrap(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        let runtimesBefore = fixture.runtimes.count
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertEqual(fixture.runtimes.count, runtimesBefore)
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertEqual(fixture.runtimes.count, runtimesBefore)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.quarantine, incident)
        XCTAssertTrue(fixture.lifecycle.clearQuarantineForHostRestart(id: alpha, incident: incident))
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: alpha))
        fixture.clock.now += 61
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        let replacement = try XCTUnwrap(fixture.runtimes.last)
        try await marker(replacement, "ready")
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
        XCTAssertFalse(fixture.lifecycle.clearQuarantineForHostRestart(id: alpha, incident: incident))
        XCTAssertFalse(context.reportSeriousFailure(kind: .actionException))
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
    }

    func testThreeActualJavaScriptStartExceptionsCountAcrossHostRetriesAndKeepFixedDiagnostics() async throws {
        let fixture = WatchdogRuntimeFixture()
        defer { fixture.shutdown() }
        let package = try package(source: "function onStart(){throw new Error('PRIVATE_START_EXCEPTION_PAYLOAD');}")
        _ = try fixture.load(package)
        try await waitUntil { fixture.watchdog.snapshot(id: self.alpha)?.recentFailureCount == 1 }
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .stopped)
        for count in 2...3 {
            fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
            try await waitUntil { fixture.watchdog.snapshot(id: self.alpha)?.recentFailureCount == count }
        }
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .disabled)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.quarantine?.kind, .runtimeStart)
        XCTAssertEqual(fixture.disableWrites.count, 1)
        XCTAssertFalse(fixture.diagnostics.allRecords().contains { $0.message.contains("PRIVATE_START_EXCEPTION_PAYLOAD") })
        XCTAssertTrue(fixture.diagnostics.records(for: alpha).contains { $0.category == .runtimeFailure && $0.phase == .start })
    }

    func testFactoryThrowsAndSynchronousOnStartThrowsShareSeriousStartBudget() throws {
        let fixture = WatchdogHostFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package(source: "")
        fixture.behavior.mode = .factoryThrow
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 1)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .stopped)
        fixture.behavior.mode = .startThrow
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 2)
        XCTAssertEqual(fixture.behavior.teardownCount, 1)
        fixture.behavior.mode = .factoryThrow
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 3)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .disabled)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.quarantine?.kind, .runtimeStart)
        XCTAssertEqual(fixture.behavior.incidents.count, 1)
    }

    func testRepeatedStopHookFailuresAndLateStopReportsNeverIncreaseSeriousFailureBudget() throws {
        let fixture = WatchdogHostFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package(source: "")
        fixture.behavior.mode = .stopThrow
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let oldContext = try XCTUnwrap(fixture.behavior.contexts.last)
        for _ in 0..<3 {
            try fixture.lifecycle.stop(id: alpha)
            XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.lastFailure, .stopFailed)
            fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        }
        XCTAssertFalse(oldContext.reportFailure(.stopFailed))
        XCTAssertEqual(fixture.watchdog.snapshot(id: alpha)?.recentFailureCount, 0)
        XCTAssertNil(fixture.lifecycle.snapshot(id: alpha)?.quarantine)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: alpha))
        XCTAssertEqual(fixture.behavior.incidents.count, 0)
        XCTAssertEqual(fixture.diagnostics.records(for: alpha).filter { $0.category == .lifecycleFailure && $0.code == "stopFailed" }.count, 3)
    }

    private func package(id: String = "com.example.watchdog.alpha", source: String) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Watchdog Integration", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [], capabilities: [.publishActivity, .updateActivity, .endActivity, .handleActions])
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/watchdog-tests/\(id)"),
            entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func actionSource(handler: String, globals: String = "") -> String {
        """
        \(globals)
        function onStart(){island.actions.on('fire',function(){\(handler)})
            .then(()=>island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},
                presentation:{title:'Watchdog controls'},actions:[{id:'fire',title:'Fire'}]}))
            .then(()=>{globalThis.ready=true;});}
        """
    }

    private func wire(kind: String) throws -> String { try wire(params: .object(["kind": .string(kind)])) }
    private func wire(params: PluginBridgeJSON) throws -> String {
        try PluginBridgeJSON.object(["apiVersion": .string("1.0.0"), "method": .string("runtime.actionFailure"), "params": params]).encodedString()
    }
    private func errorCode(_ json: String) throws -> String {
        guard case .object(let outer) = try PluginBridgeJSON.parse(json),
              case .object(let error)? = outer["error"], case .string(let code)? = error["code"] else {
            XCTFail("Expected a fixed bridge error response."); throw WatchdogIntegrationError.invalidResponse
        }
        return code
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Watchdog integration timed out."); throw WatchdogIntegrationError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func predicate(_ runtime: PluginRuntime, _ source: String) async throws {
        try await waitUntil { runtime.snapshot.state == .running || runtime.snapshot.lastFailure != nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while try await runtime.evaluateForTesting(source) != .boolean(true) {
            guard ContinuousClock.now < deadline else { XCTFail("JavaScript predicate did not settle."); throw WatchdogIntegrationError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func marker(_ runtime: PluginRuntime, _ name: String) async throws { try await predicate(runtime, "globalThis['\(name)'] === true") }
    private func assertJavaScript(_ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue) async throws {
        let value = try await runtime.evaluateForTesting(source)
        XCTAssertEqual(value, expected)
    }
}

@MainActor
private final class WatchdogTestClock {
    var now: TimeInterval = 1_000
}

@MainActor
private final class WatchdogRuntimeFixture {
    let clock = WatchdogTestClock()
    let diagnostics = PluginDiagnosticsStore()
    let watchdog: PluginCrashWatchdog
    let manager: ActivityManager
    let router: ActionRouter
    let bridge: PluginJSBridge
    let lifecycle: PluginLifecycleBridge
    private let factory = WatchdogRuntimeFactory()
    var runtimes: [PluginRuntime] { factory.runtimes }
    var contexts: [PluginExecutionContext] { factory.contexts }
    var disableWrites: [PluginCrashIncident] { factory.incidents }

    init() {
        let clock = clock
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        self.watchdog = watchdog
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 100_000)), configuration: .immediate)
        self.manager = manager
        let router = ActionRouter(manager: manager)
        self.router = router
        let service = PluginJSBridge(diagnostics: diagnostics, activityRateClock: { 1_000 })
        bridge = service
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, watchdog: watchdog,
            diagnostics: diagnostics, onAutomaticDisable: { _, incident in factory.incidents.append(incident) }) { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return WatchdogRuntimeForwarder(runtime: runtime, factory: factory)
        }
    }
    func load(_ package: ValidatedPluginPackage) throws -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.runtimes.last)
    }
    func dispatch(_ snapshot: ActivitySnapshot) -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
                        action: .init(actionID: "fire", value: .none))
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class WatchdogRuntimeFactory {
    var runtimes: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
    var incidents: [PluginCrashIncident] = []
}

@MainActor
private final class WatchdogRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    private let factory: WatchdogRuntimeFactory
    init(runtime: PluginRuntime, factory: WatchdogRuntimeFactory) { self.runtime = runtime; self.factory = factory }
    func onStart(context: PluginExecutionContext) throws {
        factory.contexts.append(context)
        try runtime.onStart(context: context)
    }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

@MainActor
private final class WatchdogHostBehavior {
    enum Mode { case running, factoryThrow, startThrow, stopThrow }
    var mode = Mode.running
    var contexts: [PluginExecutionContext] = []
    var teardownCount = 0
    var incidents: [PluginCrashIncident] = []
}

@MainActor
private final class WatchdogHostFixture {
    let watchdog = PluginCrashWatchdog(clock: { 1_000 })
    let diagnostics = PluginDiagnosticsStore()
    let behavior = WatchdogHostBehavior()
    let lifecycle: PluginLifecycleBridge
    init() {
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 100_000)), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        let behavior = behavior
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, watchdog: watchdog,
            diagnostics: diagnostics, onAutomaticDisable: { _, incident in behavior.incidents.append(incident) }) { _ in
            if behavior.mode == .factoryThrow { throw WatchdogIntegrationError.deliberate }
            return WatchdogHostRuntime(behavior: behavior)
        }
    }
}

@MainActor
private final class WatchdogHostRuntime: PluginLifecycleRuntime {
    private let behavior: WatchdogHostBehavior
    init(behavior: WatchdogHostBehavior) { self.behavior = behavior }
    func onStart(context: PluginExecutionContext) throws {
        behavior.contexts.append(context)
        if behavior.mode == .startThrow { throw WatchdogIntegrationError.deliberate }
    }
    func onStop(reason: PluginStopReason) throws {
        if behavior.mode == .stopThrow { throw WatchdogIntegrationError.deliberate }
    }
    func teardown() { behavior.teardownCount += 1 }
}

private nonisolated enum WatchdogIntegrationError: Error {
    case deliberate, invalidResponse, timedOut
}
