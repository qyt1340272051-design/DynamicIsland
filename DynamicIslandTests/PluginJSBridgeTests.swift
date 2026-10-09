import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginJSBridgeTests: XCTestCase {
    func testBridgeNamespacesAndMethodsAreFrozenVersionedPureJavaScript() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package())
        try await ready(runtime)
        let result = try await runtime.evaluateForTesting("""
            Object.isFrozen(island) && Object.isFrozen(island.plugin) &&
            ['activity', 'storage', 'actions'].every(key => Object.isFrozen(island[key])) &&
            [island.log, island.activity.publish, island.activity.end,
             island.storage.get, island.storage.set, island.storage.remove,
             island.storage.clear, island.actions.on, island.actions.off].every(method =>
                 typeof method === 'function' && Object.isFrozen(method) && method.apiVersion === '1.0.0') &&
            island.actions.supported === false &&
            [island.log, island.storage.get].every(method => {
                try { void method.caller; return false; } catch (_) { return true; }
            }) &&
            !Object.getOwnPropertyNames(globalThis).some(key => key.startsWith('__islandBridge_')) &&
            ['FileManager', 'NSFileManager', 'URLSession', 'NSURLSession', 'NSWorkspace',
             'ObjC', 'require', 'fetch', 'setTimeout'].every(key => typeof globalThis[key] === 'undefined')
            """)
        XCTAssertEqual(result, .boolean(true))
    }

    func testRealJavaScriptLoggingReturnsPromisesAndReachesHostSink() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.done = false;
            function onStart() {
                const first = island.log('你好，Host');
                globalThis.isPromise = first instanceof Promise;
                first.then(value => {
                    globalThis.firstValueWasUndefined = value === null || value === undefined;
                    return island.log('detail', 'debug');
                }).then(() => island.log('careful', 'warning'))
                  .then(() => island.log('failure', 'error'))
                  .then(() => { globalThis.done = true; });
            }
            """))
        try await marker(runtime, "done")
        let entries = fixture.service.logs(for: "com.example.alpha")
        XCTAssertEqual(entries.map(\.message), ["你好，Host", "detail", "careful", "failure"])
        XCTAssertEqual(entries.map(\.pluginID), Array(repeating: "com.example.alpha", count: 4))
        XCTAssertEqual(entries.map(\.level), [.info, .debug, .warning, .error])
        try await assertValue(runtime, "isPromise && firstValueWasUndefined", equals: .boolean(true))
    }

    func testActivityPromisePublishesHostOwnedIdentityAndEndsIt() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.published = false;
            function onStart() {
                island.activity.publish({id: 'download', presentation: {
                    title: '下载中', subtitle: 'sample.zip', symbolName: 'arrow.down.circle', progress: 0.73
                }}).then(value => { globalThis.returnedID = value.id; globalThis.published = true; });
            }
            """))
        try await marker(runtime, "published")
        let id = PluginJSBridge.activityID(pluginID: "com.example.alpha", localID: "download")
        let activity = try XCTUnwrap(fixture.manager.activity(id: id))
        XCTAssertEqual(activity.source, .init(kind: .plugin, identifier: "com.example.alpha"))
        XCTAssertEqual(activity.priority, .normal)
        XCTAssertEqual(activity.lifecycle.policy, .transient)
        XCTAssertEqual(activity.presentation, .init(title: "下载中", subtitle: "sample.zip", symbolName: "arrow.down.circle", progress: 0.73))
        XCTAssertTrue(activity.actions.isEmpty)
        try await assertValue(runtime, "returnedID", equals: .string("download"))

        _ = try await value(runtime, "island.activity.end('download').then(() => { globalThis.ended = true; }); void 0")
        try await marker(runtime, "ended")
        XCTAssertNil(fixture.manager.activity(id: id))
        XCTAssertNil(fixture.manager.current)
    }

    func testActivityPublishedByJavaScriptRendersInExistingHostView() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package())
        try await ready(runtime)
        let size = CGSize(width: 470, height: 150)
        let view = NSHostingView(rootView: BridgeRenderedActivityView(manager: fixture.manager))
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let empty = try await render(view, size: size)

        _ = try await value(runtime, "island.activity.publish({id:'render',presentation:{title:'真实 JS Activity',symbolName:'bolt.fill'}}).then(() => { globalThis.rendered = true; }); void 0")
        try await marker(runtime, "rendered")
        let published = try await render(view, size: size)
        XCTAssertNotEqual(empty, published)
        XCTAssertEqual(fixture.manager.current?.presentation.title, "真实 JS Activity")

        _ = try await value(runtime, "island.activity.end('render').then(() => { globalThis.ended = true; }); void 0")
        try await marker(runtime, "ended")
        let ended = try await render(view, size: size)
        XCTAssertNotEqual(published, ended)
        XCTAssertNil(fixture.manager.current)
    }

    func testSameLocalActivityIDIsScopedToPluginAndDisableOnlyRemovesOwner() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let script = """
            function onStart() {
                island.activity.publish({id:'same',presentation:{title:island.plugin.id}})
                    .then(() => { globalThis.done = true; });
            }
            """
        let alpha = fixture.load(try package(source: script))
        let beta = fixture.load(try package(id: "com.example.beta", source: script))
        try await marker(alpha, "done")
        try await marker(beta, "done")
        let alphaID = PluginJSBridge.activityID(pluginID: "com.example.alpha", localID: "same")
        let betaID = PluginJSBridge.activityID(pluginID: "com.example.beta", localID: "same")
        XCTAssertNotEqual(alphaID, betaID)
        XCTAssertEqual(fixture.manager.activity(id: alphaID)?.source.identifier, "com.example.alpha")
        XCTAssertEqual(fixture.manager.activity(id: betaID)?.source.identifier, "com.example.beta")

        fixture.lifecycle.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        XCTAssertNil(fixture.manager.activity(id: alphaID))
        XCTAssertNotNil(fixture.manager.activity(id: betaID))
        XCTAssertEqual(fixture.lifecycle.snapshot(id: "com.example.beta")?.state, .running)
    }

    func testStorageRoundTripsJSONAndMissingKeyIsNull() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                island.storage.get('missing').then(value => {
                    globalThis.missingWasNull = value === null;
                    return island.storage.set('settings', {enabled:true, count:3, rows:['a',null,{name:'测试'}]});
                }).then(() => island.storage.get('settings')).then(value => {
                    globalThis.valid = value.enabled === true && value.count === 3 &&
                        value.rows[0] === 'a' && value.rows[1] === null && value.rows[2].name === '测试';
                    globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "valid && missingWasNull", equals: .boolean(true))
    }

    func testStorageRequestsKeepSetGetOrderAndRemoveClearTheirOwnKeys() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                const write = island.storage.set('counter', 1);
                const read = island.storage.get('counter');
                Promise.all([write,read]).then(values => {
                    globalThis.ordered = values[1] === 1;
                    return island.storage.set('second', 2);
                }).then(() => island.storage.remove('counter'))
                  .then(() => island.storage.get('counter'))
                  .then(value => { globalThis.removed = value === null; return island.storage.clear(); })
                  .then(() => island.storage.get('second'))
                  .then(value => { globalThis.cleared = value === null; globalThis.done = true; });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "ordered && removed && cleared", equals: .boolean(true))
    }

    func testStorageIsSeparatedByPluginAndRetainedAcrossRuntimeReplacement() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let write = """
            function onStart() {
                island.storage.set('same', island.plugin.id).then(() => { globalThis.done = true; });
            }
            """
        let alpha = fixture.load(try package(source: write))
        let beta = fixture.load(try package(id: "com.example.beta", source: write))
        try await marker(alpha, "done")
        try await marker(beta, "done")
        let read = """
            function onStart() {
                island.storage.get('same').then(value => { globalThis.saved = value; globalThis.done = true; });
            }
            """
        let replacement = fixture.load(try package(source: read))
        try await marker(replacement, "done")
        try await assertValue(replacement, "saved", equals: .string("com.example.alpha"))
        _ = try await value(beta, "island.storage.get('same').then(value => { globalThis.saved = value; globalThis.readDone = true; }); void 0")
        try await marker(beta, "readDone")
        try await assertValue(beta, "saved", equals: .string("com.example.beta"))
        XCTAssertEqual(fixture.lifecycle.snapshot(id: "com.example.alpha")?.state, .running)
    }

    func testCapabilitiesAreCheckedBeforeHostEffects() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                globalThis.codes = [];
                const calls = [island.activity.publish({id:'bad',presentation:{title:'bad'}}),
                               island.activity.end('bad'), island.storage.set('bad',1),
                               island.actions.on('click', function(){})];
                Promise.all(calls.map(call => call.catch(error => error.code))).then(codes => {
                    globalThis.allDenied = codes.every(code => code === 'capabilityRequired');
                    return island.log('still allowed');
                }).then(() => { globalThis.done = true; });
            }
            """, capabilities: []))
        try await marker(runtime, "done")
        try await assertValue(runtime, "allDenied", equals: .boolean(true))
        XCTAssertNil(fixture.manager.current)
        XCTAssertEqual(fixture.service.logs(for: "com.example.alpha").map(\.message), ["still allowed"])
    }

    func testStoragePermissionIsSeparateFromCapability() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                island.storage.set('forbidden', 1).catch(error => {
                    globalThis.code = error.code; globalThis.done = true;
                });
            }
            """, permissions: []))
        try await marker(runtime, "done")
        try await assertValue(runtime, "code", equals: .string("permissionRequired"))
    }

    func testInvalidActivityTypesUnknownFieldsAndForgedSourceHaveNoEffects() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                const calls = [
                    {id:'wrong',presentation:{title:42}},
                    {id:'unknown',presentation:{title:'x',arbitrary:'extra'}},
                    {id:'forged',source:{kind:'builtIn',identifier:'music'},presentation:{title:'x'}},
                    {id:'nan',presentation:{title:'x',progress:NaN}},
                    {id:'infinite',presentation:{title:'x',progress:Infinity}},
                    {id:'range',presentation:{title:'x',progress:1.1}},
                    {id:'type',presentation:{title:'x',progress:true}}
                ];
                Promise.all(calls.map(input => island.activity.publish(input).then(
                    () => false, error => typeof error.code === 'string'
                ))).then(values => { globalThis.rejected = values.every(Boolean); globalThis.done = true; });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "rejected", equals: .boolean(true))
        XCTAssertEqual(fixture.manager.diagnostics.activityCount, 0)
    }

    func testSerializationRejectsAccessorsAndToJSONWithoutInvokingThem() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                globalThis.getterCalls = 0;
                globalThis.toJSONCalls = 0;
                const accessor = {};
                Object.defineProperty(accessor, 'value', {enumerable:true, get() {
                    ++globalThis.getterCalls; return 1;
                }});
                const converter = {value:1, toJSON() { ++globalThis.toJSONCalls; return {value:2}; }};
                const presentation = {};
                Object.defineProperty(presentation, 'title', {enumerable:true, get() {
                    ++globalThis.getterCalls; return 'bad';
                }});
                const calls = [island.storage.set('getter',accessor), island.storage.set('toJSON',converter),
                               island.activity.publish({id:'accessor',presentation})];
                Promise.all(calls.map(call => call.then(() => false, () => true))).then(results => {
                    globalThis.rejected = results.every(Boolean); globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "rejected && getterCalls === 0 && toJSONCalls === 0", equals: .boolean(true))
        XCTAssertNil(fixture.manager.current)
        _ = try await value(runtime, "island.storage.get('getter').then(value => {globalThis.unwritten = value === null;}); void 0")
        try await marker(runtime, "unwritten")
    }

    func testProxyDescriptorIsSnapshottedOnceWithoutInheritedValueGetter() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            globalThis.unsafeCalls = 0;
            globalThis.descriptorReads = 0;
            Object.defineProperty(Object.prototype, 'value', {
                configurable:true, get() { ++globalThis.unsafeCalls; return 'unsafe'; }
            });
            const proxy = new Proxy({value:7}, {
                getOwnPropertyDescriptor(target, key) {
                    if (key === 'value' && ++globalThis.descriptorReads > 1) {
                        return {enumerable:true, configurable:true, get() { return 'changed'; }};
                    }
                    return Object.getOwnPropertyDescriptor(target, key);
                }
            });
            function onStart() {
                island.storage.set('snapshot', proxy)
                    .then(() => island.storage.get('snapshot'))
                    .then(saved => { globalThis.saved = saved.value; globalThis.done = true; });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "unsafeCalls === 0 && descriptorReads === 1 && saved === 7", equals: .boolean(true))
    }

    func testCyclicDeepWideAndOversizedStorageValuesAreRejectedWithoutWrites() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                const cycle = {}; cycle.self = cycle;
                let deep = {}; for (let i=0;i<12;i++) deep = {child:deep};
                const wide = Array.from({length:300}, (_,i) => i);
                const large = ['x'.repeat(4000),'y'.repeat(4000),'z'.repeat(4000)];
                const requests = [['cycle',cycle],['deep',deep],['wide',wide],['large',large]];
                Promise.all(requests.map(([key,value]) => island.storage.set(key,value).then(
                    () => false, () => true
                ))).then(results => {
                    globalThis.rejected = results.every(Boolean);
                    return Promise.all(requests.map(([key]) => island.storage.get(key)));
                }).then(results => { globalThis.unwritten = results.every(value => value === null); globalThis.done = true; });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "rejected && unwritten", equals: .boolean(true))
    }

    func testCapturedIntrinsicsKeepBridgeWorkingAfterPluginChangesBuiltIns() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                globalThis.unsafeCalls = 0;
                Object.defineProperty(Object.prototype, 'toJSON', {get() {
                    ++globalThis.unsafeCalls; return function(){ return 'forged'; };
                }});
                Object.defineProperty(Object.prototype, 'then', {get() {
                    ++globalThis.unsafeCalls; throw 'unsafe Promise assimilation';
                }});
                JSON.stringify = function(){ throw 'patched stringify'; };
                JSON.parse = function(){ throw 'patched parse'; };
                Object.keys = function(){ throw 'patched keys'; };
                Object.getOwnPropertyDescriptor = function(){ throw 'patched descriptor'; };
                Object.getPrototypeOf = function(){ throw 'patched prototype'; };
                Array.isArray = function(){ throw 'patched array'; };
                globalThis.done = false;
                island.storage.set('safe', {value:['a',1,true]}).then(() => island.storage.get('safe'))
                    .then(value => { globalThis.valid = value.value[0] === 'a' && value.value[1] === 1; return island.log('survived'); })
                    .then(() => { globalThis.done = true; }, error => {globalThis.errorCode = error.code; globalThis.done = true;});
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "valid === true && typeof errorCode === 'undefined' && unsafeCalls === 0", equals: .boolean(true))
        XCTAssertEqual(fixture.service.logs(for: "com.example.alpha").map(\.message), ["survived"])
    }

    func testActionsValidateArgumentsAndExplicitlyRejectDeferredImplementation() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                Promise.all([
                    island.actions.on('click', function(){}).catch(error => error.code),
                    island.actions.off('click').catch(error => error.code),
                    island.actions.on('click', 'not a function').catch(error => error.code),
                    island.actions.off(42).catch(error => error.code)
                ]).then(codes => {
                    globalThis.valid = codes[0] === 'unsupportedMethod' && codes[1] === 'unsupportedMethod' &&
                        codes[2] === 'invalidArguments' && codes[3] === 'invalidArguments';
                    globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "valid && island.actions.supported === false", equals: .boolean(true))
    }

    func testHostRejectsMalformedDuplicateVersionAndUnknownMethodRequests() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let runtime = fixture.load(package)
        try await ready(runtime)
        let context = try XCTUnwrap(fixture.factory.contexts.last)
        let invalidRequests = [
            "{",
            "{\"apiVersion\":\"1.0.0\",\"method\":\"log\",\"method\":\"storage.clear\",\"params\":{}}",
            "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.set\",\"params\":{\"key\":\"x\",\"value\":{\"nested\":1,\"nested\":2}}}",
            "{\"apiVersion\":\"1.0.0\",\"method\":\"log\",\"params\":{\"message\":\"bad\",\"level\":\"info\"},\"source\":\"forged\"}",
            "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.set\",\"params\":{\"key\":\"x\",\"value\":NaN}}"
        ]
        for request in invalidRequests {
            let response = try decode(fixture.service.handle(request, package: package, context: context))
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertNotNil((response["error"] as? [String: Any])?["code"] as? String)
        }
        let version = try decode(fixture.service.handle("{\"apiVersion\":\"99.0.0\",\"method\":\"storage.clear\",\"params\":{}}", package: package, context: context))
        XCTAssertEqual(errorCode(version), "unsupportedVersion")
        let unknown = try decode(fixture.service.handle("{\"apiVersion\":\"1.0.0\",\"method\":\"workspace.open\",\"params\":{}}", package: package, context: context))
        XCTAssertEqual(errorCode(unknown), "unsupportedMethod")
        let oversized = try request(fixture, package: package, context: context, method: "log", params: ["message":String(repeating: "x", count: 20_000),"level":"info"])
        XCTAssertEqual(errorCode(oversized), "quotaExceeded")
        XCTAssertTrue(fixture.service.logs(for: package.manifest.id).isEmpty)
        let missing = try decode(fixture.service.handle("{\"apiVersion\":\"1.0.0\",\"method\":\"storage.get\",\"params\":{\"key\":\"x\"}}", package: package, context: context))
        XCTAssertTrue(missing["value"] is NSNull)
    }

    func testOldContextAndWrongPackageCannotMutateReplacementSession() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let alpha = try package()
        let first = fixture.load(alpha)
        try await ready(first)
        let oldContext = try XCTUnwrap(fixture.factory.contexts.last)
        let current = fixture.load(alpha)
        try await ready(current)
        let currentContext = try XCTUnwrap(fixture.factory.contexts.last)
        let request = "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.set\",\"params\":{\"key\":\"stale\",\"value\":1}}"
        let revoked = try decode(fixture.service.handle(request, package: alpha, context: oldContext))
        XCTAssertEqual(errorCode(revoked), "inactiveExecution")
        let mismatched = try decode(fixture.service.handle(request, package: try package(id: "com.example.beta"), context: currentContext))
        XCTAssertEqual(mismatched["ok"] as? Bool, false)
        let read = try decode(fixture.service.handle("{\"apiVersion\":\"1.0.0\",\"method\":\"storage.get\",\"params\":{\"key\":\"stale\"}}", package: alpha, context: currentContext))
        XCTAssertTrue(read["value"] is NSNull)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha.manifest.id)?.state, .running)
    }

    func testImmediateDisableRevokesStartupBridgeAdmissionAndNewSessionStaysUsable() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let first = fixture.load(try package(source: """
            function onStart() {
                const finish = Date.now() + 200;
                while (Date.now() < finish) {}
                island.log('stale log');
                island.storage.set('stale',1);
                island.activity.publish({id:'stale',presentation:{title:'stale'}});
            }
            """))
        fixture.lifecycle.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        let current = fixture.load(try package(source: """
            function onStart() {
                island.storage.get('stale').then(value => {
                    globalThis.clean = value === null; return island.log('current log');
                }).then(() => { globalThis.done = true; });
            }
            """))
        try await marker(current, "done")
        try await waitUntil { first.snapshot.state == .tornDown }
        try await assertValue(current, "clean", equals: .boolean(true))
        XCTAssertEqual(fixture.service.logs(for: "com.example.alpha").map(\.message), ["current log"])
        XCTAssertNil(fixture.manager.current)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: "com.example.alpha")?.state, .running)
    }

    func testTransportRevocationDropsQueuedRequestsAndRepliesBeforeHostEffects() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let first = fixture.load(package)
        try await ready(first)
        let oldContext = try XCTUnwrap(fixture.factory.contexts.last)
        let transport = PluginBridgeTransport(bridge: fixture.service, package: package, context: oldContext)
        let replies = JSBridgeReplyCounter()
        // This synchronous MainActor section ensures drain's MainActor.run
        // cannot process either queued request until after revocation.
        XCTAssertTrue(transport.submit(id: 1, json: "{\"apiVersion\":\"1.0.0\",\"method\":\"log\",\"params\":{\"message\":\"queued stale\",\"level\":\"info\"}}") { _, _ in replies.increment() })
        XCTAssertTrue(transport.submit(id: 2, json: "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.set\",\"params\":{\"key\":\"queued\",\"value\":1}}") { _, _ in replies.increment() })
        transport.revoke()
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        let current = fixture.load(try self.package(source: """
            function onStart() {
                island.storage.get('queued').then(value => {
                    globalThis.clean = value === null;
                    return island.log('new session');
                }).then(() => { globalThis.done = true; });
            }
            """))
        try await marker(current, "done")
        try await assertValue(current, "clean", equals: .boolean(true))
        XCTAssertEqual(replies.count, 0)
        XCTAssertEqual(fixture.service.logs(for: package.manifest.id).map(\.message), ["new session"])
        XCTAssertFalse(transport.submit(id: 3, json: "{}") { _, _ in replies.increment() })
        XCTAssertEqual(fixture.lifecycle.snapshot(id: package.manifest.id)?.state, .running)
    }

    func testHostStorageQuotasRejectNewKeyButAllowOverwriteAndCleanup() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let runtime = fixture.load(package)
        try await ready(runtime)
        let context = try XCTUnwrap(fixture.factory.contexts.last)
        for index in 0..<128 {
            let response = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"k\(index)","value":index])
            XCTAssertEqual(response["ok"] as? Bool, true)
        }
        let excess = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"overflow","value":true])
        XCTAssertEqual(excess["ok"] as? Bool, false)
        let overwrite = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"k0","value":42])
        XCTAssertEqual(overwrite["ok"] as? Bool, true)
        let remove = try request(fixture, package: package, context: context, method: "storage.remove", params: ["key":"k1"])
        XCTAssertEqual(remove["ok"] as? Bool, true)
        let afterRemove = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"replacement","value":"ok"])
        XCTAssertEqual(afterRemove["ok"] as? Bool, true)
        _ = try request(fixture, package: package, context: context, method: "storage.clear", params: [:])
        let cleared = try request(fixture, package: package, context: context, method: "storage.get", params: ["key":"k0"])
        XCTAssertTrue(cleared["value"] is NSNull)
        let longKey = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":String(repeating: "k", count: 129),"value":1])
        XCTAssertEqual(longKey["ok"] as? Bool, false)
        for index in 0..<16 {
            let stored = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"bulk\(index)","value":String(repeating: "x", count: 4_000)])
            XCTAssertEqual(stored["ok"] as? Bool, true)
        }
        let tooManyBytes = try request(fixture, package: package, context: context, method: "storage.set", params: ["key":"bulk16","value":String(repeating: "x", count: 4_000)])
        XCTAssertEqual(errorCode(tooManyBytes), "quotaExceeded")
        let unwritten = try request(fixture, package: package, context: context, method: "storage.get", params: ["key":"bulk16"])
        XCTAssertTrue(unwritten["value"] is NSNull)
    }

    func testOutstandingPromiseRequestsAreBoundedAndSettleExactlyOnce() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(source: """
            function onStart() {
                const requests = [];
                globalThis.settlements = 0;
                for (let index = 0; index < 80; ++index) {
                    requests.push(island.storage.get('missing').then(
                        () => { ++globalThis.settlements; return 'ok'; },
                        error => { ++globalThis.settlements; return error.code; }
                    ));
                }
                Promise.all(requests).then(values => {
                    globalThis.accepted = values.filter(value => value === 'ok').length;
                    globalThis.denied = values.filter(value => value === 'quotaExceeded').length;
                    globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertValue(runtime, "accepted === 64 && denied === 16 && settlements === 80", equals: .boolean(true))
    }

    func testLogRingAndActivityInventoryStayBoundedAndRejectOversizedInput() async throws {
        let fixture = JSBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let runtime = fixture.load(package)
        try await ready(runtime)
        let context = try XCTUnwrap(fixture.factory.contexts.last)
        for index in 0..<105 {
            let result = try request(fixture, package: package, context: context, method: "log", params: ["message":"log \(index)","level":"info"])
            XCTAssertEqual(result["ok"] as? Bool, true)
        }
        let logs = fixture.service.logs(for: package.manifest.id)
        XCTAssertEqual(logs.count, 100)
        XCTAssertEqual(logs.first?.message, "log 5")
        XCTAssertEqual(logs.last?.message, "log 104")
        let oversized = try request(fixture, package: package, context: context, method: "log", params: ["message":String(repeating:"界",count:400),"level":"info"])
        XCTAssertEqual(oversized["ok"] as? Bool, false)
        XCTAssertEqual(fixture.service.logs(for: package.manifest.id).count, 100)

        for index in 0..<16 {
            let result = try request(fixture, package: package, context: context, method: "activity.publish", params: ["id":"a\(index)","presentation":["title":"Activity \(index)"]])
            XCTAssertEqual(result["ok"] as? Bool, true)
        }
        let excess = try request(fixture, package: package, context: context, method: "activity.publish", params: ["id":"excess","presentation":["title":"excess"]])
        XCTAssertEqual(excess["ok"] as? Bool, false)
        XCTAssertEqual(fixture.manager.diagnostics.activityCount, 16)
    }

    // MARK: Helpers

    private func package(
        id: String = "com.example.alpha", source: String = "",
        permissions: [PluginPermission] = [.localStorage],
        capabilities: [PluginCapability] = [.publishActivity, .endActivity, .localStorage, .handleActions]
    ) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(
            id: id, name: "Bridge Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: permissions, capabilities: capabilities
        )
        let bytes = Data(source.utf8)
        return ValidatedPluginPackage(
            manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/bridge-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count)
        )
    }

    private func ready(_ runtime: PluginRuntime) async throws {
        try await waitUntil { runtime.snapshot.state == .running || runtime.snapshot.lastFailure != nil }
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        try await ready(runtime)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await value(runtime, "globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else {
                XCTFail("JavaScript Promise marker \(name) did not settle.")
                throw JSBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func value(_ runtime: PluginRuntime, _ source: String) async throws -> PluginJavaScriptValue {
        try await runtime.evaluateForTesting(source)
    }

    private func assertValue(
        _ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await value(runtime, source)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Runtime state timed out.")
                throw JSBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func request(
        _ fixture: JSBridgeFixture, package: ValidatedPluginPackage, context: PluginExecutionContext,
        method: String, params: [String: Any]
    ) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: ["apiVersion":"1.0.0","method":method,"params":params])
        return try decode(fixture.service.handle(String(decoding: bytes, as: UTF8.self), package: package, context: context))
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func errorCode(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }

    private func render<Content: View>(_ view: NSHostingView<Content>, size: CGSize) async throws -> Data {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class JSBridgeFixture {
    let service = PluginJSBridge()
    let factory = JSBridgeTestFactory()
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge

    init() {
        // Raise the Core's independent queue bound so the Bridge's per-plugin
        // inventory limit can be exercised without Core eviction obscuring it.
        var configuration = ActivityScheduler.Configuration.immediate
        configuration.maximumQueuedNormal = 32
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 90_000)), configuration: configuration)
        self.manager = manager
        let service = service
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager)) { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return JSBridgeTestForwarder(runtime: runtime, factory: factory)
        }
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class JSBridgeTestFactory {
    var runtimes: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
}

@MainActor
private final class JSBridgeTestForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let factory: JSBridgeTestFactory

    init(runtime: PluginRuntime, factory: JSBridgeTestFactory) {
        self.runtime = runtime
        self.factory = factory
    }

    func onStart(context: PluginExecutionContext) throws {
        factory.contexts.append(context)
        try runtime.onStart(context: context)
    }

    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private struct BridgeRenderedActivityView: View {
    @ObservedObject var manager: ActivityManager

    var body: some View {
        Group {
            if let activity = manager.current {
                IslandRenderer(presentation: activity.presentation, mode: .expanded, shellSize: .init(width: 470, height: 150))
            } else {
                Text("No Activity")
            }
        }
        .frame(width: 470, height: 150)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}

private enum JSBridgeTestError: Error { case timedOut }

private nonisolated final class JSBridgeReplyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
