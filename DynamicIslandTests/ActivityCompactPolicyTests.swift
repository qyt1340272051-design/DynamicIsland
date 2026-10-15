import Foundation
import JavaScriptCore
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityCompactPolicyTests: XCTestCase {
    func testLegacyJSONAndDefaultInitializerKeepPolicyOmitted() throws {
        for json in [#"{"title":"Legacy"}"#, #"{"title":"Legacy","role":"status"}"#,
                     #"{"title":"Legacy","role":"tool","showsCompact":false}"#] {
            let presentation = try JSONDecoder().decode(ActivityPresentation.self, from: Data(json.utf8))
            XCTAssertNil(presentation.compactPolicy)
            XCTAssertEqual(presentation.effectiveCompactPolicy, .selectedOnly)
            let encoded = try JSONEncoder().encode(presentation)
            XCTAssertEqual(try PluginBridgeJSON.parse(String(decoding: encoded, as: UTF8.self)),
                           try PluginBridgeJSON.parse(json))
        }
        let presentation = ActivityPresentation(title: "Default")
        XCTAssertNil(presentation.compactPolicy)
        XCTAssertEqual(presentation.effectiveCompactPolicy, .selectedOnly)
        XCTAssertTrue(presentation.isCompactVisible)
    }

    func testExplicitPoliciesRoundTripWithoutChangingCompactVisibility() throws {
        for policy in [ActivityPresentation.CompactPolicy.selectedOnly, .automatic] {
            for showsCompact in [nil, true, false] as [Bool?] {
                let presentation = ActivityPresentation(title: "Tool", showsCompact: showsCompact,
                                                        role: .tool, compactPolicy: policy)
                XCTAssertEqual(presentation.effectiveCompactPolicy, policy)
                XCTAssertEqual(presentation.isCompactVisible, showsCompact ?? true)
                let encoded = try JSONEncoder().encode(presentation)
                XCTAssertEqual(try JSONDecoder().decode(ActivityPresentation.self, from: encoded), presentation)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertEqual(fields["compactPolicy"] as? String, policy.rawValue)
                XCTAssertEqual(fields["showsCompact"] as? Bool, showsCompact)
            }
        }
    }

    func testCoreDecoderRejectsUnknownOrNonStringPolicyValues() {
        for raw in [#""unknown""#, #""Automatic""#, #""automatic ""#, #""""#, "false", "0", "1.5", "[]", "{}"] {
            let data = Data("{\"title\":\"Tool\",\"role\":\"tool\",\"compactPolicy\":\(raw)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(ActivityPresentation.self, from: data), raw)
        }
    }

    func testConverterAcceptsToolPoliciesAndKeepsExistingLifecyclePriorityAndVisibilityRules() throws {
        for policy in ["selectedOnly", "automatic"] {
            for lifecycle in ["persistent", "progress"] {
                for showsCompact in [nil, true, false] as [Bool?] {
                    var presentation = presentation(policy: .string(policy))
                    if let showsCompact { presentation["showsCompact"] = .boolean(showsCompact) }
                    let request = try publishRequest(presentation: presentation, lifecycle: lifecycle)
                    let activity = try materialize(request)
                    XCTAssertEqual(activity.presentation.compactPolicy?.rawValue, policy)
                    XCTAssertEqual(activity.presentation.showsCompact, showsCompact)
                    XCTAssertEqual(activity.presentation.isCompactVisible, showsCompact ?? true)
                    XCTAssertTrue(activity.isTool)
                    XCTAssertEqual(activity.lifecycle.policy.rawValue, lifecycle)
                    XCTAssertEqual(activity.priority, .background)
                }
            }
        }
        for role in [nil, "status", "tool"] as [String?] {
            let request = try publishRequest(presentation: presentation(role: role.map(PluginBridgeJSON.string)))
            XCTAssertNil(try materialize(request).presentation.compactPolicy)
        }
        for lifecycle in ["transient", "critical"] {
            let request = try publishRequest(presentation: presentation(policy: .string("automatic")), lifecycle: lifecycle)
            assertInvalid { try self.materialize(request) }
        }
    }

    func testConverterRejectsNullTypesUnknownPoliciesAndUnknownPresentationFields() throws {
        let malformed: [PluginBridgeJSON] = [.null, .boolean(false), .number(0), .number(1.5), .array([]), .object([:]),
            .string(""), .string("Automatic"), .string("automatic "), .string("unknown")]
        for policy in malformed {
            assertInvalid { try self.publishRequest(presentation: self.presentation(policy: policy)) }
        }
        var unknown = presentation(policy: .string("automatic"))
        unknown["compact-policy"] = .string("automatic")
        assertInvalid { try self.publishRequest(presentation: unknown) }
    }

    func testFinalMaterializationRejectsPolicyOnStatusAndPriorityOnlyRetainedInvalidData() throws {
        for policy in [ActivityPresentation.CompactPolicy.selectedOnly, .automatic] {
            for role in [nil, ActivityPresentation.Role.status] {
                let request = try publishRequest(presentation: presentation(role: role.map { .string($0.rawValue) },
                                                                            policy: .string(policy.rawValue)))
                assertInvalid { try self.materialize(request) }
                let retained = IslandActivity(id: namespacedID, source: source, priority: .normal,
                    lifecycle: .init(policy: .persistent),
                    presentation: .init(title: "Retained", role: role, compactPolicy: policy), createdAt: now)
                let before = retained
                let update = try PluginActivityConverter.parse(.object([
                    "id": .string("tool"), "priority": .string("background")
                ]), isUpdate: true)
                assertInvalid { try self.materialize(update, existing: retained) }
                XCTAssertEqual(retained, before)
            }
        }
    }

    func testPartialUpdatesPreserveValidPolicyAndReplacementCannotKeepPolicyWithStatusRole() throws {
        let original = try materialize(publishRequest(presentation: presentation(policy: .string("automatic"))))
        let priorityOnly = try PluginActivityConverter.parse(.object([
            "id": .string("tool"), "priority": .string("critical")
        ]), isUpdate: true)
        let preserved = try materialize(priorityOnly, existing: original)
        XCTAssertEqual(preserved.presentation, original.presentation)
        XCTAssertEqual(preserved.priority, .background)
        XCTAssertEqual(preserved.lifecycle, original.lifecycle)
        XCTAssertEqual(preserved.createdAt, original.createdAt)
        for role in [nil, "status"] as [String?] {
            let replacement = try PluginActivityConverter.parse(.object([
                "id": .string("tool"), "priority": .string("normal"),
                "presentation": .object(presentation(role: role.map(PluginBridgeJSON.string), policy: .string("selectedOnly")))
            ]), isUpdate: true)
            assertInvalid { try self.materialize(replacement, existing: original) }
        }
        let status = try PluginActivityConverter.parse(.object([
            "id": .string("tool"), "priority": .string("normal"),
            "presentation": .object(presentation(role: .string("status")))
        ]), isUpdate: true)
        let replaced = try materialize(status, existing: original)
        XCTAssertFalse(replaced.isTool)
        XCTAssertNil(replaced.presentation.compactPolicy)
        XCTAssertEqual(replaced.priority, .normal)
    }

    func testSDKForwardsBothPoliciesAndLeavesLegacyRequestsUnchanged() throws {
        let fixture = try CompactPolicySDKFixture()
        try fixture.run("""
            for (const method of ['publish','update']) {
                island.activity[method]({id:'tool',presentation:{title:'Legacy',role:'tool'}}).catch(()=>{});
                for (const policy of ['selectedOnly','automatic']) {
                    island.activity[method]({id:'tool',presentation:{title:'Tool',role:'tool',
                        compactPolicy:policy,showsCompact:false}}).catch(()=>{});
                }
            }
            """)
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 6)
        for (index, request) in requests.enumerated() {
            guard case .object(let envelope) = request, case .object(let params) = envelope["params"],
                  case .object(let presentation) = params["presentation"] else { return XCTFail("Invalid SDK request") }
            XCTAssertEqual(envelope["method"], .string(index < 3 ? "activity.publish" : "activity.update"))
            if index % 3 == 0 {
                XCTAssertEqual(presentation, ["title": .string("Legacy"), "role": .string("tool")])
            } else {
                XCTAssertEqual(presentation["compactPolicy"], .string(index % 3 == 1 ? "selectedOnly" : "automatic"))
                XCTAssertEqual(presentation["showsCompact"], .boolean(false))
            }
        }
    }

    func testSDKRejectsMalformedPoliciesRoleMismatchAndGettersBeforeNativeDispatch() async throws {
        let fixture = try CompactPolicySDKFixture()
        try fixture.run("""
            globalThis.codes=[];globalThis.unsafe=0;
            const invalid=[];
            for (const compactPolicy of [undefined,null,false,0,1.5,[],{},'','Automatic','automatic ','unknown'])
                invalid.push({title:'Invalid',role:'tool',compactPolicy});
            for (const compactPolicy of ['selectedOnly','automatic']) {
                invalid.push({title:'Invalid',compactPolicy});
                invalid.push({title:'Invalid',role:'status',compactPolicy});
            }
            invalid.push({title:'Invalid',role:'tool',compactPolicy:'automatic',compact_policy:'automatic'});
            const policyGetter={title:'Getter',role:'tool'};
            Object.defineProperty(policyGetter,'compactPolicy',{enumerable:true,get(){unsafe++;return 'automatic';}});
            invalid.push(policyGetter);
            const roleGetter={title:'Getter',compactPolicy:'automatic'};
            Object.defineProperty(roleGetter,'role',{enumerable:true,get(){unsafe++;return 'tool';}});invalid.push(roleGetter);
            invalid.push({title:'Coercion',role:'tool',compactPolicy:{toString(){unsafe++;return 'automatic';}}});
            globalThis.expected=invalid.length*2;
            for (const presentation of invalid) for (const method of ['publish','update'])
                island.activity[method]({id:'tool',presentation}).then(()=>codes.push('accepted'),error=>codes.push(error.code));
            """)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try !fixture.boolean("codes.length===expected"), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(try fixture.boolean("codes.length===expected && codes.every(code=>code==='invalidArguments') && unsafe===0"))
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testSDKReadsMutableProxyPresentationOnceWithoutInvokingGetTrap() throws {
        let fixture = try CompactPolicySDKFixture()
        try fixture.run("""
            globalThis.reads={title:0,role:0,compactPolicy:0,showsCompact:0};globalThis.unsafe=0;
            const target={title:'Tool',role:'tool',compactPolicy:'automatic',showsCompact:false};
            const presentation=new Proxy(target,{
                get(){unsafe++;throw 'get';},
                getOwnPropertyDescriptor(object,key){
                    reads[key]++;return {value:reads[key]===1?object[key]:'changed',enumerable:true,configurable:true,writable:true};
                }
            });
            island.activity.publish({id:'tool',presentation}).catch(()=>{});
            target.compactPolicy='selectedOnly';target.role='status';target.showsCompact=true;
            """)
        XCTAssertTrue(try fixture.boolean("unsafe===0 && Object.values(reads).every(count=>count===1)"))
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 1)
        guard case .object(let envelope) = try XCTUnwrap(requests.first),
              case .object(let params) = envelope["params"] else { return XCTFail("Proxy request missing") }
        XCTAssertEqual(params["presentation"], .object([
            "title": .string("Tool"), "role": .string("tool"),
            "compactPolicy": .string("automatic"), "showsCompact": .boolean(false)
        ]))
    }

    private let source = ActivitySource(kind: .plugin, identifier: "com.example.compact-policy")
    private let namespacedID = "plugin:com.example.compact-policy:tool"
    private let now = Date(timeIntervalSinceReferenceDate: 111_000)

    private func presentation(role: PluginBridgeJSON? = .string("tool"), policy: PluginBridgeJSON? = nil) -> [String: PluginBridgeJSON] {
        var fields: [String: PluginBridgeJSON] = ["title": .string("Tool")]
        if let role { fields["role"] = role }
        if let policy { fields["compactPolicy"] = policy }
        return fields
    }

    private func publishRequest(presentation: [String: PluginBridgeJSON], lifecycle: String = "persistent") throws -> PluginActivityConverter.Request {
        try PluginActivityConverter.parse(.object([
            "id": .string("tool"), "priority": .string("critical"),
            "lifecycle": .object(["policy": .string(lifecycle)]), "presentation": .object(presentation)
        ]), isUpdate: false)
    }

    private func materialize(_ request: PluginActivityConverter.Request, existing: IslandActivity? = nil) throws -> IslandActivity {
        try request.materialize(source: source, namespacedID: namespacedID, now: now, existing: existing)
    }

    private func assertInvalid<T>(_ operation: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .invalidArguments, file: file, line: line)
        }
    }
}

private enum CompactPolicySDKError: Error { case invalidWire, javaScriptFailure }

@MainActor
private final class CompactPolicySDKFixture {
    private let context: JSContext

    init() throws {
        context = try XCTUnwrap(JSContext())
        _ = context.evaluateScript("globalThis.policyRequests=[];globalThis.policyNative=function(id,json){policyRequests.push(json);};")
        _ = context.evaluateScript(PluginJSBridgeBootstrap.script(
            metadataJSON: #"{"apiVersion":"1.0.0","plugin":{"id":"com.example.compact-policy-sdk","name":"Compact Policy SDK","version":"1.0.0"}}"#,
            nativeKey: "policyNative"))
        guard context.exception == nil else { throw CompactPolicySDKError.javaScriptFailure }
    }

    func run(_ script: String) throws {
        _ = context.evaluateScript(script)
        guard context.exception == nil else { throw CompactPolicySDKError.javaScriptFailure }
    }

    func boolean(_ expression: String) throws -> Bool {
        let value = context.evaluateScript(expression)
        guard context.exception == nil, let value, value.isBoolean else { throw CompactPolicySDKError.javaScriptFailure }
        return value.toBool()
    }

    func requests() throws -> [PluginBridgeJSON] {
        let result = context.evaluateScript("JSON.stringify(policyRequests)")
        guard context.exception == nil, let result, result.isString, let wire = result.toString(),
              case .array(let values) = try PluginBridgeJSON.parse(wire) else { throw CompactPolicySDKError.invalidWire }
        return try values.map {
            guard case .string(let request) = $0 else { throw CompactPolicySDKError.invalidWire }
            return try PluginBridgeJSON.parse(request)
        }
    }
}
