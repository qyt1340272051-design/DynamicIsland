import Foundation
import JavaScriptCore
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownBridgeTests: XCTestCase {
    func testRealJavaScriptRequiresActionThenCompletesWhileToolIsHidden() async throws {
        let f = CountdownBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let vm = try await f.load()
        try await assertJS(vm, "startupError", .string("activationRequired"))
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
        try f.act("start")
        try await settled(vm, "state === 'running'")
        try await assertJS(vm, "Object.isFrozen(timer) && Object.getPrototypeOf(timer) === null", .boolean(true))
        f.manager.clearToolSelection()
        f.clock.now += .milliseconds(999)
        f.broker.processDue()
        try await assertJS(vm, "events.length", .number(0))
        f.clock.now += .milliseconds(1)
        f.broker.processDue()
        try await settled(vm, "events.length === 1 && state === 'completed' && replayError === 'activationRequired'")
        try await assertJS(vm, "events[0].remainingMs === 0 && !('activation' in events[0]) && Object.isFrozen(events[0])", .boolean(true))
        f.broker.processDue()
        try await assertJS(vm, "events.length", .number(1))
        XCTAssertEqual(f.broker.diagnostics.alarmCount, 0)
        _ = try await vm.evaluateForTesting("globalThis.reregistered = false; void island.countdown.onComplete(event => events.push(event)).then(() => { globalThis.reregistered = true; });")
        try await settled(vm, "reregistered === true")
        try await assertJS(vm, "events.length", .number(1))
    }

    func testPauseResumePreservesExactRemainderAndRejectsOldGeneration() async throws {
        let f = CountdownBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let vm = try await f.load(duration: 10_000)
        try f.act("start")
        try await settled(vm, "state === 'running'")
        let old = try XCTUnwrap(try f.broker.get(owner: f.owner(), id: "focus"))
        f.clock.now += .milliseconds(1_234) + .microseconds(500)
        try f.act("pause")
        try await settled(vm, "state === 'paused'")
        let paused = try XCTUnwrap(try f.broker.get(owner: f.owner(), id: "focus"))
        XCTAssertEqual(paused.remaining, .milliseconds(8_765) + .microseconds(500))
        XCTAssertEqual(paused.remainingMilliseconds, 8_766)
        XCTAssertNotEqual(old.generation, paused.generation)
        let denied = await f.request("countdown.stop", fields: ["id": .string("focus"), "generation": .string(old.generation.rawValue)])
        XCTAssertEqual(denied, "staleCountdown")
        f.clock.now += .seconds(100)
        XCTAssertEqual(try f.broker.get(owner: f.owner(), id: "focus")?.remaining, paused.remaining)
        try f.act("resume")
        try await settled(vm, "state === 'running'")
        f.clock.now += paused.remaining - .nanoseconds(1)
        f.broker.processDue()
        try await assertJS(vm, "events.length", .number(0))
        f.clock.now += .nanoseconds(1)
        f.broker.processDue()
        try await settled(vm, "events.length === 1")
    }

    func testSuspensionRetainsBusinessRecordAndResumedVMReceivesOverdueCompletion() async throws {
        let f = CountdownBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let oldVM = try await f.load()
        try f.act("start")
        try await settled(oldVM, "state === 'running'")
        let owner = try f.owner()
        let generation = try XCTUnwrap(try f.broker.get(owner: owner, id: "focus")).generation
        f.lifecycle.setEnvironment(isSleeping: true, isLowBattery: true)
        XCTAssertFalse(f.lifecycle.allowsExecution(id: f.id))
        XCTAssertEqual(f.broker.diagnostics.recordCount, 1)
        XCTAssertEqual(f.broker.diagnostics.alarmCount, 0)
        f.clock.now += .seconds(20)
        f.broker.processDue()
        f.lifecycle.setEnvironment(isSleeping: false, isLowBattery: true)
        XCTAssertEqual(f.runtimes.count, 1)
        f.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(f.runtimes.count, 2)
        let resumed = try XCTUnwrap(f.runtimes.last)
        try await settled(resumed, "ready === true && state === 'completed' && events.length === 1")
        XCTAssertEqual(try f.owner(), owner)
        XCTAssertEqual(try f.broker.get(owner: owner, id: "focus")?.generation, generation)
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: false)
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: true)
        try await settled(try XCTUnwrap(f.runtimes.last), "ready === true")
        XCTAssertNotEqual(try f.owner(), owner)
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
    }

    func testIndependentHostValidationRejectsMalformedFieldsWithoutChangingTimer() async throws {
        let f = CountdownBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let vm = try await f.load()
        try f.act("start")
        try await settled(vm, "state === 'running'")
        let original = try f.broker.get(owner: f.owner(), id: "focus")
        for fields: [String: PluginBridgeJSON] in [
            ["id": .string("focus"), "owner": .string("other")],
            ["id": .boolean(true)], ["id": .string("../other")]
        ] {
            let code = await f.request("countdown.get", fields: fields)
            XCTAssertEqual(code, "invalidArguments")
            XCTAssertEqual(try f.broker.get(owner: f.owner(), id: "focus"), original)
        }
        for value: PluginBridgeJSON in [.null, .boolean(true), .number(999), .number(1_000.1), .number(86_400_001), .string("1000")] {
            let code = await f.request("countdown.start", fields: ["id": .string("focus"), "durationMs": value, "activation": .string("forged")])
            XCTAssertEqual(code, "invalidArguments")
            XCTAssertEqual(try f.broker.get(owner: f.owner(), id: "focus"), original)
        }
    }

    func testDirectRuntimeTeardownClearsItsRecordWithoutClosingOtherOwner() async throws {
        let f = CountdownBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let vm = try await f.load()
        try f.act("start")
        try await settled(vm, "state === 'running'")
        let other = try f.broker.registerOwner(pluginID: "com.example.countdown-other")
        _ = try f.broker.start(owner: other, id: "other", durationMilliseconds: 1_000)
        vm.teardown()
        XCTAssertNil(try f.broker.get(owner: f.owner(), id: "focus"))
        XCTAssertNotNil(try f.broker.get(owner: other, id: "other"))
    }

    private func assertJS(_ runtime: PluginRuntime, _ expression: String, _ expected: PluginJavaScriptValue,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await runtime.evaluateForTesting(expression)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func settled(_ runtime: PluginRuntime, _ expression: String) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < limit {
            if try await runtime.evaluateForTesting(expression) == .boolean(true) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Countdown JavaScript did not settle: \(expression)")
    }
}

@MainActor
private final class CountdownBridgeClock {
    var now: Duration = .zero
}

@MainActor
private final class CountdownBridgeFixture {
    let id = "com.example.countdown-bridge"
    let clock = CountdownBridgeClock()
    let manager = ActivityManager(configuration: .init(ordinaryDebounce: 0, minimumDwell: 0))
    lazy var router = ActionRouter(manager: manager)
    lazy var broker = PluginCountdownBroker(clock: { [clock] in clock.now }, automaticScheduling: false)
    let bridge = PluginJSBridge()
    var runtimes: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
    var package: ValidatedPluginPackage!
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, countdownBroker: broker,
                                               runtimeFactory: { [unowned self] package in
        let vm = PluginRuntime(package: package, bridge: bridge)
        runtimes.append(vm)
        return CountdownCapturingRuntime(runtime: vm) { [weak self] in self?.contexts.append($0) }
    })

    func load(duration: Int = 1_000) async throws -> PluginRuntime {
        let manifest = try PluginManifest(id: id, name: "Countdown Bridge", version: SemanticVersion("1.0.0"),
                                          engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
                                          permissions: [], capabilities: [.publishActivity, .updateActivity, .handleActions, .countdown])
        let source = """
            globalThis.ready = false; globalThis.state = 'idle'; globalThis.events = [];
            globalThis.timer = null; globalThis.startupError = ''; globalThis.replayError = '';
            let lastActivation;
            function remember(value) { globalThis.timer = value; globalThis.state = value ? value.state : 'idle'; }
            function onStart() {
                Promise.all([
                    island.actions.on('start', event => {
                        lastActivation = event.activation;
                        return island.countdown.start({id:'focus',durationMs:\(duration),activation:event.activation}).then(remember);
                    }),
                    island.actions.on('pause', () => island.countdown.pause({id:'focus',generation:timer.generation}).then(remember)),
                    island.actions.on('resume', event => island.countdown.resume({id:'focus',generation:timer.generation,activation:event.activation}).then(remember)),
                    island.countdown.onComplete(event => {
                        events.push(event); remember(event);
                        return island.countdown.start({id:'focus',durationMs:1000,activation:lastActivation || 'forged'})
                            .catch(error => { globalThis.replayError = error.code; });
                    }),
                    island.countdown.start({id:'focus',durationMs:1000,activation:'forged'})
                        .catch(error => { globalThis.startupError = error.code; })
                ]).then(() => island.countdown.get('focus')).then(value => {
                    remember(value);
                    return island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},
                        presentation:{title:'Countdown controls',role:'tool',showsCompact:false},
                        actions:[{id:'start',title:'Start'},{id:'pause',title:'Pause'},{id:'resume',title:'Resume'}]});
                }).then(() => { globalThis.ready = true; });
            }
            function onStop() {}
            """
        package = .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/countdown-bridge/"),
                        entryRelativePath: "index.js", entrySource: Data(source.utf8), regularFileCount: 2,
                        totalFileBytes: UInt64(source.utf8.count))
        lifecycle.pluginDidLoad(package, isEnabled: true)
        let vm = runtimes[0]
        let limit = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < limit {
            if try await vm.evaluateForTesting("ready") == .boolean(true) { return vm }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Countdown fixture failed to start")
        return vm
    }

    func owner() throws -> PluginCountdownOwner { try XCTUnwrap(contexts.last?.countdownOwner) }

    func act(_ actionID: String) throws {
        let snapshot = try XCTUnwrap(manager.toolSnapshots.first)
        XCTAssertTrue(manager.selectTool(snapshot))
        XCTAssertEqual(router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
                                       instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)), .handled)
    }

    func request(_ method: String, fields: [String: PluginBridgeJSON]) async -> String? {
        let source = try! PluginBridgeJSON.object(["apiVersion": .string("1.0.0"), "method": .string(method), "params": .object(fields)]).encodedString()
        let reply = await bridge.handle(source, package: package, context: contexts.last!)
        guard case .object(let envelope) = try? PluginBridgeJSON.parse(reply),
              case .object(let error)? = envelope["error"], case .string(let code)? = error["code"] else { return nil }
        return code
    }
}

@MainActor
private final class CountdownCapturingRuntime: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let capture: (PluginExecutionContext) -> Void
    init(runtime: PluginRuntime, capture: @escaping (PluginExecutionContext) -> Void) {
        self.runtime = runtime; self.capture = capture
    }
    func onStart(context: PluginExecutionContext) throws { capture(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}
