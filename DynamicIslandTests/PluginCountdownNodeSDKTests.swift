import Foundation
import JavaScriptCore
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownNodeSDKTests: XCTestCase {
    func testValidCountdownLeavesReachNativeInEveryLayoutAndBothActivityMethods() throws {
        let fixture = try CountdownNodeSDKFixture()
        try fixture.run("""
            const g='\(CountdownNodeSDKFixture.generation)';
            const layouts=['minimal','compact','expanded'];
            const methods=['publish','update'];
            const styles=[undefined,'time','progress'];
            for (const layout of layouts) for (const method of methods) for (const style of styles) {
                const node={type:'countdown',id:'focus-1._',generation:g};
                if (style!==undefined) node.style=style;
                const presentation={title:'Countdown'};presentation[layout]=node;
                island.activity[method]({id:'tool',presentation}).catch(()=>{});
            }
            for (const color of ['primary','secondary','accent','success','warning','danger']) {
                island.activity.publish({id:'tool',presentation:{title:'Color',expanded:{
                    type:'countdown',id:'x'.repeat(80),generation:g,style:'progress',color
                }}}).catch(()=>{});
            }
            """)
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 24)
        for (index, request) in requests.prefix(18).enumerated() {
            guard case .object(let envelope) = request,
                  case .object(let params) = envelope["params"],
                  case .object(let presentation) = params["presentation"],
                  case .object(let node) = presentation[["minimal", "compact", "expanded"][index / 6]] else {
                return XCTFail("Countdown layout must remain a data-only request.")
            }
            XCTAssertEqual(envelope["method"], .string(index % 6 < 3 ? "activity.publish" : "activity.update"))
            XCTAssertEqual(node["id"], .string("focus-1._"))
            XCTAssertEqual(node["generation"], .string(CountdownNodeSDKFixture.generation))
            XCTAssertEqual(node["style"], [nil, .string("time"), .string("progress")][index % 3])
            XCTAssertEqual(Set(node.keys), index % 3 == 0
                ? Set(["type", "id", "generation"]) : Set(["type", "id", "generation", "style"]))
        }
        for (request, color) in zip(requests.suffix(6), IslandSemanticColorToken.allCases) {
            guard case .object(let envelope) = request,
                  case .object(let params) = envelope["params"],
                  case .object(let presentation) = params["presentation"],
                  case .object(let node) = presentation["expanded"] else {
                return XCTFail("Countdown colors must remain semantic tokens.")
            }
            XCTAssertEqual(node["color"], .string(color.rawValue))
            XCTAssertEqual(node["id"], .string(String(repeating: "x", count: 80)))
        }
    }

    func testMalformedCountdownFieldsRejectBeforeNativeDispatchAtEveryStructuralEdge() async throws {
        let fixture = try CountdownNodeSDKFixture()
        try fixture.run("""
            const g='\(CountdownNodeSDKFixture.generation)';
            const base={type:'countdown',id:'focus',generation:g};
            const invalid=[];
            for (const key of ['id','generation']) {const node={...base};delete node[key];invalid.push(node);}
            for (const id of ['', 'x'.repeat(81),'timer:focus','../focus','focus/path','focus\\\\path','focus name','计时',0,null])
                invalid.push({...base,id});
            for (const generation of [null,0,'',g.toUpperCase(),'12345678123412341234123456789abc',
                '12345678-1234-1234-1234-123456789abg','12345678-1234-1234-1234-123456789abc '])
                invalid.push({...base,generation});
            for (const style of [null,0,true,'','Time','ring',{},[]]) invalid.push({...base,style});
            for (const color of [null,0,false,'','Primary','#00ff00',{},[]]) invalid.push({...base,color});
            for (const key of ['deadline','duration','durationMs','remainingMs','activation','owner','token','children','label'])
                invalid.push({...base,[key]:'forbidden'});
            globalThis.codes=[];globalThis.expected=invalid.length*6;
            for (const node of invalid) for (const method of ['publish','update']) {
                const layouts=[{minimal:node},
                    {compact:{type:'hStack',children:[{type:'vStack',children:[node]}]}},
                    {expanded:{type:'zStack',children:[{type:'button',actionID:'start',label:node}]}}];
                for (const layout of layouts) island.activity[method]({id:'tool',presentation:{title:'Invalid',...layout}})
                    .then(()=>codes.push('accepted'),error=>codes.push(error.code));
            }
            """)
        try await settled(fixture, "codes.length===expected")
        XCTAssertTrue(try fixture.boolean("codes.every(code=>code==='invalidArguments')"))
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testAccessorFieldsAreRejectedWithoutCallingGettersOrCoercion() async throws {
        let fixture = try CountdownNodeSDKFixture()
        try fixture.run("""
            globalThis.unsafe=0;globalThis.codes=[];
            const g='\(CountdownNodeSDKFixture.generation)';
            const nodes=[];
            for (const key of ['type','id','generation','style','color','deadline']) {
                const node={type:'countdown',id:'focus',generation:g};
                Object.defineProperty(node,key,{enumerable:true,get(){unsafe++;return 'secret';}});
                nodes.push(node);
            }
            const stack={type:'hStack'};
            Object.defineProperty(stack,'children',{enumerable:true,get(){unsafe++;return [];}});nodes.push(stack);
            const button={type:'button',actionID:'start'};
            Object.defineProperty(button,'label',{enumerable:true,get(){unsafe++;return nodes[0];}});nodes.push(button);
            nodes.push({type:'countdown',id:'focus',generation:{toString(){unsafe++;return g;}}});
            const inherited=Object.create({type:'countdown',id:'focus',generation:g});nodes.push(inherited);
            const hidden={type:'countdown',id:'focus',generation:g};
            Object.defineProperty(hidden,'owner',{value:'forbidden'});nodes.push(hidden);
            const symbol={type:'countdown',id:'focus',generation:g};symbol[Symbol('owner')]='forbidden';nodes.push(symbol);
            globalThis.expected=nodes.length;
            for (const node of nodes) island.activity.publish({id:'tool',presentation:{title:'Invalid',expanded:node}})
                .then(()=>codes.push('accepted'),error=>codes.push(error.code));
            """)
        try await settled(fixture, "codes.length===expected")
        XCTAssertTrue(try fixture.boolean("unsafe===0 && codes.every(code=>code==='invalidArguments')"))
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testChangingProxyDescriptorsAreReadOnceAndTraversalDoesNotUseArrayIterator() throws {
        let fixture = try CountdownNodeSDKFixture()
        try fixture.run("""
            globalThis.reads={type:0,id:0,generation:0,style:0,color:0};globalThis.unsafe=0;
            const target={type:'countdown',id:'focus',generation:'\(CountdownNodeSDKFixture.generation)',style:'time',color:'accent'};
            const node=new Proxy(target,{
                get(){unsafe++;throw 'get trap';},
                getOwnPropertyDescriptor(object,key){
                    reads[key]++;
                    return {value:reads[key]===1?object[key]:'changed',enumerable:true,configurable:true,writable:true};
                }
            });
            const presentation={title:'Safe',minimal:{type:'hStack',children:[{type:'vStack',children:[
                {type:'zStack',children:[{type:'button',actionID:'start',label:node}]}
            ]}]}};
            const iterator=Object.getOwnPropertyDescriptor(Array.prototype,Symbol.iterator);
            Object.defineProperty(Array.prototype,Symbol.iterator,{configurable:true,get(){unsafe++;throw 'iterator';}});
            island.activity.publish({id:'tool',presentation}).catch(()=>{});
            Object.defineProperty(Array.prototype,Symbol.iterator,iterator);
            target.id='mutated';target.generation='invalid';
            """)
        XCTAssertTrue(try fixture.boolean("unsafe===0 && Object.values(reads).every(count=>count===1)"))
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 1)
        let encoded = try XCTUnwrap(requests.first).encodedString()
        XCTAssertTrue(encoded.contains("\"id\":\"focus\""))
        XCTAssertTrue(encoded.contains(CountdownNodeSDKFixture.generation))
        XCTAssertFalse(encoded.contains("changed"))
        XCTAssertFalse(encoded.contains("mutated"))
    }

    func testLegacyNodesAndHostValidationRemainCompatible() throws {
        let fixture = try CountdownNodeSDKFixture()
        try fixture.run("""
            const legacy=[{type:'text',content:'Text',color:'primary'}, {type:'icon',symbolName:'clock'},
                {type:'image',source:{type:'systemSymbol',name:'clock'},size:'icon'},
                {type:'hStack',children:[]},{type:'vStack',children:[]},{type:'zStack',children:[]},
                {type:'spacer'},{type:'divider'},{type:'progress',value:0.5,style:'linear',color:'accent'},
                {type:'button',actionID:'start',label:{type:'text',content:'Start'}},
                {type:'toggle',title:'Toggle',isOn:false,actionID:'toggle'},
                {type:'slider',title:'Slider',value:0.5,actionID:'slide'}];
            globalThis.expectedPresentation={title:'Legacy',expanded:{type:'vStack',children:legacy}};
            island.activity.publish({id:'legacy',presentation:expectedPresentation}).catch(()=>{});
            island.activity.update({id:'legacy',actions:[]}).catch(()=>{});
            // A malformed legacy leaf still reaches independent Host validation;
            // countdown checks do not recursively interpret arbitrary fields.
            island.activity.update({id:'legacy',presentation:{title:'Host validation',expanded:{
                type:'text',content:{type:'countdown',id:'bad:id',generation:'invalid'}
            }}}).catch(()=>{});
            """)
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 3)
        guard case .object(let request) = requests[0], case .object(let params) = request["params"] else {
            return XCTFail("Legacy Activity must remain a data-only request.")
        }
        XCTAssertEqual(params["presentation"], try fixture.json("JSON.stringify(expectedPresentation)"))
        guard case .object(let update) = requests[1] else { return XCTFail("Update request missing.") }
        XCTAssertEqual(update["params"], .object(["id": .string("legacy"), "actions": .array([])]))
    }

    private func settled(_ fixture: CountdownNodeSDKFixture, _ condition: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if try fixture.boolean(condition) { return }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTFail("Countdown node SDK rejection did not settle.")
        throw CountdownNodeSDKError.javaScriptFailure
    }
}

private enum CountdownNodeSDKError: Error { case invalidWire, javaScriptFailure }

@MainActor
private final class CountdownNodeSDKFixture {
    static let generation = "12345678-1234-1234-1234-123456789abc"
    private let context: JSContext

    init() throws {
        context = try XCTUnwrap(JSContext())
        _ = context.evaluateScript("globalThis.nodeRequests=[];globalThis.nodeNative=function(id,json){nodeRequests.push(json);};")
        _ = context.evaluateScript(PluginJSBridgeBootstrap.script(
            metadataJSON: #"{"apiVersion":"1.0.0","plugin":{"id":"com.example.countdown-node-sdk","name":"Countdown Node SDK","version":"1.0.0"}}"#,
            nativeKey: "nodeNative"))
        guard context.exception == nil else { throw CountdownNodeSDKError.javaScriptFailure }
    }

    func run(_ script: String) throws {
        _ = context.evaluateScript(script)
        guard context.exception == nil else { throw CountdownNodeSDKError.javaScriptFailure }
    }

    func boolean(_ expression: String) throws -> Bool {
        let value = context.evaluateScript(expression)
        guard context.exception == nil, let value, value.isBoolean else { throw CountdownNodeSDKError.javaScriptFailure }
        return value.toBool()
    }

    func json(_ expression: String) throws -> PluginBridgeJSON {
        let value = context.evaluateScript(expression)
        guard context.exception == nil, let value, value.isString, let wire = value.toString() else {
            throw CountdownNodeSDKError.invalidWire
        }
        return try PluginBridgeJSON.parse(wire)
    }

    func requests() throws -> [PluginBridgeJSON] {
        guard case .array(let values) = try json("JSON.stringify(nodeRequests)") else {
            throw CountdownNodeSDKError.invalidWire
        }
        return try values.map { value in
            guard case .string(let wire) = value else { throw CountdownNodeSDKError.invalidWire }
            return try PluginBridgeJSON.parse(wire)
        }
    }
}
