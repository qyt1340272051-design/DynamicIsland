import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCountdownExampleTests: XCTestCase {
    func testPublicCountdownExampleRunsThroughProductionRuntimeAndHostDisplay() async throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/countdown-demo", isDirectory: true)
        let package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [],
                           allowedContainerURL: root.deletingLastPathComponent()))
        XCTAssertTrue(package.manifest.permissions.isEmpty)
        XCTAssertEqual(Set(package.manifest.capabilities),
                       Set([.publishActivity, .updateActivity, .islandNodeUI, .handleActions, .countdown]))
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await settled { runtime.manager.toolSnapshots.count == 1 }
        let initial = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        XCTAssertEqual(initial.activity.id, PluginJSBridge.activityID(pluginID: package.manifest.id, localID: "clock"))
        XCTAssertEqual(initial.activity.lifecycle.policy, .persistent)
        XCTAssertTrue(initial.activity.isTool)
        XCTAssertEqual(Set(initial.activity.actions.map(\.id)), Set(["start", "pause", "resume", "stop"]))
        XCTAssertTrue(references(in: initial).isEmpty)

        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(initial))
        try dispatch("start", in: runtime)
        try await settled { self.references(in: runtime.manager.currentSnapshot).count == 4 }
        let running = try XCTUnwrap(runtime.manager.currentSnapshot)
        let runningReference = try XCTUnwrap(references(in: running).first)
        XCTAssertEqual(runningReference.id, "clock")
        XCTAssertEqual(Set(references(in: running).map(\.style)), Set([.time, .progress]))
        let runningValue = try XCTUnwrap(runtime.resolveCountdown(runningReference, for: running))
        assertTime(runningValue.text)
        XCTAssertTrue(runningValue.requiresTick)
        XCTAssertTrue((0...1).contains(runningValue.progress))
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.recordCount, 1)

        model.endHovering()
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.runningCount, 1)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.recordCount, 1)
        let compact = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(compact.activity.id, running.activity.id)
        XCTAssertTrue(try XCTUnwrap(runtime.resolveCountdown(runningReference, for: compact)).requiresTick)
        model.setHovering(true)
        let menuSnapshot = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        XCTAssertTrue(runtime.selectTool(menuSnapshot))
        let selectedAgain = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(references(in: selectedAgain).first?.generation, runningReference.generation)
        XCTAssertTrue(try XCTUnwrap(runtime.resolveCountdown(runningReference, for: selectedAgain)).requiresTick)

        try dispatch("pause", in: runtime)
        try await settled {
            guard let snapshot = runtime.manager.currentSnapshot,
                  let reference = self.references(in: snapshot).first,
                  reference.generation != runningReference.generation else { return false }
            return runtime.resolveCountdown(reference, for: snapshot)?.requiresTick == false
        }
        let paused = try XCTUnwrap(runtime.manager.currentSnapshot)
        let pausedReference = try XCTUnwrap(references(in: paused).first)
        let pausedValue = try XCTUnwrap(runtime.resolveCountdown(pausedReference, for: paused))
        assertTime(pausedValue.text)
        XCTAssertFalse(pausedValue.requiresTick)
        XCTAssertEqual(runtime.resolveCountdown(pausedReference, for: paused), pausedValue)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.pausedCount, 1)
        XCTAssertNil(runtime.resolveCountdown(runningReference, for: paused))

        try dispatch("resume", in: runtime)
        try await settled {
            guard let snapshot = runtime.manager.currentSnapshot,
                  let reference = self.references(in: snapshot).first,
                  reference.generation != pausedReference.generation else { return false }
            return runtime.resolveCountdown(reference, for: snapshot)?.requiresTick == true
        }
        let resumed = try XCTUnwrap(runtime.manager.currentSnapshot)
        let resumedReference = try XCTUnwrap(references(in: resumed).first)
        XCTAssertNotEqual(resumedReference.generation, pausedReference.generation)
        XCTAssertTrue(try XCTUnwrap(runtime.resolveCountdown(resumedReference, for: resumed)).requiresTick)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.runningCount, 1)

        try dispatch("stop", in: runtime)
        try await settled {
            runtime.manager.currentSnapshot != nil && self.references(in: runtime.manager.currentSnapshot).isEmpty
                && runtime.pluginLifecycle.countdownBroker.diagnostics.recordCount == 0
        }
        XCTAssertTrue(runtime.manager.current?.isTool == true)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.runningCount, 0)
        XCTAssertNil(runtime.pluginLifecycle.countdownBroker.diagnostics.nextDeadline)
        XCTAssertNil(runtime.resolveCountdown(resumedReference, for: try XCTUnwrap(runtime.manager.currentSnapshot)))
        XCTAssertTrue(runtime.pluginDiagnostics.records(for: package.manifest.id).allSatisfy {
            $0.level != .error && $0.level != .warning
        })
    }

    func testPublicExampleReceivesNaturalHostCompletionWithoutRestarting() async throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/countdown-demo", isDirectory: true)
        let package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [],
                           allowedContainerURL: root.deletingLastPathComponent()))
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await settled { runtime.manager.toolSnapshots.count == 1 }
        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(try XCTUnwrap(runtime.manager.toolSnapshots.first)))
        try dispatch("start", in: runtime)
        try await settled { self.references(in: runtime.manager.currentSnapshot).count == 4 }
        let generation = try XCTUnwrap(references(in: runtime.manager.currentSnapshot).first).generation
        try await settled(timeout: .seconds(13)) {
            runtime.manager.currentSnapshot?.activity.presentation.subtitle == "已完成"
        }
        let snapshot = try XCTUnwrap(runtime.manager.currentSnapshot)
        let reference = try XCTUnwrap(references(in: snapshot).first)
        XCTAssertEqual(reference.generation, generation)
        let value = try XCTUnwrap(runtime.resolveCountdown(reference, for: snapshot))
        XCTAssertEqual(value.text, "00:00")
        XCTAssertEqual(value.progress, 1)
        XCTAssertFalse(value.requiresTick)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.runningCount, 0)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.completedCount, 1)
        XCTAssertEqual(runtime.pluginLifecycle.countdownBroker.diagnostics.alarmCount, 0)
        XCTAssertTrue(runtime.pluginDiagnostics.records(for: package.manifest.id).allSatisfy {
            $0.level != .error && $0.level != .warning
        })
    }

    func testCompletionQueuedDuringResumeCannotBeOverwrittenByItsRunningResponse() async throws {
        let clock = CountdownExampleManualClock()
        let manager = ActivityManager(configuration: .immediate)
        let router = ActionRouter(manager: manager)
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        var vm: PluginRuntime!
        let lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router,
                                               countdownBroker: broker, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package)
            vm = runtime
            return runtime
        })
        defer { lifecycle.shutdown() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/countdown-demo", isDirectory: true)
        let package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [],
                           allowedContainerURL: root.deletingLastPathComponent()))
        lifecycle.pluginDidLoad(package, isEnabled: true)
        try await settled { manager.toolSnapshots.count == 1 }
        XCTAssertTrue(manager.selectTool(try XCTUnwrap(manager.toolSnapshots.first)))
        func act(_ id: String) throws {
            let current = try XCTUnwrap(manager.currentSnapshot)
            XCTAssertEqual(router.dispatch(id: current.activity.id, source: current.activity.source,
                instanceToken: current.instanceToken, action: .init(actionID: id, value: .none)), .handled)
        }
        try act("start")
        try await settled { manager.current?.presentation.subtitle == "进行中" }
        clock.now = .seconds(10) - .nanoseconds(1)
        try act("pause")
        try await settled { manager.current?.presentation.subtitle == "已暂停" }
        // Hold only this test's running-state render. The Host can now complete
        // while the public resume command's Promise is still in flight.
        _ = try await vm.evaluateForTesting("""
            globalThis.releaseResume = null;
            const originalRemember = remember;
            remember = function(value) {
                if (value && value.state === 'running') {
                    return new Promise(resolve => {
                        globalThis.releaseResume = () => originalRemember(value).then(resolve);
                    });
                }
                return originalRemember(value);
            };
            void 0;
            """)
        try act("resume")
        try await waitForJS(vm, "typeof releaseResume === 'function'")
        _ = try await vm.evaluateForTesting("void (globalThis.workBeforeCompletion = work);")
        clock.now = .seconds(10)
        broker.processDue()
        try await waitForJS(vm, "work !== workBeforeCompletion")
        _ = try await vm.evaluateForTesting("void releaseResume();")
        try await settled { manager.current?.presentation.subtitle == "已完成" }
        XCTAssertEqual(broker.diagnostics.completedCount, 1)
        XCTAssertEqual(broker.diagnostics.runningCount, 0)
    }

    private func waitForJS(_ vm: PluginRuntime, _ expression: String) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < limit {
            if try await vm.evaluateForTesting(expression) == .boolean(true) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Countdown example JavaScript did not settle")
        throw CountdownExampleError.unsettled
    }

    private func references(in snapshot: ActivitySnapshot?) -> [IslandNode.Countdown] {
        guard let presentation = snapshot?.activity.presentation else { return [] }
        return [presentation.minimal, presentation.compact, presentation.expanded]
            .compactMap { $0 }.flatMap { PluginIslandNodeConverter.countdownNodes(in: $0) }
    }

    private func dispatch(_ actionID: String, in runtime: IslandActivityRuntime) throws {
        let snapshot = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(runtime.router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)), .handled)
    }

    private func assertTime(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression), file: file, line: line)
    }

    private func settled(timeout: Duration = .seconds(3), _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if condition() { return }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Public countdown example did not settle.")
        throw CountdownExampleError.unsettled
    }
}

private enum CountdownExampleError: Error { case unsettled }

@MainActor
private final class CountdownExampleManualClock { var now: Duration = .zero }
