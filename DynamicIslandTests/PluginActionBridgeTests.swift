import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginActionBridgeTests: XCTestCase {
    func testActualActionMockSwiftUIButtonToggleSliderAndTypedCommitReachJavaScript() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("t26-action-mock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = container.appendingPathComponent("action-mock", isDirectory: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("docs/plugin-system/examples/action-mock"), to: root)
        try PluginLogTestWitness.instrumentTemporaryEntry(at: root)
        let package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: container))
        let runtime = try fixture.load(package)
        try await log(fixture, id: package.manifest.id, message: "action.ready")
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(original.activity.id, PluginJSBridge.activityID(pluginID: package.manifest.id, localID: "controls"))
        let witness = ActionRenderWitness()
        let view = NSHostingView(rootView: ActionBridgeRenderedView(manager: fixture.manager, router: fixture.router, witness: witness))
        view.frame = CGRect(x: 0, y: 0, width: 480, height: 200)
        // A key-capable nonactivating surface hosts the actual renderer
        // without relying on activation of the XCTest Host application.
        let window = NSPanel(contentRect: view.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(view)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-island-t26-controls.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
            print("T26 render: \(path.path)")
        }
        try await click(view, window: window, atTopLeftPoint: .init(x: 40, y: 62))
        try await log(fixture, id: package.manifest.id, message: "action.pause")
        XCTAssertEqual(fixture.manager.current?.presentation.title, "已暂停")
        try await settle(view)
        try await click(view, window: window, atTopLeftPoint: .init(x: 76, y: 93))
        try await log(fixture, id: package.manifest.id, message: "action.toggle")
        XCTAssertEqual(control(fixture.manager.current?.presentation.expanded, id: "enabled"), .toggle(.init(title: "启用示例", isOn: true, actionID: "enabled")))
        try await settle(view)
        try await click(view, window: window, atTopLeftPoint: .init(x: 340, y: 134))
        try await log(fixture, id: package.manifest.id, message: "action.slider")
        try await log(fixture, id: package.manifest.id, message: "action.sliderCommit")
        XCTAssertGreaterThan(try XCTUnwrap(fixture.manager.current?.presentation.progress), 0.1)
        XCTAssertTrue(witness.actions.contains(.init(actionID: "pause", value: .none)))
        XCTAssertTrue(witness.actions.contains(.init(actionID: "enabled", value: .toggle(true))))
        XCTAssertTrue(witness.actions.contains { if case .slider = $0.value { return $0.actionID == "progress" }; return false })
        XCTAssertTrue(witness.actions.contains { if case .sliderCommit = $0.value { return $0.actionID == "progress" }; return false })
        XCTAssertTrue(witness.results.allSatisfy { $0 == .handled })
        // Mouse input proves both Binding and editing-end paths. A second
        // typed commit checks the exact value without reusing the first log.
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        let commits = try await PluginLogTestWitness.count(runtime, pluginID: package.manifest.id, message: "action.sliderCommit")
        XCTAssertEqual(fixture.dispatch(snapshot, id: "progress", value: .sliderCommit(0.75)), .handled)
        try await log(fixture, id: package.manifest.id, message: "action.sliderCommit", count: commits + 1)
        XCTAssertEqual(fixture.manager.current?.presentation.progress, 0.75)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, original.instanceToken)
        XCTAssertEqual(fixture.manager.current?.createdAt, original.activity.createdAt)
        let noCallbackErrors = try await runtime.evaluateForTesting("__testLogWitness.every(value => !value.startsWith('action.error:'))")
        XCTAssertEqual(noCallbackErrors, .boolean(true))
    }

    func testFrozenLocalEventAndAllFourTypedPayloadsArriveInFIFO() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: """
            events.push(event);
            safe = safe && arguments.length === 1 && Object.isFrozen(event) && Object.isFrozen(event.value)
                && Object.getPrototypeOf(event) === null && Object.getPrototypeOf(event.value) === null
                && Object.keys(event).sort().join(',') === 'actionID,activityID,value' && event.activityID === 'controls';
            """)))
        try await marker(runtime, "ready")
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        let values: [IslandRenderActionValue] = [.none, .toggle(true), .slider(0.25), .sliderCommit(0.75)]
        for value in values {
            XCTAssertEqual(fixture.dispatch(snapshot, value: value), .handled)
        }
        try await predicate(runtime, "events.length === 4")
        let value = try await runtime.evaluateForTesting("safe && events.map(event=>event.value.type).join(',') === 'none,toggle,slider,sliderCommit' && events[1].value.value === true && events[2].value.value === 0.25 && events[3].value.value === 0.75 && Object.keys(events[0].value).join(',') === 'type'")
        XCTAssertEqual(value, .boolean(true))
    }

    func testCallbackPromiseCanReenterUpdateWithoutChangingInstance() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: "return island.activity.update({id:'controls',presentation:{title:'Callback updated',progress:0.5}}).then(()=>island.log('callback.updated'));")))
        try await marker(runtime, "ready")
        let before = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(fixture.dispatch(before), .handled)
        try await log(fixture, message: "callback.updated")
        XCTAssertEqual(fixture.manager.current?.presentation.title, "Callback updated")
        XCTAssertEqual(fixture.manager.current?.presentation.progress, 0.5)
        XCTAssertEqual(fixture.manager.current?.createdAt, before.activity.createdAt)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, before.instanceToken)
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testOnReplacementOffIdempotenceAndReregistrationUseCurrentHandler() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: "events.push('old');")))
        try await marker(runtime, "ready")
        _ = try await runtime.evaluateForTesting("island.actions.on('fire',()=>events.push('new')).then(()=>{globalThis.replaced=true;});void 0")
        try await marker(runtime, "replaced")
        XCTAssertEqual(fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot)), .handled)
        try await predicate(runtime, "events.length === 1")
        let selected = try await runtime.evaluateForTesting("events.join(',')")
        XCTAssertEqual(selected, .string("new"))
        _ = try await runtime.evaluateForTesting("island.actions.off('fire').then(()=>island.actions.off('fire')).then(()=>{globalThis.removed=true;});void 0")
        try await marker(runtime, "removed")
        _ = fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot))
        _ = try await runtime.evaluateForTesting("island.actions.on('fire',()=>events.push('latest')).then(()=>{globalThis.restored=true;});void 0")
        try await marker(runtime, "restored")
        XCTAssertEqual(fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot)), .handled)
        try await predicate(runtime, "events.length === 2")
        let final = try await runtime.evaluateForTesting("events.join(',')")
        XCTAssertEqual(final, .string("new,latest"))
    }

    func testRegistrationCapacityReplacementAndOffReleaseCapacity() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            function onStart(){void (async function(){
                for(let i=0;i<128;i++) await island.actions.on('a'+i,function(){});
                globalThis.full=await island.actions.on('overflow',function(){}).catch(error=>error.code);
                await island.actions.on('a0',function(){});await island.actions.off('a1');
                globalThis.released=await island.actions.on('overflow',function(){});globalThis.done=true;
            })().catch(error=>{globalThis.failure=error.code;globalThis.done=true;});}
            """))
        try await marker(runtime, "done")
        let correct = try await runtime.evaluateForTesting("full === 'quotaExceeded' && released === null && typeof failure === 'undefined'")
        XCTAssertEqual(correct, .boolean(true))
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testOutstandingSameIDRegistrationsDoNotRollbackAcceptedReplacement() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            globalThis.selected=-1;
            function onStart(){const requests=[];
                for(let i=0;i<65;i++)requests.push(island.actions.on('fire',function(){selected=i;}).catch(error=>error.code));
                Promise.all(requests).then(codes=>{globalThis.safe=codes.slice(0,64).every(value=>value===null)&&codes[64]==='quotaExceeded';
                    return island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},presentation:{title:'Burst'},actions:[{id:'fire',title:'Fire'}]});
                }).then(()=>{globalThis.ready=true;});}
            """))
        try await marker(runtime, "ready")
        XCTAssertEqual(fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot)), .handled)
        try await predicate(runtime, "selected === 63")
        let safe = try await runtime.evaluateForTesting("safe")
        XCTAssertEqual(safe, .boolean(true))
        _ = try await runtime.evaluateForTesting("island.actions.on('fire',()=>{selected=99;}).then(()=>{globalThis.replaced=true;});void 0")
        try await marker(runtime, "replaced")
        XCTAssertEqual(fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot)), .handled)
        try await predicate(runtime, "selected === 99")
    }

    func testJavaScriptArgumentLimitsAndCapabilityChecksHaveNoCallbackEffects() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            function onStart(){Promise.all([
                island.actions.on(42,function(){}),island.actions.on('bad:colon',function(){}),
                island.actions.on('x'.repeat(81),function(){}),island.actions.on('fire','not a function'),
                island.actions.on('fire',function(){},1),island.actions.off(),island.actions.off('fire',1)
            ].map(call=>call.catch(error=>error.code))).then(codes=>{
                globalThis.safe=codes.join(',')==='invalidArguments,invalidArguments,quotaExceeded,invalidArguments,invalidArguments,invalidArguments,invalidArguments';globalThis.done=true;
            });}
            """))
        try await marker(runtime, "done")
        let safe = try await runtime.evaluateForTesting("safe")
        XCTAssertEqual(safe, .boolean(true))
        let denied = try fixture.load(package(id: "com.example.denied", source: """
            function onStart(){Promise.all([island.actions.on('fire',function(){}),island.actions.off('fire')].map(call=>call.catch(error=>error.code)))
                .then(codes=>{globalThis.safe=codes.every(code=>code==='capabilityRequired');globalThis.done=true;});}
            """, capabilities: []))
        try await marker(denied, "done")
        let deniedValue = try await denied.evaluateForTesting("safe")
        XCTAssertEqual(deniedValue, .boolean(true))
        XCTAssertNil(fixture.manager.current)
    }

    func testHostWireRejectsInvalidAndMismatchedSessions() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let alpha = try package()
        let context = try fixture.loadHost(alpha)
        let captures = ActionDeliveryCapture()
        let session = try PluginActionSession(package: alpha, context: context) { captures.values.append($0) }
        defer { session.revoke() }
        let invalidParams: [[String: Any]] = [
            ["actionID": "fire"], ["actionID": "fire", "registrationID": 1],
            ["actionID": "fire", "registrationID": "bad:registration"],
            ["actionID": "fire", "registrationID": "r1", "handler": "native"],
            ["actionID": "bad:action", "registrationID": "r1"]
        ]
        for params in invalidParams {
            let response = try await request(fixture, package: alpha, context: context, session: session, method: "actions.on", params: params)
            XCTAssertEqual(errorCode(response), "invalidArguments")
        }
        let oversized = try await request(fixture, package: alpha, context: context, session: session, method: "actions.on", params: ["actionID": "fire", "registrationID": String(repeating: "r", count: 81)])
        XCTAssertEqual(errorCode(oversized), "quotaExceeded")
        let missingSession = try await request(fixture, package: alpha, context: context, method: "actions.on", params: ["actionID": "fire", "registrationID": "r1"])
        XCTAssertEqual(errorCode(missingSession), "inactiveExecution")
        let beta = try package(id: "com.example.other")
        let other = try fixture.loadHost(beta)
        let mismatchedSession = try await request(fixture, package: beta, context: other, session: session, method: "actions.on", params: ["actionID": "fire", "registrationID": "r1"])
        XCTAssertEqual(errorCode(mismatchedSession), "inactiveExecution")
        XCTAssertThrowsError(try PluginActionSession(package: beta, context: context, deliver: { _ in }))
        XCTAssertTrue(captures.values.isEmpty)
    }

    func testHostRegistrationGenerationOffRevokeAndCapacityProtectDeliveries() throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.loadHost(package)
        let captures = ActionDeliveryCapture()
        let session = try PluginActionSession(package: package, context: context) { captures.values.append($0) }
        try session.register(actionID: "fire", registrationID: "r1")
        try fixture.publishHost(context)
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(fixture.dispatch(snapshot, value: .toggle(true)), .handled)
        let first = try XCTUnwrap(captures.values.first)
        XCTAssertTrue(first.isValid())
        XCTAssertLessThanOrEqual(first.eventJSON.utf8.count, 1_024)
        let event = try decode(first.eventJSON)
        XCTAssertEqual(Set(event.keys), ["activityID", "actionID", "value"])
        XCTAssertEqual(event["activityID"] as? String, "controls")
        XCTAssertEqual((event["value"] as? [String: Any])?["type"] as? String, "toggle")
        XCTAssertEqual((event["value"] as? [String: Any])?["value"] as? Bool, true)
        try session.register(actionID: "fire", registrationID: "r2")
        XCTAssertFalse(first.isValid())
        _ = fixture.dispatch(snapshot)
        let second = try XCTUnwrap(captures.values.last)
        XCTAssertEqual(second.registrationID, "r2")
        XCTAssertTrue(second.isValid())
        try session.unregister(actionID: "fire")
        try session.unregister(actionID: "fire")
        XCTAssertFalse(second.isValid())
        for index in 0..<128 { try session.register(actionID: "a\(index)", registrationID: "r\(index)") }
        XCTAssertThrowsError(try session.register(actionID: "overflow", registrationID: "r129")) { XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded) }
        try session.register(actionID: "a0", registrationID: "replacement")
        session.revoke()
        XCTAssertThrowsError(try session.register(actionID: "fire", registrationID: "r1")) { XCTAssertEqual($0 as? PluginBridgeErrorCode, .inactiveExecution) }
        XCTAssertFalse(first.isValid())
    }

    func testOriginalDeliveryExpiresHidesAndLosesDeclarationsWithoutReauthorization() throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.loadHost(package)
        let captures = ActionDeliveryCapture()
        let session = try PluginActionSession(package: package, context: context) { captures.values.append($0) }
        defer { session.revoke() }
        try session.register(actionID: "fire", registrationID: "r1")
        try fixture.publishHost(context, expiresAt: fixture.clock.now().addingTimeInterval(1))
        _ = fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot))
        let expired = try XCTUnwrap(captures.values.last)
        fixture.clock.advance(by: 2)
        XCTAssertFalse(expired.isValid())
        try fixture.publishHost(context)
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        _ = fixture.dispatch(original)
        let ended = try XCTUnwrap(captures.values.last)
        try context.endActivity(id: original.activity.id)
        try fixture.publishHost(context)
        XCTAssertFalse(ended.isValid())
        XCTAssertNotEqual(fixture.manager.currentSnapshot?.instanceToken, original.instanceToken)
        _ = fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot))
        let undeclared = try XCTUnwrap(captures.values.last)
        var removed = try XCTUnwrap(fixture.manager.current)
        removed.actions = []
        try fixture.manager.update(removed)
        XCTAssertFalse(undeclared.isValid())
        removed.actions = [.init(id: "fire", title: "Fire")]
        try fixture.manager.update(removed)
        _ = fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot))
        let hidden = try XCTUnwrap(captures.values.last)
        try fixture.manager.publish(IslandActivity(id: "host.interrupt", source: .init(kind: .builtIn, identifier: "host"), priority: .critical, lifecycle: .init(policy: .critical), presentation: .init(title: "Host"), createdAt: fixture.clock.now()))
        XCTAssertFalse(hidden.isValid())
    }

    func testQueuedRealCallbackCannotReachRepublishedSameIDInstance() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: "events.push(event);")))
        try await marker(runtime, "ready")
        let old = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(fixture.dispatch(old), .handled)
        let context = try XCTUnwrap(fixture.contexts.last)
        try context.endActivity(id: old.activity.id)
        try fixture.publishHost(context)
        let replacement = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertNotEqual(old.instanceToken, replacement.instanceToken)
        XCTAssertEqual(fixture.dispatch(old), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(replacement), .handled)
        try await predicate(runtime, "events.length === 1")
        let count = try await runtime.evaluateForTesting("events.length")
        XCTAssertEqual(count, .number(1))
    }

    func testStopRestartDiscardsQueuedActionsAndOldRuntimeRegistrations() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package(source: simpleSource(handler: "events.push(event);"))
        let oldRuntime = try fixture.load(package)
        try await marker(oldRuntime, "ready")
        let old = try XCTUnwrap(fixture.manager.currentSnapshot)
        _ = fixture.dispatch(old)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        let fresh = try XCTUnwrap(fixture.runtimes.last)
        XCTAssertFalse(fresh === oldRuntime)
        try await marker(fresh, "ready")
        XCTAssertEqual(fixture.dispatch(old), .inactiveActivity)
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(fixture.dispatch(snapshot), .handled)
        try await predicate(fresh, "events.length === 1")
        let count = try await fresh.evaluateForTesting("events.length")
        XCTAssertEqual(count, .number(1))
        XCTAssertEqual(fresh.snapshot.state, .running)
    }

    func testThrowRejectAndReturnedThenGetterStayIsolatedAndUseFixedLogs() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            globalThis.calls=0;globalThis.unsafeCalls=0;
            function onStart(){Promise.all([
                island.actions.on('badThrow',()=>{throw new Error('private throw detail');}),
                island.actions.on('badPromise',()=>Promise.reject('private rejection detail')),
                island.actions.on('ordinary',()=>{calls++;return Object.defineProperty({},'then',{get(){unsafeCalls++;throw 'getter';}});}),
                island.actions.on('good',()=>{calls++;})
            ]).then(()=>island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},presentation:{title:'Failures'},
                actions:['badThrow','badPromise','ordinary','good'].map(id=>({id,title:id}))})).then(()=>{globalThis.ready=true;});}
            """))
        try await marker(runtime, "ready")
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        for actionID in ["badThrow", "badPromise", "ordinary", "good"] { XCTAssertEqual(fixture.dispatch(snapshot, id: actionID), .handled) }
        try await predicate(runtime, "calls === 2")
        try await log(fixture, message: "Action handler failed.", count: 2)
        let unsafe = try await runtime.evaluateForTesting("unsafeCalls")
        XCTAssertEqual(unsafe, .number(0))
        XCTAssertEqual(fixture.service.logs(for: "com.example.action").map(\.message), ["Action handler failed.", "Action handler failed."])
        XCTAssertTrue(fixture.service.logs(for: "com.example.action").allSatisfy { $0.level == .error })
        XCTAssertEqual(fixture.service.diagnostics.records(for: "com.example.action").map(\.category), [.actionFailure, .actionFailure])
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testReentrantAuthorizerCannotDeliverRevokedRegistration() throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.loadHost(package)
        let capture = ActionDeliveryCapture()
        let session = try PluginActionSession(package: package, context: context) { capture.values.append($0) }
        try session.register(actionID: "fire", registrationID: "r1")
        try fixture.publishHost(context)
        var authorizationCount = 0
        fixture.authorization.hook = { authorizationCount += 1; if authorizationCount == 2 { session.revoke() } }
        _ = fixture.dispatch(try XCTUnwrap(fixture.manager.currentSnapshot))
        XCTAssertTrue(capture.values.isEmpty)
        XCTAssertGreaterThanOrEqual(authorizationCount, 2)
        XCTAssertThrowsError(try session.register(actionID: "fire", registrationID: "r2"))
    }

    func testWorkerActionQueueLimitsOutstandingTo64AndKeepsFIFO() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: """
            globalThis.values=[];
            function onStart(){Promise.all([island.actions.on('fire',event=>{values.push(event.value.value);}),island.actions.on('barrier',()=>island.log('barrier'))])
                .then(()=>island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},presentation:{title:'Queue'},actions:[{id:'fire',title:'Fire'},{id:'barrier',title:'Barrier'}]}))
                .then(()=>{globalThis.ready=true;});}
            """))
        try await marker(runtime, "ready")
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        for index in 0..<80 { XCTAssertEqual(fixture.dispatch(snapshot, value: .slider(Double(index) / 100)), .handled) }
        try await predicate(runtime, "values.length === 64")
        XCTAssertEqual(fixture.dispatch(snapshot, id: "barrier"), .handled)
        try await log(fixture, message: "barrier")
        let boundedFIFO = try await runtime.evaluateForTesting("values.length === 64 && values.every((value,index)=>value===index/100)")
        XCTAssertEqual(boundedFIFO, .boolean(true))
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testPendingCallbackPromiseLimitReleasesWhenPromiseSettles() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: "calls++;return new Promise(resolve=>resolvers.push(resolve));", globals: "globalThis.calls=0;globalThis.resolvers=[];")))
        try await marker(runtime, "ready")
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        for _ in 0..<64 { _ = fixture.dispatch(snapshot) }
        try await predicate(runtime, "calls === 64")
        _ = fixture.dispatch(snapshot)
        try await log(fixture, message: "Action handler limit exceeded.")
        XCTAssertEqual(fixture.service.diagnostics.records(for: "com.example.action").last?.category, .actionLimit)
        let before = try await runtime.evaluateForTesting("calls")
        XCTAssertEqual(before, .number(64))
        _ = try await runtime.evaluateForTesting("resolvers[0]();void 0")
        _ = fixture.dispatch(snapshot)
        try await predicate(runtime, "calls === 65")
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testInvalidNativePayloadAndUndeclaredActionDoNotReachCallback() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = try fixture.load(package(source: simpleSource(handler: "events.push(event);")))
        try await marker(runtime, "ready")
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        for value in [Double.nan, Double.infinity, -0.1, 1.1] {
            XCTAssertEqual(fixture.dispatch(snapshot, value: .slider(value)), .invalidPayload)
            XCTAssertEqual(fixture.dispatch(snapshot, value: .sliderCommit(value)), .invalidPayload)
        }
        XCTAssertEqual(fixture.dispatch(snapshot, id: "undeclared"), .undeclaredAction)
        XCTAssertEqual(fixture.dispatch(snapshot, id: "bad/id"), .invalidActionID)
        let empty = try await runtime.evaluateForTesting("events.length")
        XCTAssertEqual(empty, .number(0))
        XCTAssertEqual(fixture.dispatch(snapshot), .handled)
        try await predicate(runtime, "events.length === 1")
    }

    func testDifferentPluginSameIDsKeepCallbacksAndEventOwnershipSeparate() async throws {
        let fixture = ActionBridgeFixture()
        defer { fixture.shutdown() }
        let alpha = try fixture.load(package(source: simpleSource(handler: "events.push(event);")))
        try await marker(alpha, "ready")
        let first = try XCTUnwrap(fixture.manager.currentSnapshot)
        _ = fixture.dispatch(first)
        try await predicate(alpha, "events.length === 1")
        let betaID = "com.example.beta-action"
        let beta = try fixture.load(package(id: betaID, source: simpleSource(handler: "events.push(event);")))
        try await marker(beta, "ready")
        try fixture.manager.dismiss(id: first.activity.id, source: first.activity.source)
        let second = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(second.activity.source.identifier, betaID)
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(second), .handled)
        try await predicate(beta, "events.length === 1")
        let alphaCount = try await alpha.evaluateForTesting("events.length")
        let betaLocal = try await beta.evaluateForTesting("events[0].activityID")
        XCTAssertEqual(alphaCount, .number(1))
        XCTAssertEqual(betaLocal, .string("controls"))
    }

    // MARK: Helpers

    private func package(id: String = "com.example.action", source: String = "",
                         capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions]) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Action Bridge Test", version: SemanticVersion("1.0.0"), engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/action-bridge-tests/\(id)"), entryRelativePath: "index.js", entrySource: Data(PluginLogTestWitness.source(source).utf8), regularFileCount: 2, totalFileBytes: UInt64(PluginLogTestWitness.source(source).utf8.count))
    }

    private func simpleSource(handler: String, globals: String = "") -> String {
        """
        globalThis.events=[];globalThis.safe=true;\(globals)
        function onStart(){island.actions.on('fire',function(event){\(handler)})
            .then(()=>island.activity.publish({id:'controls',lifecycle:{policy:'persistent'},presentation:{title:'Controls'},actions:[{id:'fire',title:'Fire'}]}))
            .then(()=>{globalThis.ready=true;}).catch(error=>{globalThis.failure=error.code;globalThis.ready=true;});}
        """
    }

    private func predicate(_ runtime: PluginRuntime, _ expression: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while true {
            if runtime.snapshot.state == .running, try await runtime.evaluateForTesting(expression) == .boolean(true) { return }
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else {
                XCTFail("JS predicate did not settle: \(expression), \(runtime.snapshot)")
                throw ActionBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws { try await predicate(runtime, "globalThis['\(name)'] === true") }
    private func log(_ fixture: ActionBridgeFixture, id: String = "com.example.action", message: String, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while true {
            let arrived: Bool
            if message == "Action handler failed." || message == "Action handler limit exceeded." {
                let category: PluginDiagnosticCategory = message == "Action handler failed." ? .actionFailure : .actionLimit
                arrived = fixture.service.diagnostics.records(for: id).filter { $0.category == category && $0.message == message }.count >= count
            } else {
                arrived = await PluginLogTestWitness.hasMarker(fixture.runtimes, pluginID: id, message: message, count: count)
            }
            if arrived { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("Log missing \(message): \(fixture.service.logs(for: id))")
                throw ActionBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func request(_ fixture: ActionBridgeFixture, package: ValidatedPluginPackage, context: PluginExecutionContext,
                         session: PluginActionSession? = nil, method: String, params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": method, "params": params])
        return try decode(await fixture.service.handle(String(decoding: data, as: UTF8.self), package: package, context: context, actionSession: session))
    }
    private func decode(_ json: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) }
    private func errorCode(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }

    private func settle<Content: View>(_ view: NSHostingView<Content>) async throws {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }
    private func click<Content: View>(_ view: NSHostingView<Content>, window: NSWindow,
                                     atTopLeftPoint point: CGPoint) async throws {
        window.makeKeyAndOrderFront(nil)
        try await settle(view)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !window.isKeyWindow {
            guard ContinuousClock.now < deadline else {
                NativeWindowTestingDiagnostics.keyTimeout(window)
                XCTFail("The native ActionMock window did not become key before mouse delivery.")
                throw ActionBridgeTestError.timedOut
            }
            // A window transition may have dropped the first key request.
            // Retry inside the same bound, without activating the Host or
            // taking key away from an attached confirmation sheet.
            if window.attachedSheet == nil { window.makeKey() }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Fixed Host canvas positions were checked in the rendered fixture.
        // Queue up before synchronously dispatching down: AppKit controls may
        // consume up in a nested tracking loop, while SwiftUI may leave it for
        // explicit dispatch. Both paths still go through real native controls.
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(local, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) {
            NSApp.sendEvent(up)
        }
    }
    private func control(_ node: IslandNode?, id: String) -> IslandNode? {
        guard let node else { return nil }
        switch node {
        case .toggle(let value): return value.actionID == id ? node : nil
        case .slider(let value): return value.actionID == id ? node : nil
        case .button(let value): return value.actionID == id ? node : control(value.label, id: id)
        case .hStack(let value), .vStack(let value), .zStack(let value): return value.children.compactMap { control($0, id: id) }.first
        default: return nil
        }
    }
}

@MainActor
private final class ActionBridgeFixture {
    let clock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 96_000))
    let service = PluginJSBridge(activityRateClock: { 1_000 })
    let authorization = ActionAuthorizationState()
    let manager: ActivityManager
    let router: ActionRouter
    let lifecycle: PluginLifecycleBridge
    private let factory: ActionBridgeFactory
    var contexts: [PluginExecutionContext] { factory.contexts }
    var runtimes: [PluginRuntime] { factory.runtimes }

    init() {
        var configuration = ActivityScheduler.Configuration.immediate
        configuration.maximumQueuedNormal = 32
        let manager = ActivityManager(clock: clock, configuration: configuration)
        self.manager = manager
        let authorization = authorization
        let router = ActionRouter(manager: manager, authorizer: { _, _ in authorization.hook?(); return authorization.allowed })
        self.router = router
        let factory = ActionBridgeFactory(service: service)
        self.factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, runtimeFactory: { package in
            let runtime = factory.usesJavaScript ? PluginRuntime(package: package, bridge: factory.service) : nil
            if let runtime { factory.runtimes.append(runtime) }
            return ActionBridgeTestRuntime(factory: factory, runtime: runtime)
        })
    }
    func load(_ package: ValidatedPluginPackage) throws -> PluginRuntime {
        factory.usesJavaScript = true
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.runtimes.last)
    }
    func loadHost(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        factory.usesJavaScript = false
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.contexts.last)
    }
    func publishHost(_ context: PluginExecutionContext, expiresAt: Date? = nil) throws {
        try context.publish(IslandActivity(id: PluginJSBridge.activityID(pluginID: context.id, localID: "controls"), source: context.source, priority: .normal, lifecycle: .init(policy: .persistent), presentation: .init(title: "Host controls"), createdAt: clock.now(), expiresAt: expiresAt, actions: [.init(id: "fire", title: "Fire")]))
    }
    @discardableResult
    func dispatch(_ snapshot: ActivitySnapshot, id: String = "fire", value: IslandRenderActionValue = .none) -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken, action: .init(actionID: id, value: value))
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class ActionAuthorizationState { var allowed = true; var hook: (() -> Void)? }
@MainActor
private final class ActionDeliveryCapture { var values: [PluginActionDelivery] = [] }
@MainActor
private final class ActionBridgeFactory {
    let service: PluginJSBridge
    var usesJavaScript = false
    var contexts: [PluginExecutionContext] = []
    var runtimes: [PluginRuntime] = []
    init(service: PluginJSBridge) { self.service = service }
}
@MainActor
private final class ActionBridgeTestRuntime: PluginLifecycleRuntime {
    let factory: ActionBridgeFactory
    let runtime: PluginRuntime?
    init(factory: ActionBridgeFactory, runtime: PluginRuntime?) { self.factory = factory; self.runtime = runtime }
    func onStart(context: PluginExecutionContext) throws { factory.contexts.append(context); try runtime?.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime?.onStop(reason: reason) }
    func teardown() { runtime?.teardown() }
}
@MainActor
private final class ActionRenderWitness { var actions: [IslandRenderAction] = []; var results: [ActionDispatchResult] = [] }
private struct ActionBridgeRenderedView: View {
    @ObservedObject var manager: ActivityManager
    let router: ActionRouter
    let witness: ActionRenderWitness
    var body: some View {
        Group {
            if let snapshot = manager.currentSnapshot {
                IslandRenderer(presentation: snapshot.activity.presentation, mode: .expanded, shellSize: .init(width: 480, height: 200), onAction: { action in
                    witness.actions.append(action)
                    witness.results.append(router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken, action: action))
                })
            } else { Text("No Activity") }
        }.frame(width: 480, height: 200).background(Color.black).foregroundStyle(.white)
    }
}
private enum ActionBridgeTestError: Error { case timedOut }
