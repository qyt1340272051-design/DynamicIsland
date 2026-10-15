import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroPluginTests: XCTestCase {
    func testValidatedOfficialPackageStartsEveryPresetThroughRealRouterActions() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        XCTAssertEqual(f.package.manifest.id, "com.dynamicisland.pomodoro")
        XCTAssertEqual(f.package.manifest.version, try SemanticVersion("0.1.0"))
        XCTAssertTrue(f.package.manifest.permissions.isEmpty)
        XCTAssertEqual(Set(f.package.manifest.capabilities), Set([
            .publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions, .countdown
        ]))
        try await f.load()
        XCTAssertNil(f.manager.currentSnapshot)
        XCTAssertEqual(f.tool?.presentation.title, "番茄钟")
        XCTAssertEqual(f.tool?.presentation.subtitle, "25 分钟 · 准备专注")
        XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
        XCTAssertEqual(Set(try XCTUnwrap(f.tool).actions.map(\.id)), Set([
            "start", "pause", "resume", "stop", "preset.15", "preset.25", "preset.45", "preset.60"
        ]))
        XCTAssertTrue(f.references.isEmpty)
        for minutes in [15, 25, 45, 60] {
            try f.act("preset.\(minutes)")
            try await f.waitForState("准备专注", minutes: minutes)
            try f.act("start")
            try await f.waitForState("专注中", minutes: minutes)
            let running = try XCTUnwrap(try f.record())
            XCTAssertEqual(running.state, .running)
            XCTAssertEqual(running.durationMilliseconds, minutes * 60_000)
            XCTAssertEqual(running.remaining, .milliseconds(minutes * 60_000))
            XCTAssertTrue(try XCTUnwrap(f.tool).presentation.isCompactVisible)
            XCTAssertEqual(f.tool?.presentation.compactPolicy, .automatic)
            XCTAssertEqual(f.tool?.priority, .background)
            XCTAssertEqual(Set(f.references.map(\.style)), Set([.time, .progress]))
            XCTAssertTrue(f.references.allSatisfy { $0.id == "session" && $0.generation == running.generation.rawValue })
            try f.act("stop")
            try await f.waitForState("准备专注", minutes: minutes)
            XCTAssertNil(try f.record())
            XCTAssertTrue(f.references.isEmpty)
        }
        f.assertNoFailures()
    }

    func testPauseResumePreservesNanosecondsAndStopClearsTheHostRecord() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        try f.act("start")
        try await f.waitForState("专注中")
        let running = try XCTUnwrap(try f.record())
        let elapsed = Duration.nanoseconds(1_234_567_890)
        f.clock.now += elapsed
        try f.act("pause")
        try await f.waitForState("已暂停")
        let paused = try XCTUnwrap(try f.record())
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.remaining, .milliseconds(25 * 60_000) - elapsed)
        XCTAssertNotEqual(paused.generation, running.generation)
        f.clock.now += .seconds(100)
        XCTAssertEqual(try f.record(), paused)
        try f.act("resume")
        try await f.waitForState("专注中")
        let resumed = try XCTUnwrap(try f.record())
        XCTAssertEqual(resumed.state, .running)
        XCTAssertEqual(resumed.remaining, paused.remaining)
        XCTAssertNotEqual(resumed.generation, paused.generation)
        XCTAssertTrue(f.references.allSatisfy { $0.generation == resumed.generation.rawValue })
        try f.act("stop")
        try await f.waitForState("准备专注")
        XCTAssertNil(try f.record())
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
        XCTAssertTrue(f.references.isEmpty)
        XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
        f.assertNoFailures()
    }

    func testRunningPresetIsIgnoredAndPausedPresetStopsBeforeReturningToIdle() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        try f.act("start")
        try await f.waitForState("专注中")
        let running = try XCTUnwrap(try f.record())
        let publications = f.clock.publicationCount
        // Both are real FIFO actions. The later pause's public result also
        // establishes that the preceding ignored preset reached the VM.
        try f.act("preset.60")
        try f.act("pause")
        try await f.waitForState("已暂停", minutes: 25)
        let paused = try XCTUnwrap(try f.record())
        XCTAssertEqual(paused.durationMilliseconds, running.durationMilliseconds)
        XCTAssertEqual(paused.remaining, running.remaining)
        XCTAssertEqual(f.clock.publicationCount, publications + 1)
        try f.act("preset.15")
        try await f.waitForState("准备专注", minutes: 15)
        XCTAssertNil(try f.record())
        XCTAssertTrue(f.references.isEmpty)
        try f.act("start")
        try await f.waitForState("专注中", minutes: 15)
        XCTAssertEqual(try f.record()?.durationMilliseconds, 15 * 60_000)
        f.assertNoFailures()
    }

    func testNaturalCompletionPublishesOneTransientAndNeverRestartsItself() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        let capture = PomodoroPluginCompletionCapture()
        let observation = f.manager.$currentSnapshot.sink { snapshot in
            if snapshot?.activity.id == f.completionID { capture.snapshots.append(snapshot!) }
        }
        try f.act("start")
        try await f.waitForState("专注中")
        let running = try XCTUnwrap(try f.record())
        f.clock.now += running.remaining - .nanoseconds(1)
        f.broker.processDue()
        XCTAssertNil(f.manager.activity(id: f.completionID))
        XCTAssertEqual(try f.record()?.state, .running)
        f.clock.now += .nanoseconds(1)
        f.broker.processDue()
        try await f.waitForState("本轮已完成")
        try await f.waitUntil { f.manager.activity(id: f.completionID) != nil }
        let completion = try XCTUnwrap(f.manager.currentSnapshot)
        XCTAssertEqual(completion.activity.id, f.completionID)
        XCTAssertEqual(completion.activity.source, try f.context().source)
        XCTAssertEqual(completion.activity.presentation.title, "专注完成")
        XCTAssertEqual(completion.activity.presentation.subtitle, "本轮专注已结束")
        XCTAssertEqual(completion.activity.presentation.effectiveRole, .status)
        XCTAssertEqual(completion.activity.lifecycle.policy, .transient)
        XCTAssertEqual(completion.activity.priority, .normal)
        XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
        XCTAssertEqual(try f.record()?.generation, running.generation)
        XCTAssertEqual(try f.record()?.remaining, .zero)
        XCTAssertEqual(f.broker.diagnostics.runningCount, 0)
        XCTAssertEqual(f.broker.diagnostics.completedCount, 1)
        XCTAssertEqual(f.broker.diagnostics.alarmCount, 0)
        let publications = f.clock.publicationCount
        for _ in 0..<3 { f.broker.processDue(); await Task.yield() }
        f.activityClock.advance(by: 3)
        f.manager.processDeadlines()
        XCTAssertNil(f.manager.activity(id: f.completionID))
        f.clock.now += .seconds(3_600)
        f.broker.processDue()
        try await f.flushWorker()
        XCTAssertEqual(capture.snapshots.count, 1)
        XCTAssertEqual(f.clock.publicationCount, publications)
        XCTAssertEqual(try f.record()?.generation, running.generation)
        XCTAssertEqual(try f.record()?.state, .completed)
        XCTAssertEqual(f.runtimes.count, 1)
        f.assertNoFailures()
        withExtendedLifetime(observation) {}
    }

    func testHostDisplayAdvancesWithoutPerSecondJavaScriptActivityUpdates() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        try f.act("start")
        try await f.waitForState("专注中")
        let snapshot = try XCTUnwrap(f.manager.currentSnapshot)
        let reference = try XCTUnwrap(f.references.first { $0.style == .time })
        let publications = f.clock.publicationCount
        XCTAssertEqual(f.lifecycle.resolveCountdown(reference, for: snapshot)?.text, "25:00")
        for _ in 0..<3 {
            f.clock.now += .seconds(1)
            f.broker.processDue()
        }
        try await f.flushWorker()
        XCTAssertEqual(f.lifecycle.resolveCountdown(reference, for: snapshot)?.text, "24:57")
        XCTAssertTrue(try XCTUnwrap(f.lifecycle.resolveCountdown(reference, for: snapshot)).requiresTick)
        XCTAssertEqual(f.manager.currentSnapshot, snapshot)
        XCTAssertEqual(f.clock.publicationCount, publications)
        XCTAssertEqual(f.runtimes.count, 1)
        f.assertNoFailures()
    }

    func testBothSuspensionConditionsMustClearBeforeNewVMRestoresOwnerGenerationAndPreset() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        try f.act("preset.45")
        try await f.waitForState("准备专注", minutes: 45)
        try f.act("start")
        try await f.waitForState("专注中", minutes: 45)
        let oldContext = try f.context()
        let owner = try f.owner()
        let running = try XCTUnwrap(try f.record())
        let oldActivity = try XCTUnwrap(f.manager.currentSnapshot)
        f.lifecycle.setEnvironment(isSleeping: true, isLowBattery: true)
        XCTAssertFalse(f.lifecycle.allowsExecution(id: f.id))
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertTrue(f.manager.toolSnapshots.isEmpty)
        XCTAssertEqual(f.broker.diagnostics.recordCount, 1)
        f.clock.now += .seconds(60) + .nanoseconds(123)
        f.lifecycle.setEnvironment(isSleeping: false, isLowBattery: true)
        XCTAssertEqual(f.runtimes.count, 1)
        XCTAssertFalse(f.lifecycle.allowsExecution(id: f.id))
        f.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        try await f.waitForState("专注中", minutes: 45)
        XCTAssertEqual(f.runtimes.count, 2)
        XCTAssertEqual(try f.owner(), owner)
        XCTAssertThrowsError(try oldContext.perform {})
        let restored = try XCTUnwrap(try f.record())
        XCTAssertEqual(restored.generation, running.generation)
        XCTAssertEqual(restored.durationMilliseconds, 45 * 60_000)
        XCTAssertEqual(restored.remaining, running.remaining - .seconds(60) - .nanoseconds(123))
        XCTAssertTrue(f.references.allSatisfy { $0.generation == running.generation.rawValue })
        XCTAssertNil(f.manager.currentSnapshot, "An expanded tool needs a fresh Host choice after suspension.")
        let newActivity = try XCTUnwrap(f.manager.toolSnapshots.first)
        XCTAssertNotEqual(newActivity.instanceToken, oldActivity.instanceToken)
        XCTAssertTrue(f.manager.selectTool(newActivity))
        XCTAssertEqual(f.manager.currentSnapshot?.instanceToken, newActivity.instanceToken)
        f.assertNoFailures()
    }

    func testDisableEnableRotatesOwnerAndReturnsIdleWithoutAutomaticallyStarting() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        try f.act("start")
        try await f.waitForState("专注中")
        let oldOwner = try f.owner()
        let oldContext = try f.context()
        let oldActivity = try XCTUnwrap(f.manager.currentSnapshot)
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: false)
        XCTAssertTrue(f.manager.toolSnapshots.isEmpty)
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertThrowsError(try f.broker.get(owner: oldOwner, id: "session"))
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: true)
        try await f.waitForState("准备专注")
        XCTAssertEqual(f.runtimes.count, 2)
        XCTAssertNotEqual(try f.owner(), oldOwner)
        XCTAssertNil(try f.record())
        XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
        XCTAssertTrue(f.references.isEmpty)
        XCTAssertFalse(f.manager.selectTool(oldActivity))
        f.manager.setPresentationContext(.compact)
        XCTAssertNil(f.manager.currentSnapshot)
        XCTAssertEqual(f.broker.diagnostics.runningCount, 0)
        f.assertNoFailures()
    }
}

@MainActor
private final class PomodoroPluginFixture {
    let id = "com.dynamicisland.pomodoro"
    let package: ValidatedPluginPackage
    let clock = PomodoroPluginManualClock()
    let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 39_000))
    lazy var manager = ActivityManager(clock: activityClock, configuration: .immediate)
    lazy var router = ActionRouter(manager: manager)
    lazy var broker = PluginCountdownBroker(clock: { [clock] in clock.now }, automaticScheduling: false)
    lazy var bridge = PluginJSBridge(activityRateClock: { [clock] in
        clock.publicationCount += 1
        return TimeInterval(clock.publicationCount)
    })
    var runtimes: [PluginRuntime] = []
    private var contexts: [PluginExecutionContext] = []
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router,
        countdownBroker: broker, runtimeFactory: { [unowned self] package in
            let runtime = PluginRuntime(package: package, bridge: bridge)
            runtimes.append(runtime)
            return PomodoroPluginCapturingRuntime(runtime: runtime) { [weak self] in self?.contexts.append($0) }
        })

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/pomodoro", isDirectory: true)
        package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [],
                           allowedContainerURL: root.deletingLastPathComponent()))
    }

    var completionID: String { PluginJSBridge.activityID(pluginID: id, localID: "completion") }
    var tool: IslandActivity? { manager.activity(id: PluginJSBridge.activityID(pluginID: id, localID: "session")) }
    var references: [IslandNode.Countdown] {
        guard let presentation = tool?.presentation else { return [] }
        return [presentation.minimal, presentation.compact, presentation.expanded].compactMap { $0 }
            .flatMap { $0.countdownReferences }
    }

    func load() async throws {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        try await waitForState("准备专注")
    }

    func context() throws -> PluginExecutionContext { try XCTUnwrap(contexts.last) }
    func owner() throws -> PluginCountdownOwner { try XCTUnwrap(context().countdownOwner) }
    func record() throws -> PluginCountdownSnapshot? { try broker.get(owner: owner(), id: "session") }

    func act(_ actionID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try XCTUnwrap(manager.toolSnapshots.first { $0.activity.source.identifier == id }, file: file, line: line)
        XCTAssertTrue(manager.selectTool(snapshot), file: file, line: line)
        XCTAssertEqual(router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)),
                       .handled, file: file, line: line)
    }

    func waitForState(_ state: String, minutes: Int = 25,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil(file: file, line: line) {
            self.tool?.presentation.subtitle == "\(minutes) 分钟 · \(state)"
        }
    }

    func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Official Pomodoro public state did not settle.", file: file, line: line)
                throw PomodoroPluginTestError.unsettled
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Only a primitive worker barrier; no plugin implementation variable or
    /// private function is inspected or modified by these integration tests.
    func flushWorker() async throws {
        try await Task.sleep(for: .milliseconds(20))
        _ = try await XCTUnwrap(runtimes.last).evaluateForTesting("void 0")
    }

    func assertNoFailures(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(lifecycle.snapshot(id: id)?.lastFailure, file: file, line: line)
        XCTAssertTrue(bridge.diagnostics.records(for: id).allSatisfy { $0.level != .warning && $0.level != .error },
                      file: file, line: line)
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class PomodoroPluginManualClock {
    var now: Duration = .zero
    var publicationCount = 0
}

@MainActor
private final class PomodoroPluginCompletionCapture { var snapshots: [ActivitySnapshot] = [] }

@MainActor
private final class PomodoroPluginCapturingRuntime: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let capture: (PluginExecutionContext) -> Void
    init(runtime: PluginRuntime, capture: @escaping (PluginExecutionContext) -> Void) {
        self.runtime = runtime
        self.capture = capture
    }
    func onStart(context: PluginExecutionContext) throws { capture(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private enum PomodoroPluginTestError: Error { case unsettled }
