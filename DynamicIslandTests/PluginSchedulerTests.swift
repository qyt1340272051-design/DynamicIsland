import AppKit
import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginSchedulerTests: XCTestCase {
    private let alpha = "com.example.scheduler.alpha"

    func testRequestParserBoundsIntegerDelayAndRejectsUnexpectedShape() throws {
        XCTAssertEqual(try PluginRefreshRequest(delayMilliseconds: 1_000).delayMilliseconds, 1_000)
        XCTAssertEqual(try PluginRefreshRequest(delayMilliseconds: 86_400_000).delayMilliseconds, 86_400_000)
        XCTAssertEqual(try PluginRefreshRequest.parse(.object(["delayMs": .number(5_000)])).delayMilliseconds, 5_000)
        for delay in [-1, 0, 999, 86_400_001, Int.max] {
            assertSchedulerThrow(.invalidArguments) { try PluginRefreshRequest(delayMilliseconds: delay) }
        }
        let malformed: [PluginBridgeJSON] = [
            .null, .array([]), .object([:]), .object(["delayMs": .null]),
            .object(["delayMs": .string("1000")]), .object(["delayMs": .boolean(true)]),
            .object(["delayMs": .number(1_000.5)]), .object(["delayMs": .number(999)]),
            .object(["delayMs": .number(86_400_001)]),
            .object(["delayMs": .number(1_000), "repeat": .boolean(true)])
        ]
        for value in malformed { assertSchedulerThrow(.invalidArguments) { try PluginRefreshRequest.parse(value) } }
    }

    func testPolicyMinimumsAndRoundUpCoalescingNeverRefreshEarly() throws {
        let clock = SchedulerTestClock(100.2)
        let cases: [(PluginSchedulerPolicy, TimeInterval)] = [(.active, 102), (.background, 135), (.lowPower, 165)]
        for (policy, expected) in cases {
            let scheduler = PluginScheduler(policy: policy, clock: { clock.now }, automaticScheduling: false)
            let result = try begin(scheduler, delay: 1_000)
            XCTAssertEqual(scheduler.snapshot.nextDeadline, expected)
            clock.now = expected - 0.001
            scheduler.processDue()
            XCTAssertEqual(result.count, 0)
            clock.now = expected
            scheduler.processDue()
            XCTAssertEqual(try result.value().policy, policy)
            XCTAssertEqual(result.count, 1)
            scheduler.processDue()
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
            clock.now = 100.2
        }
    }

    func testRequestsInOneBucketShareOneDeadlineAndOneWake() throws {
        let clock = SchedulerTestClock(100.1)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let first = try begin(scheduler, delay: 1_000)
        clock.now = 100.4
        let second = try begin(scheduler, id: "com.example.scheduler.beta", delay: 1_000)
        XCTAssertEqual(scheduler.snapshot.pendingCount, 2)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 102)
        let wakes = scheduler.snapshot.wakeCount
        clock.now = 102
        scheduler.processDue()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(scheduler.snapshot.wakeCount, wakes + 1)
        XCTAssertNil(scheduler.snapshot.nextDeadline)
    }

    func testPerPluginAndGlobalQuotasReleaseWithoutDroppingExistingRequests() async throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let admission = PluginResourceAdmission()
        let first = try begin(scheduler, delay: 1_000, admission: admission)
        assertSchedulerThrow(.quotaExceeded) { try begin(scheduler, delay: 2_000) }
        for index in 1..<128 {
            _ = try begin(scheduler, id: "com.example.scheduler.p\(index)", delay: 1_000)
        }
        XCTAssertEqual(scheduler.snapshot.pendingCount, 128)
        assertSchedulerThrow(.quotaExceeded) { try begin(scheduler, id: "com.example.scheduler.overflow", delay: 1_000) }
        admission.revoke()
        try await waitUntil { scheduler.snapshot.pendingCount == 127 }
        XCTAssertEqual(first.failure, .inactiveExecution)
        let replacement = try begin(scheduler, id: "com.example.scheduler.overflow", delay: 1_000)
        clock.now = 101
        scheduler.processDue()
        XCTAssertEqual(try replacement.value().policy, .active)
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
    }

    func testSessionCancellationSettlesOnceAndOldDueCannotCancelReplacement() async throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let old = PluginResourceAdmission()
        let oldResult = try begin(scheduler, delay: 1_000, admission: old)
        old.revoke()
        try await waitUntil { scheduler.snapshot.pendingCount == 0 }
        XCTAssertEqual(oldResult.failure, .inactiveExecution)
        let replacement = try begin(scheduler, delay: 2_000)
        clock.now = 101
        scheduler.processDue()
        XCTAssertEqual(replacement.count, 0)
        clock.now = 102
        scheduler.processDue()
        XCTAssertEqual(try replacement.value().policy, .active)
        old.revoke()
        scheduler.processDue()
        XCTAssertEqual(oldResult.count, 1)
        XCTAssertEqual(replacement.count, 1)
    }

    func testAlreadyRevokedAdmissionRejectsWithoutRetainingRequest() throws {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let admission = PluginResourceAdmission()
        admission.revoke()
        assertSchedulerThrow(.inactiveExecution) { try begin(scheduler, delay: 1_000, admission: admission) }
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        XCTAssertNil(scheduler.snapshot.nextDeadline)
    }

    func testPolicyDowngradeExtendsPendingAndUpgradeDoesNotBurst() throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let first = try begin(scheduler, delay: 1_000)
        clock.now = 100.5
        scheduler.setPolicy(.background)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 135)
        clock.now = 101
        scheduler.setPolicy(.lowPower)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 165)
        scheduler.setPolicy(.active)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 165)
        clock.now = 164.999
        scheduler.processDue()
        XCTAssertEqual(first.count, 0)
        clock.now = 165
        scheduler.processDue()
        XCTAssertEqual(try first.value().policy, .active)
        let fresh = try begin(scheduler, delay: 1_000)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 166)
        clock.now = 166
        scheduler.processDue()
        XCTAssertEqual(fresh.count, 1)
    }

    func testRepeatedPolicyNotificationDoesNotKeepPushingDeadline() throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(policy: .background, clock: { clock.now }, automaticScheduling: false)
        let pending = try begin(scheduler, delay: 1_000)
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 130)
        for second in 101...129 {
            clock.now = Double(second)
            scheduler.setPolicy(.background)
        }
        XCTAssertEqual(scheduler.snapshot.nextDeadline, 130)
        clock.now = 130
        scheduler.processDue()
        XCTAssertEqual(pending.count, 1)
    }

    func testShutdownCancelsAllRequestsAndRejectsNewAdmission() throws {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let first = try begin(scheduler, delay: 1_000)
        let second = try begin(scheduler, id: "com.example.scheduler.beta", delay: 1_000)
        scheduler.shutdown()
        XCTAssertEqual(first.failure, .inactiveExecution)
        XCTAssertEqual(second.failure, .inactiveExecution)
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        XCTAssertNil(scheduler.snapshot.nextDeadline)
        assertSchedulerThrow(.inactiveExecution) { try begin(scheduler, delay: 1_000) }
        scheduler.shutdown()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
    }

    func testEnvironmentUsesCurrentInjectedAppAndPowerStateAndStopsObservation() {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let center = NotificationCenter()
        let state = SchedulerEnvironmentState()
        state.active = false
        let environment = PluginSchedulerEnvironment(scheduler: scheduler, notificationCenter: center,
            isActive: { state.active }, isLowPowerModeEnabled: { state.lowPower })
        defer { environment.stop() }
        XCTAssertEqual(scheduler.snapshot.policy, .background)
        state.active = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .active)
        state.lowPower = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .lowPower)
        state.active = false
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .lowPower)
        state.lowPower = false
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .background)
        environment.stop()
        state.active = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .background)
        environment.start()
        XCTAssertEqual(scheduler.snapshot.policy, .active)
        // Names announce a possible change. The current supplier state remains
        // authoritative when an old resign notification arrives after resume.
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(scheduler.snapshot.policy, .active)
    }

    func testQueuedEnvironmentNotificationCannotAffectRestartedObservation() async {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let center = NotificationCenter()
        let state = SchedulerEnvironmentState()
        var powerReads = 0
        let environment = PluginSchedulerEnvironment(scheduler: scheduler, notificationCenter: center,
            isActive: { state.active }, isLowPowerModeEnabled: { powerReads += 1; return state.lowPower })
        defer { environment.stop() }
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            delivered.signal()
        }
        // Keep MainActor occupied only until the background observer has queued
        // its callback, then invalidate that callback before yielding admission.
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        environment.stop()
        state.lowPower = true
        environment.start()
        let readsAfterRestart = powerReads
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(powerReads, readsAfterRestart)
        XCTAssertEqual(scheduler.snapshot.policy, .lowPower)
    }

    func testRealJavaScriptRefreshResolvesFrozenResponseAndPublishesActivityAtDue() async throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() {
                globalThis.started = true;
                globalThis.done = false;
                island.scheduler.requestRefresh(1000).then(async result => {
                    globalThis.valid = result.policy === 'active' && Object.isFrozen(result) &&
                        Object.getPrototypeOf(result) === null && Object.isFrozen(island.scheduler) &&
                        Object.isFrozen(island.scheduler.requestRefresh) && island.scheduler.supported === true &&
                        island.scheduler.apiVersion === '1.0.0' && island.scheduler.requestRefresh.apiVersion === '1.0.0';
                    await island.activity.publish({id:'refreshed', presentation:{title:'Scheduled refresh'}});
                    globalThis.done = true;
                }).catch(error => { globalThis.error = error.code; globalThis.done = true; });
            }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        try await waitUntil { scheduler.snapshot.pendingCount == 1 }
        XCTAssertNil(fixture.manager.current)
        try await assertJavaScript(runtime, "done", equals: .boolean(false))
        clock.now = 101
        scheduler.processDue()
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "valid", equals: .boolean(true))
        try await assertJavaScript(runtime, "typeof error", equals: .string("undefined"))
        XCTAssertEqual(fixture.manager.current?.presentation.title, "Scheduled refresh")
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testRealJavaScriptRejectsInvalidArityTypesRangesWithoutCoercionOrScheduling() async throws {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() {
                globalThis.coercions = 0;
                const object = {valueOf(){globalThis.coercions++; return 1000;}};
                Promise.all([
                    island.scheduler.requestRefresh(), island.scheduler.requestRefresh(1000, 2),
                    island.scheduler.requestRefresh('1000'), island.scheduler.requestRefresh(null),
                    island.scheduler.requestRefresh(true), island.scheduler.requestRefresh(object),
                    island.scheduler.requestRefresh(NaN), island.scheduler.requestRefresh(Infinity),
                    island.scheduler.requestRefresh(1000.5), island.scheduler.requestRefresh(999),
                    island.scheduler.requestRefresh(86400001)
                ].map(p => p.then(() => 'unexpected', error => error.code))).then(values => {
                    globalThis.valid = values.every(value => value === 'invalidArguments') && coercions === 0;
                    globalThis.done = true;
                });
            }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "valid", equals: .boolean(true))
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testPendingRefreshDoesNotBlockStorageActivityOrSecondRequestQuotaError() async throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() {
                globalThis.refreshDone = false;
                island.scheduler.requestRefresh(60000).then(() => { globalThis.refreshDone = true; });
                island.scheduler.requestRefresh(1000).catch(error => {
                    globalThis.quota = error.code; globalThis.quotaDone = true;
                });
                Promise.all([island.storage.set('ready', true), island.activity.publish({
                    id:'independent', presentation:{title:'Refresh pending'}
                })]).then(() => { globalThis.independentDone = true; });
            }
            """)
        let review = fixture.permissions.request(package: package)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let runtime = fixture.load(package)
        try await marker(runtime, "independentDone")
        try await marker(runtime, "quotaDone")
        try await assertJavaScript(runtime, "quota", equals: .string("quotaExceeded"))
        try await assertJavaScript(runtime, "refreshDone", equals: .boolean(false))
        XCTAssertEqual(scheduler.snapshot.pendingCount, 1)
        let stored = try await fixture.store.get(pluginID: alpha, key: "ready")
        XCTAssertEqual(stored, .boolean(true))
        XCTAssertEqual(fixture.manager.current?.presentation.title, "Refresh pending")
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testHostBridgeRequiresCapabilityValidatesEnvelopeAndRejectsStaleContext() async throws {
        let scheduler = PluginScheduler(automaticScheduling: false)
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let noCapability = try package(source: "function onStart(){globalThis.started = true;}", capabilities: [.publishActivity])
        let runtime = fixture.load(noCapability)
        try await marker(runtime, "started")
        let context = try XCTUnwrap(fixture.contexts[alpha])
        let missing = await fixture.bridge.handle(requestJSON(.object(["delayMs": .number(1_000)])), package: noCapability, context: context)
        XCTAssertEqual(try errorCode(missing), "capabilityRequired")
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        fixture.lifecycle.pluginWillUnload(id: alpha)
        let stale = await fixture.bridge.handle(requestJSON(.object(["delayMs": .number(1_000)])), package: noCapability, context: context)
        XCTAssertEqual(try errorCode(stale), "inactiveExecution")

        let declared = try package(id: "com.example.scheduler.beta", source: "function onStart(){globalThis.started = true;}")
        let replacement = fixture.load(declared)
        try await marker(replacement, "started")
        let active = try XCTUnwrap(fixture.contexts[declared.manifest.id])
        for fields in [PluginBridgeJSON.object([:]), .object(["delayMs": .number(1_000), "pluginID": .string(alpha)]), .object(["delayMs": .number(999)])] {
            let invalid = await fixture.bridge.handle(requestJSON(fields), package: declared, context: active)
            XCTAssertEqual(try errorCode(invalid), "invalidArguments")
        }
        let unsupported = await fixture.bridge.handle(requestJSON(.object(["delayMs": .number(1_000)]), version: "2.0.0"), package: declared, context: active)
        XCTAssertEqual(try errorCode(unsupported), "unsupportedVersion")
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
    }

    func testRealJavaScriptDisableReloadAndStopCancelPendingOldSession() async throws {
        let clock = SchedulerTestClock(100)
        let scheduler = PluginScheduler(clock: { clock.now }, automaticScheduling: false)
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart(){
                globalThis.started = true;
                island.scheduler.requestRefresh(1000).then(() => {globalThis.done = true;});
            }
            """)
        let old = fixture.load(package)
        try await marker(old, "started")
        try await waitUntil { scheduler.snapshot.pendingCount == 1 }
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: false)
        try await waitUntil { scheduler.snapshot.pendingCount == 0 }
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        let replacement = try XCTUnwrap(fixture.runtimes.last)
        XCTAssertFalse(old === replacement)
        try await marker(replacement, "started")
        try await waitUntil { scheduler.snapshot.pendingCount == 1 }
        do {
            _ = try await old.evaluateForTesting("void 0")
            XCTFail("The old VM accepted evaluation after disable.")
        } catch { XCTAssertEqual(error as? PluginRuntimeError, .inactiveExecution) }
        clock.now = 101
        scheduler.processDue()
        try await marker(replacement, "done")
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        _ = try await replacement.evaluateForTesting("globalThis.done = false; island.scheduler.requestRefresh(1000).then(() => {globalThis.done = true;}); void 0")
        try await waitUntil { scheduler.snapshot.pendingCount == 1 }
        try fixture.lifecycle.stop(id: alpha)
        try await waitUntil { scheduler.snapshot.pendingCount == 0 }
        clock.now = 1_000
        scheduler.processDue()
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .stopped)
    }

    func testRealAutomaticHostTimerDeliversOneRefreshAndThenGoesIdle() async throws {
        let scheduler = PluginScheduler()
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart(){island.scheduler.requestRefresh(1000).then(result => {
                globalThis.policy = result.policy; globalThis.done = true;
            });}
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "policy", equals: .string("active"))
        XCTAssertEqual(scheduler.snapshot.pendingCount, 0)
        XCTAssertNil(scheduler.snapshot.nextDeadline)
        XCTAssertEqual(scheduler.snapshot.timerCount, 0)
        XCTAssertEqual(scheduler.snapshot.wakeCount, 1)
    }

    /// A small process-level observation, not an Energy Impact claim. No JS
    /// polling or test evaluation runs inside either ten-second idle window.
    func testTwentyRealVMsShareIdleHostSchedulingAndRecordCPUAgainstBaseline() async throws {
        let scheduler = PluginScheduler()
        let fixture = SchedulerRuntimeFixture(scheduler: scheduler)
        defer { fixture.shutdown() }
        let baselineStart = try cpuSeconds()
        try await Task.sleep(for: .seconds(10))
        let baselineCPU = try cpuSeconds() - baselineStart
        for index in 0..<20 {
            let package = try package(id: "com.example.scheduler.idle\(index)", source: """
                function onStart(){
                    globalThis.started = true;
                    island.scheduler.requestRefresh(60000).then(() => {globalThis.refreshed = true;});
                }
                """)
            let runtime = fixture.load(package)
            try await marker(runtime, "started")
        }
        try await waitUntil { scheduler.snapshot.pendingCount == 20 }
        XCTAssertEqual(scheduler.snapshot.timerCount, 1)
        let wakeCount = scheduler.snapshot.wakeCount
        let loadedStart = try cpuSeconds()
        try await Task.sleep(for: .seconds(10))
        let loadedCPU = try cpuSeconds() - loadedStart
        XCTAssertEqual(scheduler.snapshot.pendingCount, 20)
        XCTAssertEqual(scheduler.snapshot.timerCount, 1)
        XCTAssertEqual(scheduler.snapshot.wakeCount, wakeCount, "Idle refresh requests woke the Host before any deadline.")
        XCTAssertEqual(fixture.runtimes.count, 20)
        XCTAssertTrue(fixture.runtimes.allSatisfy { $0.snapshot.state == .running && $0.snapshot.lastFailure == nil })
        let report = String(format: "T31_IDLE_CPU window_seconds=10 baseline_cpu_seconds=%.6f loaded_20_vm_cpu_seconds=%.6f baseline_cpu_percent=%.3f loaded_cpu_percent=%.3f scheduler_wakes=%llu pending=20", baselineCPU, loadedCPU, baselineCPU * 10, loadedCPU * 10, scheduler.snapshot.wakeCount - wakeCount)
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "T31 20 real VMs idle CPU observation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func begin(_ scheduler: PluginScheduler, id: String = "com.example.scheduler.alpha", delay: Int,
                       admission: PluginResourceAdmission = PluginResourceAdmission()) throws -> SchedulerResultRecorder {
        let recorder = SchedulerResultRecorder()
        try scheduler.schedule(request: PluginRefreshRequest(delayMilliseconds: delay), pluginID: id,
                               admission: admission) { recorder.record($0) }
        return recorder
    }

    private func assertSchedulerThrow<T>(_ expected: PluginSchedulerError, file: StaticString = #filePath, line: UInt = #line,
                                        _ operation: () throws -> T) {
        do { _ = try operation(); XCTFail("Expected \(expected).", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginSchedulerError, expected, file: file, line: line) }
    }

    private func package(id: String = "com.example.scheduler.alpha", source: String,
                         capabilities: [PluginCapability] = [.scheduler, .publishActivity, .localStorage]) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Scheduler Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.localStorage], capabilities: capabilities)
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/scheduler-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func requestJSON(_ params: PluginBridgeJSON, version: String = "1.0.0") -> String {
        try! PluginBridgeJSON.object(["apiVersion": .string(version), "method": .string("scheduler.requestRefresh"), "params": params]).encodedString()
    }

    private func errorCode(_ json: String) throws -> String {
        let response = try PluginBridgeJSON.parse(json)
        guard case .object(let outer) = response, case .object(let fields)? = outer["error"], case .string(let code)? = fields["code"] else {
            XCTFail("Expected a bridge error response."); throw SchedulerTestError.invalidResponse
        }
        return code
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Scheduler test timed out."); throw SchedulerTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        try await waitUntil { runtime.snapshot.state == .running || runtime.snapshot.lastFailure != nil }
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { XCTFail("JavaScript marker \(name) did not settle."); throw SchedulerTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertJavaScript(_ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await runtime.evaluateForTesting(source)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw SchedulerTestError.cpuMeasurementFailed }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

@MainActor
private final class SchedulerTestClock {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}

@MainActor
private final class SchedulerEnvironmentState {
    var active = true
    var lowPower = false
}

private nonisolated final class SchedulerResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<PluginRefreshResponse, PluginSchedulerError>] = []
    var count: Int { lock.withLock { results.count } }
    var failure: PluginSchedulerError? {
        lock.withLock { if case .failure(let error)? = results.first { return error }; return nil }
    }
    func value() throws -> PluginRefreshResponse {
        try lock.withLock { guard let result = results.first else { throw SchedulerTestError.invalidResponse }; return try result.get() }
    }
    func record(_ result: Result<PluginRefreshResponse, PluginSchedulerError>) { lock.withLock { results.append(result) } }
}

@MainActor
private final class SchedulerRuntimeFixture {
    let permissions = PermissionManager()
    let store = PluginStorage()
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    let bridge: PluginJSBridge
    private let factory = SchedulerRuntimeFactory()
    var runtimes: [PluginRuntime] { factory.runtimes }
    var contexts: [String: PluginExecutionContext] { factory.contexts }

    init(scheduler: PluginScheduler) {
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 100_000)), configuration: .immediate)
        self.manager = manager
        let service = PluginJSBridge(storage: store, permissions: permissions, scheduler: scheduler)
        bridge = service
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), permissions: permissions, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return SchedulerRuntimeForwarder(runtime: runtime, factory: factory)
        })
    }
    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class SchedulerRuntimeFactory {
    var runtimes: [PluginRuntime] = []
    var contexts: [String: PluginExecutionContext] = [:]
}

@MainActor
private final class SchedulerRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    private let factory: SchedulerRuntimeFactory
    init(runtime: PluginRuntime, factory: SchedulerRuntimeFactory) { self.runtime = runtime; self.factory = factory }
    func onStart(context: PluginExecutionContext) throws {
        factory.contexts[context.id] = context
        try runtime.onStart(context: context)
    }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated enum SchedulerTestError: Error {
    case timedOut, invalidResponse, cpuMeasurementFailed
}
