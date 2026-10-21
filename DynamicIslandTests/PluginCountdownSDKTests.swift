import Foundation
import JavaScriptCore
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownSDKTests: XCTestCase {
    func testNamespaceAndMethodsAreFrozenVersionedAndDoNotExposePrivateFailureAPI() throws {
        let f = try CountdownSDKFixture()
        XCTAssertTrue(try f.boolean("""
            Object.getPrototypeOf(island.countdown) === null && Object.isFrozen(island.countdown) &&
            island.countdown.apiVersion === '1.0.0' && island.countdown.supported === true &&
            ['get','start','pause','resume','stop','onComplete','offComplete'].every(name =>
                typeof island.countdown[name] === 'function' && Object.isFrozen(island.countdown[name]) &&
                island.countdown[name].apiVersion === '1.0.0' &&
                Object.getOwnPropertyDescriptor(island.countdown[name], 'apiVersion').writable === false) &&
            typeof island.countdown.failure === 'undefined' && typeof globalThis.sdkNative === 'undefined'
            """))
        try f.run("""
            globalThis.originalCountdown = island.countdown;
            try { island.countdown = {}; } catch (_) {}
            try { island.countdown.start = function() {}; } catch (_) {}
            try { Object.setPrototypeOf(island.countdown, {injected:true}); } catch (_) {}
            """)
        XCTAssertTrue(try f.boolean("island.countdown === originalCountdown && !('injected' in island.countdown)"))
    }

    func testEveryPublicMethodRejectsMalformedArgumentsBeforeNativeDispatch() async throws {
        let f = try CountdownSDKFixture()
        try f.run("""
            globalThis.codes=[];
            const g='12345678-1234-1234-1234-123456789abc';
            const invalid=[
                () => island.countdown.get(), () => island.countdown.get('focus','extra'),
                () => island.countdown.get(null), () => island.countdown.get('../outside'),
                () => island.countdown.get('x'.repeat(81)),
                () => island.countdown.start(), () => island.countdown.start(null),
                () => island.countdown.start({id:'focus',durationMs:1000,activation:'ticket'},0),
                () => island.countdown.start({id:'focus',durationMs:999,activation:'ticket'}),
                () => island.countdown.start({id:'focus',durationMs:86400001,activation:'ticket'}),
                () => island.countdown.start({id:'focus',durationMs:1000.5,activation:'ticket'}),
                () => island.countdown.start({id:'focus',durationMs:'1000',activation:'ticket'}),
                () => island.countdown.start({id:'focus',durationMs:1000}),
                () => island.countdown.start({id:'focus',durationMs:1000,activation:''}),
                () => island.countdown.pause({id:'focus'}),
                () => island.countdown.pause({id:'focus',generation:g.toUpperCase()}),
                () => island.countdown.pause({id:'focus',generation:g,activation:'ticket'}),
                () => island.countdown.resume({id:'focus',generation:g}),
                () => island.countdown.resume({id:'focus',generation:g,activation:1}),
                () => island.countdown.stop({id:'focus',generation:'not-a-generation'}),
                () => island.countdown.stop({id:'focus',generation:g,owner:'another-plugin'}),
                () => island.countdown.onComplete(null), () => island.countdown.onComplete(()=>{},0),
                () => island.countdown.offComplete(null)
            ];
            globalThis.expectedCodes=invalid.length;
            for (const call of invalid) call().then(()=>codes.push('accepted'),error=>codes.push(error.code));
            """)
        try await settled(f, "codes.length === expectedCodes")
        XCTAssertTrue(try f.boolean("codes.every(code => code === 'invalidArguments')"))
        XCTAssertEqual(try f.requestCount(), 0)
    }

    func testOptionsRejectExecutableOrInheritedDataAndSnapshotProxyOnlyOnce() async throws {
        let f = try CountdownSDKFixture()
        try f.run("""
            globalThis.unsafe=0;globalThis.rejected=0;
            const g='12345678-1234-1234-1234-123456789abc';
            const base={id:'focus',durationMs:1000,activation:'ticket'};
            const getter={id:'focus',activation:'ticket'};
            Object.defineProperty(getter,'durationMs',{enumerable:true,get(){unsafe++;return 1000;}});
            const inherited=Object.create(base);
            const symbol=Object.assign({},base);symbol[Symbol('hidden')]='hidden';
            const hidden=Object.assign({},base);Object.defineProperty(hidden,'owner',{value:'other'});
            const json=Object.assign({},base,{toJSON(){unsafe++;return base;}});
            const inputs=[getter,inherited,symbol,hidden,json,new Date(),
                Object.assign({},base,{owner:'other'}), Object.assign({},base,{callback:()=>{}})];
            for(const input of inputs) island.countdown.start(input).catch(()=>rejected++);
            globalThis.expectedRejects=inputs.length;
            globalThis.reads={id:0,durationMs:0,activation:0};
            const target={id:'focus',durationMs:1000,activation:'ticket'};
            const proxy=new Proxy(target,{getOwnPropertyDescriptor(object,key){
                reads[key]++;return {value:reads[key]===1?object[key]:'changed',enumerable:true,configurable:true,writable:true};
            }});
            island.countdown.start(proxy).catch(()=>{});
            const plain=Object.create(null);plain.id='focus';plain.generation=g;
            island.countdown.pause(plain).catch(()=>{});
            target.id='mutated';target.durationMs=2000;plain.id='mutated';
            """)
        try await settled(f, "rejected === expectedRejects")
        XCTAssertEqual(try f.requestCount(), 2)
        XCTAssertTrue(try f.boolean("unsafe===0 && Object.values(reads).every(count=>count===1)"))
        XCTAssertEqual(try f.request(0).params, .object([
            "id": .string("focus"), "durationMs": .number(1_000), "activation": .string("ticket")
        ]))
        XCTAssertEqual(try f.request(1).params, .object([
            "id": .string("focus"), "generation": .string(CountdownSDKFixture.generation)
        ]))
    }

    func testNativeSuccessDTOsAreFrozenNullPrototypeAndCannotAssimilateInheritedThen() async throws {
        let f = try CountdownSDKFixture()
        try f.run("""
            globalThis.values=[];globalThis.unsafe=0;
            const g='12345678-1234-1234-1234-123456789abc';
            function remember(value){values.push(value);}
            island.countdown.get('focus').then(remember);
            island.countdown.start({id:'focus',durationMs:1000,activation:'ticket'}).then(remember);
            island.countdown.pause({id:'focus',generation:g}).then(remember);
            island.countdown.resume({id:'focus',generation:g,activation:'ticket'}).then(remember);
            island.countdown.get('missing').then(remember);
            island.countdown.stop({id:'focus',generation:g}).then(remember);
            Object.defineProperty(Object.prototype,'then',{configurable:true,get(){unsafe++;throw 'private';}});
            """)
        for (index, state) in ["running", "running", "paused", "running"].enumerated() {
            try f.reply(index, body: success(f.dto(state: state)))
        }
        try f.reply(4, body: #"{"ok":true,"value":null}"#)
        try f.reply(5, body: #"{"ok":true,"value":null}"#)
        try await settled(f, "values.length===6")
        XCTAssertTrue(try f.boolean("""
            unsafe===0 && values.slice(0,4).every(value=>Object.isFrozen(value) &&
                Object.getPrototypeOf(value)===null && value.id==='focus') && values[4]===null && values[5]===null
            """))
    }

    func testMalformedRepliesRejectOnceWithoutCoercionOrHangingThePromise() async throws {
        let f = try CountdownSDKFixture()
        var invalid: [[String: Any]] = []
        var fields = f.dto(); fields["owner"] = "other"; invalid.append(fields)
        fields = f.dto(); fields.removeValue(forKey: "generation"); invalid.append(fields)
        fields = f.dto(); fields["id"] = "../other"; invalid.append(fields)
        fields = f.dto(); fields["generation"] = CountdownSDKFixture.generation.uppercased(); invalid.append(fields)
        fields = f.dto(); fields["state"] = "stopped"; invalid.append(fields)
        fields = f.dto(); fields["durationMs"] = 999; invalid.append(fields)
        fields = f.dto(); fields["durationMs"] = "1000"; invalid.append(fields)
        fields = f.dto(); fields["remainingMs"] = 1001; invalid.append(fields)
        fields = f.dto(); fields["remainingMs"] = 0.5; invalid.append(fields)
        fields = f.dto(state: "completed"); fields["remainingMs"] = 1; invalid.append(fields)
        try f.run("globalThis.errors=[];globalThis.resolved=0;globalThis.unsafe=0;")
        for value in invalid {
            let index = try f.requestCount()
            try f.run("island.countdown.get('focus').then(()=>resolved++,error=>errors.push(error.code));")
            try f.reply(index, body: success(value))
            try f.reply(index, body: success(f.dto()))
        }
        let nonString = try f.requestCount()
        try f.run("island.countdown.get('focus').then(()=>resolved++,error=>errors.push(error.code));")
        let id = try f.request(nonString).id
        try f.run("sdkReceivers.receiveResponse(\(id),{toString(){unsafe++;return '{}';}});")
        try f.reply(nonString, body: success(f.dto()))
        let nonNullStop = try f.requestCount()
        try f.run("island.countdown.stop({id:'focus',generation:'\(CountdownSDKFixture.generation)'}).then(()=>resolved++,error=>errors.push(error.code));")
        try f.reply(nonNullStop, body: success(f.dto()))
        let nullStart = try f.requestCount()
        try f.run("island.countdown.start({id:'focus',durationMs:1000,activation:'ticket'}).then(()=>resolved++,error=>errors.push(error.code));")
        try f.reply(nullStart, body: #"{"ok":true,"value":null}"#)
        let invalidError = try f.requestCount()
        try f.run("island.countdown.get('focus').then(()=>resolved++,error=>errors.push(error.code));")
        try f.reply(invalidError, body: #"{"ok":false,"error":{"code":{"toString":"secret"},"message":"private"}}"#)
        let oversized = try f.requestCount()
        try f.run("island.countdown.get('focus').then(()=>resolved++,error=>errors.push(error.code));")
        fields = f.dto(); fields["id"] = String(repeating: "x", count: 4_097)
        try f.reply(oversized, body: success(fields))
        try await settled(f, "errors.length===\(invalid.count + 5)")
        XCTAssertTrue(try f.boolean("resolved===0 && unsafe===0 && errors.slice(0,-1).every(code=>code==='invalidResponse') && errors[errors.length-1]==='quotaExceeded'"))
    }

    func testCompletionRejectsMalformedOrStaleEventsAndOffCompleteClosesDeliveryImmediately() async throws {
        let f = try CountdownSDKFixture()
        try f.run("globalThis.calls=[];globalThis.unsafe=0;island.countdown.onComplete(event=>calls.push(['first',Object.isFrozen(event),Object.getPrototypeOf(event)===null])).catch(()=>{});")
        let first = try f.registration(0)
        try f.reply(0, body: #"{"ok":true,"value":null}"#)
        try f.completion("stale", body: f.dto(state: "completed"))
        try f.completion(first, body: f.dto(state: "running"))
        var malformed = f.dto(state: "completed"); malformed["remainingMs"] = 1
        try f.completion(first, body: malformed)
        malformed = f.dto(state: "completed"); malformed["activation"] = "forged"
        try f.completion(first, body: malformed)
        try f.run("sdkReceivers.receiveCountdown('\(first)',{toString(){unsafe++;return '{}';}});")
        XCTAssertTrue(try f.boolean("calls.length===0 && unsafe===0"))
        try f.completion(first, body: f.dto(state: "completed"))
        try f.run("island.countdown.onComplete(()=>calls.push(['second',true,true])).catch(()=>{});")
        let second = try f.registration(1)
        try f.reply(1, body: #"{"ok":true,"value":null}"#)
        try f.completion(first, body: f.dto(state: "completed"))
        try f.completion(second, body: f.dto(state: "completed"))
        try f.run("island.countdown.offComplete().catch(()=>{});")
        try f.completion(second, body: f.dto(state: "completed"))
        XCTAssertTrue(try f.boolean("calls.length===2 && calls[0][0]==='first' && calls[1][0]==='second' && calls.every(row=>row[1]&&row[2])"))
    }

    func testOutOfOrderFailedRegistrationsRestoreTheLastSuccessfulHandler() async throws {
        let f = try CountdownSDKFixture()
        try f.run("globalThis.calls=[];globalThis.errors=[];island.countdown.onComplete(()=>calls.push('first')).then(()=>{globalThis.firstReady=true;}).catch(error=>errors.push(error.code));")
        let first = try f.registration(0)
        try f.reply(0, body: #"{"ok":true,"value":null}"#)
        try await settled(f, "globalThis.firstReady===true")
        try f.run("""
            island.countdown.onComplete(()=>calls.push('second')).catch(error=>errors.push(error.code));
            island.countdown.onComplete(()=>calls.push('third')).catch(error=>errors.push(error.code));
            """)
        let second = try f.registration(1), third = try f.registration(2)
        try f.reply(1, body: #"{"ok":false,"error":{"code":"quotaExceeded","message":"Fixed failure"}}"#)
        try f.reply(2, body: #"{"ok":false,"error":{"code":"quotaExceeded","message":"Fixed failure"}}"#)
        try await settled(f, "errors.length===2")
        try f.completion(second, body: f.dto(state: "completed"))
        try f.completion(third, body: f.dto(state: "completed"))
        try f.completion(first, body: f.dto(state: "completed"))
        XCTAssertTrue(try f.boolean("calls.length===1 && calls[0]==='first'"))
    }

    func testHandlerFailuresDoNotInspectSecretsAndUnbrandedThenablesReleaseCallbackCapacity() async throws {
        let f = try CountdownSDKFixture()
        try f.run("""
            globalThis.unsafe=0;globalThis.calls=0;
            const secret={get message(){unsafe++;return 'secret';},get stack(){unsafe++;return 'secret';},toString(){unsafe++;return 'secret';}};
            island.countdown.onComplete(()=>{throw secret;}).catch(()=>{});
            """)
        var registration = try f.registration(0)
        try f.reply(0, body: #"{"ok":true,"value":null}"#)
        try f.completion(registration, body: f.dto(state: "completed"))
        try await settled(f, "sdkRequests.some(row=>JSON.parse(row.json).method==='countdown.failure')")
        var index = try f.requestCount()
        try f.run("island.countdown.onComplete(()=>Promise.reject(secret)).catch(()=>{});")
        registration = try f.registration(index)
        try f.reply(index, body: #"{"ok":true,"value":null}"#)
        try f.completion(registration, body: f.dto(state: "completed"))
        try await settled(f, "sdkRequests.filter(row=>JSON.parse(row.json).method==='countdown.failure').length===2")
        index = try f.requestCount()
        try f.run("""
            const thenable={get then(){unsafe++;throw 'secret';},get constructor(){unsafe++;throw 'secret';}};
            island.countdown.onComplete(()=>{calls++;return thenable;}).catch(()=>{});
            """)
        registration = try f.registration(index)
        try f.reply(index, body: #"{"ok":true,"value":null}"#)
        for _ in 0..<70 {
            var value = f.dto(state: "completed")
            value["generation"] = UUID().uuidString.lowercased()
            try f.completion(registration, body: value)
        }
        XCTAssertTrue(try f.boolean("calls===70 && unsafe===0"))
        let count = try f.requestCount()
        let failures = try (0..<count).map { try f.request($0) }.filter { $0.method == "countdown.failure" }
        XCTAssertEqual(failures.map(\.params), [.object(["kind": .string("exception")]), .object(["kind": .string("rejection")])])
        XCTAssertTrue(try f.boolean("sdkRequests.every(row=>!row.json.includes('secret'))"))
    }

    private func settled(_ fixture: CountdownSDKFixture, _ condition: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if try fixture.boolean(condition) { return }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Countdown SDK promise did not settle", file: file, line: line)
        throw CountdownSDKTestError.unsettled
    }

    private func success(_ fields: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "value": fields], options: [.sortedKeys]), as: UTF8.self)
    }
}

private enum CountdownSDKTestError: Error { case invalidWire, javaScriptFailure, unsettled }

@MainActor
private final class CountdownSDKFixture {
    static let generation = "12345678-1234-1234-1234-123456789abc"
    let context: JSContext
    let receivers: JSValue

    struct Request { let id: Int; let method: String; let params: PluginBridgeJSON }

    init() throws {
        let context = try XCTUnwrap(JSContext())
        self.context = context
        _ = context.evaluateScript("globalThis.sdkRequests=[];globalThis.sdkNative=function(id,json){sdkRequests.push({id,json});};")
        receivers = try XCTUnwrap(context.evaluateScript(PluginJSBridgeBootstrap.script(
            metadataJSON: #"{"apiVersion":"1.0.0","plugin":{"id":"com.example.countdown-sdk","name":"Countdown SDK","version":"1.0.0"}}"#,
            nativeKey: "sdkNative"
        )))
        XCTAssertNil(context.exception)
        context.setObject(receivers, forKeyedSubscript: "sdkReceivers" as NSString)
    }

    func run(_ script: String) throws {
        _ = context.evaluateScript(script)
        if context.exception != nil { throw CountdownSDKTestError.javaScriptFailure }
    }

    func boolean(_ expression: String) throws -> Bool {
        let value = context.evaluateScript(expression)
        guard context.exception == nil, let value, value.isBoolean else { throw CountdownSDKTestError.javaScriptFailure }
        return value.toBool()
    }

    func requestCount() throws -> Int {
        let value = context.evaluateScript("sdkRequests.length")
        guard context.exception == nil, let value, value.isNumber else { throw CountdownSDKTestError.invalidWire }
        return Int(value.toInt32())
    }

    func request(_ index: Int) throws -> Request {
        let id = context.evaluateScript("sdkRequests[\(index)].id")
        let wire = context.evaluateScript("sdkRequests[\(index)].json")
        guard context.exception == nil, let id, id.isNumber, let wire, wire.isString,
              let json = wire.toString(), case .object(let fields) = try PluginBridgeJSON.parse(json),
              case .string(let method) = fields["method"], let params = fields["params"] else {
            throw CountdownSDKTestError.invalidWire
        }
        return Request(id: Int(id.toInt32()), method: method, params: params)
    }

    func registration(_ index: Int) throws -> String {
        guard case .object(let fields) = try request(index).params,
              case .string(let registration) = fields["registrationID"] else { throw CountdownSDKTestError.invalidWire }
        return registration
    }

    func reply(_ index: Int, body: String) throws {
        let id = try request(index).id
        _ = receivers.objectForKeyedSubscript("receiveResponse")?.call(withArguments: [id, body])
        if context.exception != nil { throw CountdownSDKTestError.javaScriptFailure }
    }

    func completion(_ registration: String, body: [String: Any]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        _ = receivers.objectForKeyedSubscript("receiveCountdown")?.call(withArguments: [registration, json])
        if context.exception != nil { throw CountdownSDKTestError.javaScriptFailure }
    }

    func dto(state: String = "running") -> [String: Any] {
        ["id": "focus", "generation": Self.generation, "state": state,
         "durationMs": 1_000, "remainingMs": state == "completed" ? 0 : 1_000]
    }
}
