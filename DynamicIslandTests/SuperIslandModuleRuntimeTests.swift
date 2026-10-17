import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class SuperIslandModuleRuntimeTests: XCTestCase {
    func testActualModuleRendersSixViewKindsAndActionRouterUpdatesSameActivity() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.count = 0;
            globalThis.activationArguments = -1;
            globalThis.actionArguments = -1;
            SuperIsland.registerModule({
                onActivate: function() { activationArguments = arguments.length; },
                compact: function() {
                    return View.hstack([View.icon('bolt.fill'), View.text('Count ' + count)]);
                },
                expanded: function() {
                    return View.vstack([
                        View.progress(count, {total:4}),
                        View.button(View.text('Increment'), 'increment')
                    ]);
                },
                onAction: function(actionID) {
                    actionArguments = arguments.length;
                    if (actionID === 'increment') count += 1;
                }
            });
            """))
        let original = try await snapshot(fixture)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertEqual(original.activity.id, PluginJSBridge.activityID(pluginID: fixture.defaultID, localID: "superisland-module"))
        XCTAssertEqual(original.activity.presentation.title, "Compatible Module Test")
        XCTAssertEqual(original.activity.priority, .background)
        XCTAssertEqual(original.activity.lifecycle.policy, .persistent)
        XCTAssertEqual(original.activity.presentation.role, .tool)
        XCTAssertEqual(original.activity.presentation.compactPolicy, .selectedOnly)
        XCTAssertEqual(original.activity.actions, [.init(id: "increment", title: "increment")])
        XCTAssertEqual(original.activity.presentation.compact, .hStack(.init([
            .icon(.init("bolt.fill")), .text(.init("Count 0"))
        ])))
        XCTAssertEqual(original.activity.presentation.expanded, expanded(progress: 0))
        XCTAssertNil(fixture.manager.currentSnapshot, "A compatible background tool must wait for a Host selection.")

        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.snapshot()?.activity.presentation.compact == .hStack(.init([
                .icon(.init("bolt.fill")), .text(.init("Count 1"))
            ]))
        }
        let updated = try XCTUnwrap(fixture.snapshot())
        XCTAssertEqual(updated.activity.presentation.expanded, expanded(progress: 0.25))
        XCTAssertEqual(updated.instanceToken, original.instanceToken)
        XCTAssertEqual(updated.activity.createdAt, original.activity.createdAt)
        let arguments = try await runtime.evaluateForTesting("activationArguments === 0 && actionArguments === 1 && count === 1")
        XCTAssertEqual(arguments, .boolean(true))
    }

    func testMissingExpandedUsesSingleCompactSnapshotAndExposesOnlyFrozenCompatibilityAPI() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.compactCalls = 0;
            SuperIsland.registerModule({compact: function() {
                compactCalls += 1; return View.text('Snapshot ' + compactCalls);
            }});
            """))
        let value = try await snapshot(fixture)
        XCTAssertEqual(value.activity.presentation.compact, .text(.init("Snapshot 1")))
        XCTAssertEqual(value.activity.presentation.expanded, value.activity.presentation.compact)
        let safe = try await runtime.evaluateForTesting("""
            compactCalls === 1 && Object.isFrozen(SuperIsland) && Object.isFrozen(View) &&
            Object.isFrozen(island) && Object.isFrozen(SuperIsland.island) &&
            Object.getOwnPropertyDescriptor(globalThis, 'SuperIsland').writable === false &&
            Object.getOwnPropertyDescriptor(globalThis, 'View').configurable === false &&
            Object.keys(View).sort().join(',') === 'button,hstack,icon,progress,text,vstack' &&
            typeof SuperIsland.render === 'undefined' && typeof SuperIsland.View === 'undefined' &&
            typeof __superIslandStart === 'undefined' && typeof __superIslandStop === 'undefined'
            """)
        XCTAssertEqual(safe, .boolean(true))
    }

    func testNativeEngineDoesNotReceiveCompatibilityGlobals() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: "globalThis.started = false; function onStart(){ started = true; }", engine: .javaScriptCore))
        try await waitUntil { runtime.snapshot.state == .running }
        let native = try await runtime.evaluateForTesting("started && typeof SuperIsland === 'undefined' && typeof View === 'undefined' && Object.isFrozen(island)")
        XCTAssertEqual(native, .boolean(true))
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
    }

    func testPrivateLifecycleIgnoresGlobalHooksAndDeactivationHasNoArguments() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.events = ['entry'];
            globalThis.onStart = function() { throw new Error('global onStart must not run'); };
            globalThis.onStop = function() { throw new Error('global onStop must not run'); };
            SuperIsland.registerModule({
                onActivate: function() { events.push('activate:' + arguments.length); },
                onDeactivate: function() {
                    if (arguments.length !== 0) throw new Error('unexpected stop argument');
                },
                compact: function() { events.push('compact'); return View.text('Ready'); }
            });
            """))
        _ = try await snapshot(fixture)
        let events = try await runtime.evaluateForTesting("events.join(',')")
        XCTAssertEqual(events, .string("entry,activate:0,compact"))
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.defaultID, isEnabled: false)
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertNil(runtime.snapshot.lastFailure)
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
    }

    func testModuleDeactivationActuallyRunsThroughPrivateStopReceiver() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.onStop=function(){return undefined;};
            SuperIsland.registerModule({
                compact:function(){return View.text('Ready');},
                onDeactivate:function(){throw new Error('Private stop proof');}
            });
            """))
        _ = try await snapshot(fixture)
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.defaultID, isEnabled: false)
        try await waitUntil { runtime.snapshot.lastFailure?.phase == .stop }
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
    }

    func testUnknownConfigAccessorsAndDuplicateOrLateRegistrationAreRejected() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.getterCalls = 0;
            globalThis.rejections = [];
            const attempts = [
                {compact:function(){return View.text('Unknown');}, unknown:true},
                Object.defineProperty({}, 'compact', {enumerable:true,get:function(){getterCalls+=1;return function(){return View.text('Getter');};}}),
                {compact:function(){return View.text('Bad lifecycle');}, onActivate:'not a function'}
            ];
            attempts.forEach(function(config) {
                try { SuperIsland.registerModule(config); rejections.push(false); }
                catch (_) { rejections.push(true); }
            });
            SuperIsland.registerModule({compact:function(){return View.text('Valid');}});
            try { SuperIsland.registerModule({compact:function(){return View.text('Duplicate');}}); rejections.push(false); }
            catch (_) { rejections.push(true); }
            """))
        let value = try await snapshot(fixture)
        XCTAssertEqual(value.activity.presentation.compact, .text(.init("Valid")))
        let rejected = try await runtime.evaluateForTesting("getterCalls === 0 && rejections.length === 4 && rejections.every(Boolean)")
        XCTAssertEqual(rejected, .boolean(true))
        let late = try await runtime.evaluateForTesting("""
            (()=>{try {SuperIsland.registerModule({compact:function(){return View.text('Late');}});return false;}catch(_){return true;}})()
            """)
        XCTAssertEqual(late, .boolean(true))
        XCTAssertEqual(fixture.snapshot()?.activity.presentation.compact, .text(.init("Valid")))
    }

    func testGetterRenderAfterActionIsRejectedWithoutExecutingGetterOrReplacingLayout() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.badRender = false; globalThis.getterCalls = 0;
            SuperIsland.registerModule({
                compact:function(){
                    if (!badRender) return View.button(View.text('Safe'), 'increment');
                    return Object.defineProperty({type:'text'}, 'value', {
                        enumerable:true,get:function(){getterCalls+=1;return 'Unsafe';}
                    });
                },
                onAction:function(){badRender=true;}
            });
            """))
        let original = try await snapshot(fixture)
        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.service.diagnostics.records(for: fixture.defaultID).contains { $0.category == .compatibilityFailure }
        }
        let safe = try await runtime.evaluateForTesting("badRender && getterCalls === 0")
        XCTAssertEqual(safe, .boolean(true))
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertEqual(fixture.snapshot()?.activity.presentation, original.activity.presentation)
    }

    func testPromiseRenderAfterActionIsRejectedWithoutPublishingPromiseData() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.asyncRender = false;
            SuperIsland.registerModule({
                compact:function(){return asyncRender ? Promise.resolve(View.text('Async')) : View.button(View.text('Safe'), 'increment');},
                onAction:function(){asyncRender=true;}
            });
            """))
        let original = try await snapshot(fixture)
        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.service.diagnostics.records(for: fixture.defaultID).contains { $0.category == .compatibilityFailure }
        }
        XCTAssertEqual(fixture.snapshot()?.activity.presentation, original.activity.presentation)
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testRejectedReplacementLayoutRetainsPreviousButtonRegistrationAndActivity() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.calls=0;
            SuperIsland.registerModule({
                compact:function(){
                    return calls === 1 ? View.button(View.text('Rejected replacement'), 'replacement')
                        : View.button(View.text(calls === 0 ? 'Original' : 'Recovered'), 'increment');
                },
                expanded:function(){return View.progress(calls === 1 ? 2 : calls/4);},
                onAction:function(id){if(id==='increment')calls+=1;}
            });
            """))
        let original = try await snapshot(fixture)
        XCTAssertTrue(fixture.manager.selectTool(original))
        let selected = try XCTUnwrap(fixture.snapshot())
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.service.diagnostics.records(for: fixture.defaultID).filter { $0.category == .compatibilityFailure }.count >= 1
        }
        XCTAssertEqual(fixture.snapshot()?.activity, selected.activity)
        XCTAssertEqual(fixture.snapshot()?.instanceToken, original.instanceToken)
        XCTAssertEqual(fixture.dispatch(original, id: "replacement"), .undeclaredAction)
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await predicate(runtime, "calls === 2")
        try await waitUntil {
            fixture.snapshot()?.activity.presentation.compact == .button(.init(actionID: "increment", label: .text(.init("Recovered"))))
        }
        XCTAssertEqual(fixture.snapshot()?.activity.presentation.expanded, .progress(.init(0.5, color: .primary)))
        XCTAssertEqual(fixture.snapshot()?.instanceToken, original.instanceToken)
        XCTAssertEqual(fixture.snapshot()?.activity.createdAt, original.activity.createdAt)
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testAsynchronousActivationAndInitialRenderFailStartWithoutActivity() async throws {
        for config in [
            "{compact:function(){return View.text('Never');},onActivate:function(){return Promise.resolve();}}",
            "{compact:function(){return Promise.resolve(View.text('Never'));}}"
        ] {
            let fixture = SuperIslandModuleFixture()
            defer { fixture.shutdown() }
            let runtime = fixture.load(try package(source: "SuperIsland.registerModule(\(config));"))
            try await waitUntil { runtime.snapshot.lastFailure != nil }
            XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .start)
            XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
            XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
        }
    }

    func testMissingRenderCapabilitiesDoNotPublishActivity() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: "SuperIsland.registerModule({compact:function(){return View.text('Denied');}});", capabilities: []))
        try await waitUntil {
            fixture.service.diagnostics.records(for: fixture.defaultID).contains { $0.category == .compatibilityFailure }
        }
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
        XCTAssertNil(fixture.manager.currentSnapshot)
    }

    func testWindowRequestsAreUnsupportedAndCannotChangeHostToolSelection() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: "SuperIsland.registerModule({compact:function(){return View.text('Ready');}});"))
        let original = try await snapshot(fixture)
        XCTAssertNil(fixture.manager.currentSnapshot)
        let rejected = try await runtime.evaluateForTesting("""
            ['activate','dismiss'].every(function(name){
                try {SuperIsland.island[name]();return false;}
                catch(error){return error.code === 'unsupportedMethod';}
            })
            """)
        XCTAssertEqual(rejected, .boolean(true))
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertTrue(fixture.manager.selectTool(original))
        let afterSelection = try await runtime.evaluateForTesting("""
            (()=>{try{SuperIsland.island.dismiss();return false;}catch(error){return error.code === 'unsupportedMethod';}})()
            """)
        XCTAssertEqual(afterSelection, .boolean(true))
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, original.instanceToken)
    }

    func testDisableAndRestartRejectOldSnapshotAndCreateFreshVirtualMachine() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let first = fixture.load(try package(source: counterSource))
        let original = try await snapshot(fixture)
        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil { fixture.snapshot()?.activity.presentation.compact == .button(.init(actionID: "increment", label: .text(.init("Count 1")))) }
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.defaultID, isEnabled: false)
        XCTAssertEqual(fixture.dispatch(original), .inactiveActivity)
        XCTAssertNil(fixture.snapshot())
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.defaultID, isEnabled: true)
        let replacement = try await snapshot(fixture)
        let second = try XCTUnwrap(fixture.runtimes.last)
        XCTAssertFalse(first === second)
        XCTAssertNotEqual(replacement.instanceToken, original.instanceToken)
        XCTAssertEqual(replacement.activity.presentation.compact, .button(.init(actionID: "increment", label: .text(.init("Count 0")))))
        XCTAssertTrue(fixture.manager.selectTool(replacement))
        XCTAssertEqual(fixture.dispatch(original), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(replacement), .handled)
        try await waitUntil { fixture.snapshot()?.activity.presentation.compact == .button(.init(actionID: "increment", label: .text(.init("Count 1")))) }
        let count = try await second.evaluateForTesting("count")
        XCTAssertEqual(count, .number(1))
        try await waitUntil { first.snapshot.state == .tornDown }
    }

    func testTwoCompatibleModulesHaveIndependentGlobalsPrototypesAndActions() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let alpha = fixture.load(try package(source: counterSource + "\nglobalThis.alphaOnly=73;Object.prototype.alphaOnly=true;"))
        let beta = fixture.load(try package(id: "com.example.compatible-beta", source: counterSource))
        let alphaSnapshot = try await snapshot(fixture)
        let betaSnapshot = try await snapshot(fixture, id: "com.example.compatible-beta")
        XCTAssertTrue(fixture.manager.selectTool(alphaSnapshot))
        XCTAssertEqual(fixture.dispatch(alphaSnapshot), .handled)
        try await predicate(alpha, "count === 1")
        let isolated = try await beta.evaluateForTesting("count === 0 && typeof alphaOnly === 'undefined' && typeof ({}).alphaOnly === 'undefined'")
        XCTAssertEqual(isolated, .boolean(true))
        XCTAssertEqual(fixture.snapshot(id: "com.example.compatible-beta")?.activity.presentation, betaSnapshot.activity.presentation)
    }

    func testCapturedPrimordialsAndPrivatePromiseChainsSurviveEntryPrototypePollution() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.count=0;
            globalThis.pollutedThenCalls=0;
            globalThis.pollutedGetterCalls=0;
            globalThis.pollutedPrimitiveCalls=0;
            Object.defineProperty(Object.prototype,'then',{
                configurable:true,
                get:function(){pollutedGetterCalls+=1;throw new Error('Poisoned inherited then');}
            });
            Promise.prototype.then=function(){pollutedThenCalls+=1;throw new Error('Poisoned Promise then');};
            Object.getOwnPropertyDescriptor=function(){pollutedPrimitiveCalls+=1;throw new Error('Poisoned descriptor');};
            Reflect.apply=function(){pollutedPrimitiveCalls+=1;throw new Error('Poisoned apply');};
            SuperIsland.registerModule({
                compact:function(){return View.button(View.text('Count '+count),'increment');},
                onAction:function(id){if(id==='increment')count+=1;}
            });
            """))
        let original = try await snapshot(fixture)
        XCTAssertEqual(original.activity.presentation.compact, .button(.init(actionID: "increment", label: .text(.init("Count 0")))))
        XCTAssertTrue(fixture.manager.selectTool(original))
        XCTAssertEqual(fixture.dispatch(original), .handled)
        try await waitUntil {
            fixture.snapshot()?.activity.presentation.compact == .button(.init(actionID: "increment", label: .text(.init("Count 1"))))
        }
        let protected = try await runtime.evaluateForTesting("count === 1 && pollutedThenCalls === 0 && pollutedGetterCalls === 0 && pollutedPrimitiveCalls === 0")
        XCTAssertEqual(protected, .boolean(true))
        XCTAssertEqual(fixture.snapshot()?.instanceToken, original.instanceToken)
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testHostIndependentlyRejectsNativeModeAndMissingRenderCapabilities() async throws {
        let capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions]
        let cases: [(PluginEngine, [PluginCapability], String)] = [
            (.javaScriptCore, capabilities, "unsupportedMethod"),
            (.superIsland, capabilities.filter { $0 != .publishActivity }, "capabilityRequired"),
            (.superIsland, capabilities.filter { $0 != .islandNodeUI }, "capabilityRequired")
        ]
        for (engine, selectedCapabilities, expectedCode) in cases {
            let fixture = SuperIslandModuleFixture()
            defer { fixture.shutdown() }
            let package = try package(source: "", engine: engine, capabilities: selectedCapabilities)
            let context = try fixture.loadHost(package)
            let response = try await renderRequest(fixture, package: package, context: context,
                compact: ["type": "text", "value": "Compact"], expanded: ["type": "text", "value": "Expanded"])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, expectedCode)
            XCTAssertNil(fixture.manager.activity(id: PluginJSBridge.activityID(pluginID: package.manifest.id, localID: "superisland-module")))
            XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
        }
    }

    func testHostRejectsInvalidExpandedSnapshotWithoutPartiallyPublishingOrUpdating() async throws {
        let fixture = SuperIslandModuleFixture()
        defer { fixture.shutdown() }
        let package = try package(source: "")
        let context = try fixture.loadHost(package)
        let malformed: [String: Any] = ["type": "text", "value": "Unsafe", "unknown": true]
        let initialRejection = try await renderRequest(fixture, package: package, context: context,
            compact: ["type": "text", "value": "Never partially published"], expanded: malformed)
        XCTAssertEqual((initialRejection["error"] as? [String: Any])?["code"] as? String, "invalidArguments")
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)

        let accepted = try await renderRequest(fixture, package: package, context: context,
            compact: ["type": "text", "value": "Safe compact"], expanded: ["type": "text", "value": "Safe expanded"])
        XCTAssertEqual(accepted["ok"] as? Bool, true)
        let original = try XCTUnwrap(fixture.snapshot())
        let rejectedUpdate = try await renderRequest(fixture, package: package, context: context,
            compact: ["type": "text", "value": "Never partially updated"], expanded: malformed)
        XCTAssertEqual((rejectedUpdate["error"] as? [String: Any])?["code"] as? String, "invalidArguments")
        XCTAssertEqual(fixture.snapshot()?.activity, original.activity)
        XCTAssertEqual(fixture.snapshot()?.instanceToken, original.instanceToken)
    }

    private func renderRequest(_ fixture: SuperIslandModuleFixture, package: ValidatedPluginPackage,
                               context: PluginExecutionContext, compact: [String: Any], expanded: [String: Any]) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": "superisland.render", "params": ["compact": compact, "expanded": expanded]])
        let response = await fixture.service.handle(String(decoding: request, as: UTF8.self), package: package, context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private var counterSource: String {
        """
        globalThis.count=0;
        SuperIsland.registerModule({
            compact:function(){return View.button(View.text('Count '+count),'increment');},
            onAction:function(id){if(id==='increment')count+=1;}
        });
        """
    }

    private func expanded(progress: Double) -> IslandNode {
        .vStack(.init([
            .progress(.init(progress, color: .primary)),
            .button(.init(actionID: "increment", label: .text(.init("Increment"))))
        ]))
    }

    private func package(id: String = "com.example.compatible-module", source: String,
                         engine: PluginEngine = .superIsland,
                         capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions]) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Compatible Module Test", version: SemanticVersion("1.0.0"),
            engine: engine, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/superisland-module-tests/\(id)"),
            entryRelativePath: "index.js", entrySource: Data(source.utf8), regularFileCount: 2, totalFileBytes: UInt64(source.utf8.count))
    }

    private func snapshot(_ fixture: SuperIslandModuleFixture, id: String? = nil) async throws -> ActivitySnapshot {
        try await waitUntil { fixture.snapshot(id: id) != nil && fixture.latestRuntime(id: id)?.snapshot.state == .running }
        return try XCTUnwrap(fixture.snapshot(id: id))
    }

    private func predicate(_ runtime: PluginRuntime, _ expression: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while true {
            if runtime.snapshot.state == .running, try await runtime.evaluateForTesting(expression) == .boolean(true) { return }
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else {
                XCTFail("Compatibility predicate did not settle: \(expression), \(runtime.snapshot)")
                throw SuperIslandModuleTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Compatible module did not reach the expected state.", file: file, line: line)
                throw SuperIslandModuleTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SuperIslandModuleFixture {
    let defaultID = "com.example.compatible-module"
    let service = PluginJSBridge(activityRateClock: { 1_000 })
    let manager: ActivityManager
    let router: ActionRouter
    let lifecycle: PluginLifecycleBridge
    private let factory: SuperIslandModuleRuntimeFactory
    var runtimes: [PluginRuntime] { factory.runtimes }

    init() {
        var configuration = ActivityScheduler.Configuration.immediate
        configuration.maximumQueuedNormal = 32
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 104_000)), configuration: configuration)
        self.manager = manager
        let router = ActionRouter(manager: manager)
        self.router = router
        let factory = SuperIslandModuleRuntimeFactory(service: service)
        self.factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, runtimeFactory: { package in
            let runtime = factory.usesJavaScript ? PluginRuntime(package: package, bridge: factory.service) : nil
            if let runtime {
                factory.runtimes.append(runtime)
                factory.latestRuntimeByID[package.manifest.id] = runtime
            }
            return SuperIslandModuleLifecycleRuntime(factory: factory, runtime: runtime)
        })
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        factory.usesJavaScript = true
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes[factory.runtimes.count - 1]
    }

    func loadHost(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        factory.usesJavaScript = false
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.contexts.last)
    }

    func latestRuntime(id: String?) -> PluginRuntime? { factory.latestRuntimeByID[id ?? defaultID] }

    func snapshot(id: String? = nil) -> ActivitySnapshot? {
        manager.toolSnapshots.first { $0.activity.source.identifier == (id ?? defaultID) }
    }

    func dispatch(_ snapshot: ActivitySnapshot, id: String = "increment") -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
            action: .init(actionID: id, value: .none))
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class SuperIslandModuleRuntimeFactory {
    let service: PluginJSBridge
    var usesJavaScript = true
    var contexts: [PluginExecutionContext] = []
    var runtimes: [PluginRuntime] = []
    var latestRuntimeByID: [String: PluginRuntime] = [:]
    init(service: PluginJSBridge) { self.service = service }
}

@MainActor
private final class SuperIslandModuleLifecycleRuntime: PluginLifecycleRuntime {
    let factory: SuperIslandModuleRuntimeFactory
    let runtime: PluginRuntime?
    init(factory: SuperIslandModuleRuntimeFactory, runtime: PluginRuntime?) { self.factory = factory; self.runtime = runtime }
    func onStart(context: PluginExecutionContext) throws { factory.contexts.append(context); try runtime?.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime?.onStop(reason: reason) }
    func teardown() { runtime?.teardown() }
}

private enum SuperIslandModuleTestError: Error { case timedOut }
