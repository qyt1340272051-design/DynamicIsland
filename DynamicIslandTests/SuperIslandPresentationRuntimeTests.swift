import Foundation
import XCTest
@testable import DynamicIsland

/// These tests exercise the actual isolated VM, private Promise transport,
/// Activity admission and ActionRouter. No compatibility callback is invoked
/// directly by the test Host.
@MainActor
final class SuperIslandPresentationRuntimeTests: XCTestCase {
    func testInitialActivationWaitsForSuccessfulRenderAndReturnsUndefined() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.activationWasUndefined = false;
            globalThis.compactCalls = 0;
            SuperIsland.registerModule({
                onActivate:function(){ activationWasUndefined = SuperIsland.island.activate() === undefined; },
                compact:function(){ compactCalls += 1; return View.text('First frame'); }
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 && fixture.manager.currentSnapshot != nil }
        let rendered = try XCTUnwrap(fixture.snapshot)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, rendered.instanceToken)
        XCTAssertEqual(rendered.activity.presentation.compact, .text(.init("First frame")))
        XCTAssertNil(fixture.manager.selectedToolSnapshot, "A module request is not a Host user selection.")
        XCTAssertEqual(fixture.decisions.map(\.code), ["presentationAccepted"])
        let exactAPI = try await runtime.evaluateForTesting("""
            activationWasUndefined && compactCalls === 1 && SuperIsland.island.supported === true &&
            Object.isFrozen(SuperIsland.island) && typeof SuperIsland.island.presentationHandle === 'undefined' &&
            typeof island.presentation === 'undefined' && typeof globalThis.__superIslandPresentation === 'undefined'
            """)
        XCTAssertEqual(exactAPI, .boolean(true))
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testPreStartAndLifecycleCallsKeepOnlyLastIntentOfOneFrame() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.entryReturn = SuperIsland.island.activate(false);
            globalThis.compactCalls = 0;
            SuperIsland.registerModule({
                onActivate:function(){
                    for(let i=0;i<1000;i++) SuperIsland.island.activate(i % 2 === 0);
                    SuperIsland.island.dismiss();
                },
                compact:function(){compactCalls+=1;return View.text('Last intent only');}
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 }
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertNotNil(fixture.snapshot, "Dismiss withdraws presentation; it does not end module data.")
        XCTAssertEqual(fixture.decisions.map(\.code), ["presentationAccepted"])
        let bounded = try await runtime.evaluateForTesting("entryReturn === undefined && compactCalls === 1")
        XCTAssertEqual(bounded, .boolean(true))
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testPreStartActivationIsBoundToFirstRenderAndFalseIsDegraded() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.entryWasUndefined=SuperIsland.island.activate(false)===undefined;
            SuperIsland.registerModule({compact:function(){return View.text('Prepared before start');}});
            """))
        try await waitUntil { fixture.decisions.count == 1 }
        XCTAssertEqual(fixture.decisions.map(\.code), ["presentationDegraded"])
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, fixture.snapshot?.instanceToken)
        let returned = try await runtime.evaluateForTesting("entryWasUndefined")
        XCTAssertEqual(returned, .boolean(true))
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testExternalControlBurstCoalescesPendingFramesAndKeepsFinalDismiss() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.sequence=0;
            SuperIsland.registerModule({compact:function(){return View.text('Sequence '+sequence);}});
            """))
        try await waitUntil { fixture.snapshot != nil && runtime.snapshot.state == .running }
        let returned = try await runtime.evaluateForTesting("""
            (()=>{
                for(let i=1;i<=100;i++){
                    sequence=i;
                    if(i===100)SuperIsland.island.dismiss();else SuperIsland.island.activate();
                }
                return sequence===100;
            })()
            """)
        XCTAssertEqual(returned, .boolean(true))
        try await waitUntil {
            fixture.snapshot?.activity.presentation.compact == .text(.init("Sequence 100")) &&
                !fixture.decisions.isEmpty && fixture.manager.currentSnapshot == nil
        }
        XCTAssertLessThanOrEqual(fixture.decisions.count, 2,
            "A control burst must retain at most one current and one replacement presentation intent.")
        XCTAssertEqual(fixture.decisions.last?.code, "presentationAccepted")
        XCTAssertNil(fixture.manager.selectedToolSnapshot)
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testParametersAreStrictAndDoNotCoerceObjectsOrInvokeGetters() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.getterCalls=0;
            globalThis.rejected=0;
            globalThis.validUndefined=false;
            const object=Object.defineProperty({},'valueOf',{get:function(){getterCalls+=1;throw 'coercion';}});
            Object.defineProperty(object,Symbol.toPrimitive,{get:function(){getterCalls+=1;throw 'coercion';}});
            Object.defineProperty(object,'toJSON',{get:function(){getterCalls+=1;throw 'coercion';}});
            const attempts=[
                function(){SuperIsland.island.activate(object);},
                function(){SuperIsland.island.activate(null);},
                function(){SuperIsland.island.activate(1);},
                function(){SuperIsland.island.activate('true');},
                function(){SuperIsland.island.activate(true,false);},
                function(){SuperIsland.island.dismiss(undefined);},
                function(){SuperIsland.island.dismiss(object);}
            ];
            for(let i=0;i<attempts.length;i++){
                try{attempts[i]();}catch(error){if(error.code==='invalidArguments')rejected+=1;}
            }
            SuperIsland.registerModule({
                onActivate:function(){
                    validUndefined=SuperIsland.island.activate(undefined)===undefined &&
                        SuperIsland.island.activate(false)===undefined && SuperIsland.island.dismiss()===undefined;
                },
                compact:function(){return View.text('Strict arguments');}
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 }
        let strict = try await runtime.evaluateForTesting("getterCalls===0 && rejected===7 && validUndefined")
        XCTAssertEqual(strict, .boolean(true))
        XCTAssertNil(fixture.manager.currentSnapshot)
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testRejectedReplacementDropsItsIntentAndPreservesOldActionUntilRecovery() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.count=0;
            SuperIsland.registerModule({
                onActivate:function(){SuperIsland.island.activate();},
                compact:function(){
                    return View.button(View.text('Count '+count),count===1?'replacement':'increment');
                },
                expanded:function(){return View.progress(count===1?2:count/4);},
                onAction:function(){count+=1;if(count===1)SuperIsland.island.activate(false);}
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 && fixture.manager.currentSnapshot != nil }
        let original = try XCTUnwrap(fixture.snapshot)
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil { fixture.failures.contains { $0.category == .compatibilityFailure } }
        XCTAssertEqual(fixture.decisions.count, 1, "A failed replacement must never submit its presentation intent.")
        XCTAssertEqual(fixture.snapshot?.activity, original.activity)
        XCTAssertEqual(fixture.dispatch(original, actionID: "replacement"), .undeclaredAction)
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.snapshot?.activity.presentation.compact == .button(.init(actionID: "increment", label: .text(.init("Count 2"))))
        }
        // A new explicit, intent-free frame has now been accepted. This also
        // proves the failed frame did not leak its request into recovery.
        let recovered = try await runtime.evaluateForTesting("count===2")
        XCTAssertEqual(recovered, .boolean(true))
        XCTAssertEqual(fixture.decisions.count, 1)
        XCTAssertEqual(fixture.snapshot?.instanceToken, original.instanceToken)
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testInvalidPreparedFrameDropsIntentBeforeAnyHostPresentation() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.bad=false;globalThis.getterCalls=0;
            SuperIsland.registerModule({
                compact:function(){
                    if(bad)return Object.defineProperty({type:'text'},'value',{
                        enumerable:true,get:function(){getterCalls+=1;return 'invalid';}
                    });
                    return View.button(View.text('Safe'),'increment');
                },
                onAction:function(){bad=true;SuperIsland.island.activate();}
            });
            """))
        try await waitUntil { fixture.snapshot != nil && runtime.snapshot.state == .running }
        let original = try XCTUnwrap(fixture.snapshot)
        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil { fixture.failures.contains { $0.category == .compatibilityFailure } }
        XCTAssertTrue(fixture.decisions.isEmpty)
        let safe = try await runtime.evaluateForTesting("getterCalls===0 && bad")
        XCTAssertEqual(safe, .boolean(true))
        XCTAssertEqual(fixture.snapshot?.activity.presentation, original.activity.presentation)
    }

    func testPrivatePresentationPromisesSurvivePollutedBuiltinsAndActionDismissesOwnLease() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.count=0;globalThis.poisoned=0;
            Object.defineProperty(Object.prototype,'then',{
                configurable:true,get:function(){poisoned+=1;throw 'inherited then';}
            });
            Promise.prototype.then=function(){poisoned+=1;throw 'promise then';};
            Object.getOwnPropertyDescriptor=function(){poisoned+=1;throw 'descriptor';};
            Reflect.apply=function(){poisoned+=1;throw 'apply';};
            SuperIsland.registerModule({
                onActivate:function(){SuperIsland.island.activate(false);},
                compact:function(){return View.button(View.text('Count '+count),'increment');},
                onAction:function(){count+=1;SuperIsland.island.dismiss();}
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 && fixture.manager.currentSnapshot != nil }
        let original = try XCTUnwrap(fixture.snapshot)
        XCTAssertEqual(fixture.decisions.map(\.code), ["presentationDegraded"])
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil { fixture.decisions.count == 2 && fixture.manager.currentSnapshot == nil }
        XCTAssertEqual(fixture.decisions.map(\.code), ["presentationDegraded", "presentationAccepted"])
        XCTAssertEqual(fixture.snapshot?.activity.presentation.compact,
                       .button(.init(actionID: "increment", label: .text(.init("Count 1")))))
        let protected = try await runtime.evaluateForTesting("count===1 && poisoned===0")
        XCTAssertEqual(protected, .boolean(true))
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testMissingCapabilityIsRecordedAsPolicyRejectionWithoutSeriousFailure() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            SuperIsland.registerModule({
                onActivate:function(){SuperIsland.island.activate();},
                compact:function(){return View.text('No capability');}
            });
            """, capabilities: capabilities.filter { $0 != .requestPresentation }))
        try await waitUntil { fixture.decisions.count == 1 }
        for expectedCount in 2...5 {
            let returned = try await runtime.evaluateForTesting("SuperIsland.island.activate(false)===undefined")
            XCTAssertEqual(returned, .boolean(true))
            try await waitUntil { fixture.decisions.count == expectedCount }
        }
        XCTAssertEqual(fixture.decisions.map(\.code), Array(repeating: "presentationRejected", count: 5))
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertNotNil(fixture.snapshot)
        assertNoSeriousFailure(fixture, runtime: runtime)
    }

    func testCompactAndUnavailableHostRejectWithoutChangingSurfaceOrFailureCount() async throws {
        for context in [ActivityManager.PresentationContext.compact, .expanded] {
            let fixture = SuperIslandPresentationFixture(context: context, allowsRequests: false)
            defer { fixture.shutdown() }
            let runtime = fixture.load(try package(source: """
                SuperIsland.registerModule({
                    onActivate:function(){SuperIsland.island.activate(false);},
                    compact:function(){return View.text('Host unavailable');}
                });
                """))
            try await waitUntil { fixture.decisions.count == 1 }
            XCTAssertEqual(fixture.decisions.map(\.code), ["presentationRejected"])
            XCTAssertNil(fixture.manager.currentSnapshot)
            XCTAssertNil(fixture.manager.selectedToolSnapshot)
            XCTAssertNotNil(fixture.snapshot)
            assertNoSeriousFailure(fixture, runtime: runtime)
        }
    }

    func testExternalControlsRenderRateLimitDoesNotAdvanceCrashWatchdog() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.attempt=0;
            SuperIsland.registerModule({compact:function(){return View.text('Attempt '+attempt);}});
            """))
        try await waitUntil { fixture.snapshot != nil && runtime.snapshot.state == .running }
        let original = try XCTUnwrap(fixture.snapshot)
        // The fixture's admission clock is fixed. One initial render and 19
        // updates consume the actual Host bucket; no test limit is substituted.
        for index in 1...19 {
            let returned = try await runtime.evaluateForTesting("attempt+=1;SuperIsland.island.activate()===undefined")
            XCTAssertEqual(returned, .boolean(true))
            try await waitUntil { fixture.decisions.count == index }
        }
        XCTAssertEqual(fixture.snapshot?.activity.presentation.compact, .text(.init("Attempt 19")))
        for rejectedCount in 1...5 {
            let returned = try await runtime.evaluateForTesting("attempt+=1;SuperIsland.island.activate(false)===undefined")
            XCTAssertEqual(returned, .boolean(true))
            try await waitUntil {
                fixture.service.diagnostics.records(for: fixture.id).filter {
                    $0.category == .compatibilityFailure && $0.level == .warning
                }.count == rejectedCount
            }
        }
        XCTAssertEqual(fixture.decisions.count, 19, "Rate-limited frames must never submit their presentation intent.")
        XCTAssertEqual(fixture.snapshot?.activity.presentation.compact, .text(.init("Attempt 19")))
        XCTAssertEqual(fixture.snapshot?.instanceToken, original.instanceToken)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 0)
        XCTAssertNil(fixture.lifecycle.snapshot(id: fixture.id)?.quarantine)
        XCTAssertFalse(fixture.failures.contains { $0.level == .error })
        let attempts = try await runtime.evaluateForTesting("attempt")
        XCTAssertEqual(attempts, .number(24))
    }

    func testStopAllowsHarmlessCleanupDismissButRejectsNewActivation() async throws {
        let fixture = SuperIslandPresentationFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            SuperIsland.registerModule({
                onActivate:function(){SuperIsland.island.activate();},
                compact:function(){return View.text('Active');},
                onDeactivate:function(){
                    if(SuperIsland.island.dismiss()!==undefined)throw 'cleanup did not return undefined';
                    try{SuperIsland.island.activate();throw 'accepted after stop';}
                    catch(error){if(error.code!=='inactiveExecution')throw 'wrong stop result';}
                }
            });
            """))
        try await waitUntil { fixture.decisions.count == 1 && fixture.manager.currentSnapshot != nil }
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.id, isEnabled: false)
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertNil(runtime.snapshot.lastFailure)
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertNil(fixture.snapshot)
        XCTAssertEqual(fixture.decisions.count, 1)
    }

    private var capabilities: [PluginCapability] {
        [.publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions, .requestPresentation]
    }

    private func package(source: String, capabilities: [PluginCapability]? = nil) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: "com.example.compatible-presentation", name: "Presentation Test",
            version: SemanticVersion("1.0.0"), engine: .superIsland, entry: "index.js",
            minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities ?? self.capabilities)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/superisland-presentation-tests"),
            entryRelativePath: "index.js", entrySource: Data(source.utf8), regularFileCount: 2,
            totalFileBytes: UInt64(source.utf8.count))
    }

    private func assertNoSeriousFailure(_ fixture: SuperIslandPresentationFixture, runtime: PluginRuntime,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(runtime.snapshot.state, .running, file: file, line: line)
        XCTAssertNil(runtime.snapshot.lastFailure, file: file, line: line)
        XCTAssertTrue(fixture.failures.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 0, file: file, line: line)
        XCTAssertNil(fixture.lifecycle.snapshot(id: fixture.id)?.quarantine, file: file, line: line)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Presentation Runtime did not reach the expected state.", file: file, line: line)
                throw SuperIslandPresentationTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SuperIslandPresentationFixture {
    let id = "com.example.compatible-presentation"
    let service = PluginJSBridge(activityRateClock: { 1_000 })
    let watchdog = PluginCrashWatchdog()
    let manager: ActivityManager
    let router: ActionRouter
    let lifecycle: PluginLifecycleBridge
    private let factory: SuperIslandPresentationRuntimeFactory

    init(context: ActivityManager.PresentationContext = .expanded, allowsRequests: Bool = true) {
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 105_000)),
                                      configuration: .immediate)
        self.manager = manager
        manager.setPresentationContext(context)
        manager.setPresentationRequestsAllowed(allowsRequests)
        let router = ActionRouter(manager: manager)
        self.router = router
        let factory = SuperIslandPresentationRuntimeFactory(service: service)
        self.factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router,
            watchdog: watchdog, diagnostics: service.diagnostics, runtimeFactory: { package in
                let runtime = PluginRuntime(package: package, bridge: factory.service)
                factory.runtimes.append(runtime)
                return runtime
            })
    }

    var snapshot: ActivitySnapshot? { manager.toolSnapshots.first { $0.activity.source.identifier == id } }
    var decisions: [PluginDiagnosticEntry] { service.diagnostics.records(for: id).filter { $0.category == .presentationDecision } }
    var failures: [PluginDiagnosticEntry] {
        service.diagnostics.records(for: id).filter {
            [.runtimeFailure, .actionFailure, .compatibilityFailure, .watchdogIsolation].contains($0.category)
        }
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes[factory.runtimes.count - 1]
    }

    func dispatch(_ snapshot: ActivitySnapshot, actionID: String = "increment") -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
                        action: .init(actionID: actionID, value: .none))
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class SuperIslandPresentationRuntimeFactory {
    let service: PluginJSBridge
    var runtimes: [PluginRuntime] = []
    init(service: PluginJSBridge) { self.service = service }
}

private enum SuperIslandPresentationTestError: Error { case timedOut }
