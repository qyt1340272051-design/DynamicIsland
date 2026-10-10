import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginIslandNodeBridgeTests: XCTestCase {
    func testAllTwelveKindsConvertWithDocumentedDefaults() throws {
        let samples: [([String: Any], IslandNode)] = [
            (["type": "text", "content": "Hello"], .text(.init("Hello"))),
            (["type": "icon", "symbolName": "music.note"], .icon(.init("music.note"))),
            (["type": "image", "source": ["type": "systemSymbol", "name": "play.fill"]],
             .image(.init(source: .systemSymbol(name: "play.fill")))),
            (["type": "hStack", "children": []], .hStack(.init([]))),
            (["type": "vStack", "children": []], .vStack(.init([]))),
            (["type": "zStack", "children": []], .zStack(.init([]))),
            (["type": "spacer"], .spacer(.init())),
            (["type": "divider"], .divider(.init())),
            (["type": "progress", "value": 0.5], .progress(.init(0.5))),
            (["type": "button", "actionID": "open", "label": ["type": "text", "content": "Open"]],
             .button(.init(actionID: "open", label: .text(.init("Open"))))),
            (["type": "toggle", "title": "Loop", "isOn": true, "actionID": "loop"],
             .toggle(.init(title: "Loop", isOn: true, actionID: "loop"))),
            (["type": "slider", "title": "Volume", "value": 0.25, "actionID": "volume"],
             .slider(.init(title: "Volume", value: 0.25, actionID: "volume")))
        ]
        XCTAssertEqual(samples.count, 12)
        for (value, expected) in samples {
            XCTAssertEqual(try parse(value), expected)
            var unknown = value
            unknown["width"] = 100
            assertInvalid(try json(unknown))
        }
    }

    func testFiniteAppearanceTokensAndOptionalValuesAreStrict() throws {
        for color in IslandSemanticColorToken.allCases {
            XCTAssertEqual(try parse(["type": "text", "content": "", "color": color.rawValue]), .text(.init("", color: color)))
        }
        for size in IslandImageSizeToken.allCases {
            XCTAssertEqual(try parse(["type": "image", "source": ["type": "pluginAsset", "id": "cover"], "size": size.rawValue]),
                           .image(.init(source: .pluginAsset(id: "cover"), size: size)))
        }
        for style in IslandProgressStyleToken.allCases {
            XCTAssertEqual(try parse(["type": "progress", "value": 1, "style": style.rawValue, "color": "success"]),
                           .progress(.init(1, style: style, color: .success)))
        }
        XCTAssertEqual(try parse(["type": "slider", "title": "", "value": 0, "actionID": "seek", "showsTitle": false]),
                       .slider(.init(title: "", value: 0, actionID: "seek", showsTitle: false)))
        XCTAssertEqual(try parse(["type": "button", "actionID": "open", "label": ["type": "icon", "symbolName": "arrow.right"], "accessibilityLabel": ""]),
                       .button(.init(actionID: "open", label: .icon(.init("arrow.right")), accessibilityLabel: "")))
        let malformedValues: [[String: Any]] = [
            ["type": "text", "content": "Text", "color": "#ffffff"],
            ["type": "progress", "value": 0.5, "style": "custom"],
            ["type": "image", "source": ["type": "pluginAsset", "id": "cover"], "size": 100],
            ["type": "slider", "title": "Seek", "value": 0.5, "actionID": "seek", "showsTitle": "false"],
            ["type": "text", "content": "Text", "color": NSNull()],
            ["type": "progress", "value": 0.5, "style": NSNull()],
            ["type": "image", "source": ["type": "pluginAsset", "id": "cover"], "size": NSNull()],
            ["type": "button", "actionID": "open", "label": ["type": "text", "content": "Open"], "accessibilityLabel": NSNull()]
        ]
        for malformed in malformedValues { assertInvalid(try json(malformed)) }
    }

    func testUnknownKindsNativeFieldsAndMalformedShapesAreRejected() throws {
        let malformed: [Any] = [
            NSNull(), [], "Text", ["content": "Missing type"], ["type": "NSView"],
            ["type": "text", "content": "Text", "swiftClass": "NSView"],
            ["type": "text", "content": "Text", "selector": "performSelector:"],
            ["type": "text", "content": "Text", "frame": ["width": 100]],
            ["type": "icon", "symbolName": "star", "color": "accent"],
            ["type": "text", "content": true], ["type": "text"],
            ["type": "hStack", "children": NSNull()], ["type": "vStack", "children": [:]],
            ["type": "zStack", "children": [NSNull()]],
            ["type": "toggle", "title": "Toggle", "isOn": 1, "actionID": "toggle"],
            ["type": "slider", "title": "Slider", "value": true, "actionID": "slider"],
            ["type": "button", "actionID": "open", "label": []],
            ["type": "image", "source": ["type": "systemSymbol", "name": "star", "id": "extra"]],
            ["type": "image", "source": ["type": "pluginAsset", "id": "cover", "name": "extra"]],
            ["type": "image", "source": ["type": "url", "url": "https://example.com/cover.png"]]
        ]
        for value in malformed { assertInvalid(try json(value)) }
        for number in [-0.01, 1.01, Double.nan, Double.infinity, -Double.infinity] {
            assertInvalid(.object(["type": .string("progress"), "value": .number(number)]))
            assertInvalid(.object(["type": .string("slider"), "title": .string("Seek"), "actionID": .string("seek"), "value": .number(number)]))
        }
    }

    func testTreeDepthChildrenAndTotalNodeBoundariesCountNodeEdgesOnly() throws {
        let image: [String: Any] = ["type": "image", "source": ["type": "brokerResource", "id": "cover"], "size": "artwork"]
        _ = try parse(nested(image, depth: 8))
        assertQuota(try json(nested(image, depth: 9)))
        var button: [String: Any] = ["type": "text", "content": "Leaf"]
        for _ in 1..<8 { button = ["type": "button", "actionID": "open", "label": button] }
        _ = try parse(button)
        assertQuota(try json(["type": "button", "actionID": "open", "label": button]))
        _ = try parse(["type": "hStack", "children": Array(repeating: ["type": "spacer"], count: 16)])
        assertQuota(try json(["type": "hStack", "children": Array(repeating: ["type": "spacer"], count: 17)]))
        _ = try parse(countedTree(nodeCount: 128))
        assertQuota(try json(countedTree(nodeCount: 129)))
    }

    func testTextIdentifierAndActionUTF8Boundaries() throws {
        let exactText = String(repeating: "汉", count: 85) + "x"
        XCTAssertEqual(exactText.utf8.count, 256)
        _ = try parse(["type": "text", "content": exactText])
        _ = try parse(["type": "toggle", "title": exactText, "isOn": false, "actionID": "toggle"])
        _ = try parse(["type": "button", "actionID": "open", "label": ["type": "spacer"], "accessibilityLabel": exactText])
        let oversized: [[String: Any]] = [
            ["type": "text", "content": exactText + "y"],
            ["type": "toggle", "title": exactText + "y", "isOn": false, "actionID": "toggle"],
            ["type": "slider", "title": exactText + "y", "value": 0.5, "actionID": "seek"],
            ["type": "button", "actionID": "open", "label": ["type": "spacer"], "accessibilityLabel": exactText + "y"]
        ]
        for value in oversized { assertQuota(try json(value)) }
        for kind in ["pluginAsset", "brokerResource"] {
            _ = try parse(["type": "image", "source": ["type": kind, "id": String(repeating: "a", count: 128)]])
            assertQuota(try json(["type": "image", "source": ["type": kind, "id": String(repeating: "a", count: 129)]]))
        }
        _ = try parse(["type": "icon", "symbolName": String(repeating: "a", count: 128)])
        assertQuota(try json(["type": "icon", "symbolName": String(repeating: "a", count: 129)]))
        _ = try parse(["type": "toggle", "title": "", "isOn": false, "actionID": String(repeating: "a", count: 80)])
        assertQuota(try json(["type": "toggle", "title": "", "isOn": false, "actionID": String(repeating: "a", count: 81)]))
    }

    func testImageAndActionIdentifiersCannotCarryPathsURLsOrSchemes() throws {
        _ = try parse(["type": "icon", "symbolName": "symbol:variant"])
        _ = try parse(["type": "image", "source": ["type": "systemSymbol", "name": "symbol:variant"]])
        for identifier in ["", "../cover", "/tmp/cover", "file:cover", "https://example.com/cover", "data:image", "cover%2Fname", "cover name", "封面", "cover\\name"] {
            for kind in ["pluginAsset", "brokerResource"] {
                assertInvalid(try json(["type": "image", "source": ["type": kind, "id": identifier]]))
            }
            assertInvalid(try json(["type": "button", "actionID": identifier, "label": ["type": "text", "content": "Open"]]))
        }
    }

    func testActionCollectionIncludesNestedLabelsAndDeduplicatesIDs() throws {
        let tree = try parse(["type": "vStack", "children": [
            ["type": "button", "actionID": "open", "label": ["type": "hStack", "children": [
                ["type": "toggle", "title": "Loop", "isOn": true, "actionID": "loop"],
                ["type": "slider", "title": "Seek", "value": 0.2, "actionID": "seek"]
            ]]],
            ["type": "button", "actionID": "open", "label": ["type": "icon", "symbolName": "star"]]
        ]])
        XCTAssertEqual(PluginIslandNodeConverter.actionIDs(in: tree), ["open", "loop", "seek"])
    }

    func testHostPublishesAllLayoutsAndOwnsActivityIdentity() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, presentation: [
            "title": "Build", "minimal": ["type": "icon", "symbolName": "hammer"],
            "compact": ["type": "text", "content": "Building"],
            "expanded": ["type": "vStack", "children": [["type": "text", "content": "Build details"], ["type": "progress", "value": 0.5]]]
        ])
        let activity = try XCTUnwrap(fixture.activity())
        XCTAssertEqual(activity.id, "plugin:com.example.node:ui")
        XCTAssertEqual(activity.source, context.source)
        XCTAssertEqual(activity.createdAt, fixture.activityClock.now())
        XCTAssertEqual(activity.presentation.minimal, .icon(.init("hammer")))
        XCTAssertEqual(activity.presentation.compact, .text(.init("Building")))
        XCTAssertEqual(activity.presentation.expanded, .vStack(.init([.text(.init("Build details")), .progress(.init(0.5))])))
    }

    func testUILayoutCapabilityIsRequiredForEffectiveMergedPresentation() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let noUI = try package(capabilities: [.publishActivity, .updateActivity, .endActivity])
        let context = try fixture.load(noUI)
        let denied = try await request(fixture, package: noUI, context: context, params: ["id": "ui", "presentation": ["title": "Denied", "minimal": ["type": "text", "content": "Tree"]]])
        XCTAssertEqual(errorCode(denied), "capabilityRequired")
        XCTAssertNil(fixture.activity())
        try context.publish(IslandActivity(id: fixture.id(), source: context.source, priority: .normal,
            lifecycle: .init(policy: .persistent), presentation: .init(title: "Host tree", minimal: .text(.init("Tree"))), createdAt: fixture.activityClock.now()))
        let original = fixture.activity()
        let effectiveTree = try await request(fixture, package: noUI, context: context, method: "activity.update", params: ["id": "ui", "priority": "background"])
        XCTAssertEqual(errorCode(effectiveTree), "capabilityRequired")
        XCTAssertEqual(fixture.activity(), original)
        let removeTree = try await request(fixture, package: noUI, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Summary"]])
        XCTAssertEqual(removeTree["ok"] as? Bool, true)
        XCTAssertNil(fixture.activity()?.presentation.minimal)
    }

    func testInteractiveTreesRequireActionCapabilityAndDeclaredMetadata() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let tree: [String: Any] = ["type": "button", "actionID": "open", "label": ["type": "text", "content": "Open"]]
        let noActions = try package(capabilities: [.publishActivity, .updateActivity, .islandNodeUI])
        let noActionsContext = try fixture.load(noActions)
        let capability = try await request(fixture, package: noActions, context: noActionsContext, params: ["id": "ui", "presentation": ["title": "Button", "expanded": tree], "actions": [["id": "open", "title": "Open"]]])
        XCTAssertEqual(errorCode(capability), "capabilityRequired")
        try noActionsContext.publish(IslandActivity(
            id: fixture.id(), source: noActionsContext.source, priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Host control", expanded: .button(.init(actionID: "open", label: .text(.init("Open"))))),
            createdAt: fixture.activityClock.now(), actions: [.init(id: "open", title: "Open")]
        ))
        let retainedBefore = fixture.activity()
        for _ in 0..<25 {
            let retained = try await request(fixture, package: noActions, context: noActionsContext, method: "activity.update", params: ["id": "ui", "priority": "background"])
            XCTAssertEqual(errorCode(retained), "capabilityRequired")
            XCTAssertEqual(fixture.activity(), retainedBefore)
        }
        let removed = try await request(fixture, package: noActions, context: noActionsContext, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Summary"], "actions": []])
        XCTAssertEqual(removed["ok"] as? Bool, true)
        XCTAssertNil(fixture.activity()?.presentation.expanded)
        XCTAssertTrue(fixture.activity()?.actions.isEmpty == true)
        for _ in 1..<20 {
            let allowed = try await request(fixture, package: noActions, context: noActionsContext, method: "activity.update", params: ["id": "ui", "priority": "background"])
            XCTAssertEqual(allowed["ok"] as? Bool, true)
        }
        let complete = try package(id: "com.example.controls")
        let context = try fixture.load(complete)
        for metadata in [[], [["id": "other", "title": "Other"]]] as [[[String: String]]] {
            let absent = try await request(fixture, package: complete, context: context, params: ["id": "ui", "presentation": ["title": "Button", "expanded": tree], "actions": metadata])
            XCTAssertEqual(errorCode(absent), "invalidArguments")
            XCTAssertNil(fixture.activity(pluginID: complete.manifest.id))
        }
        try await publish(fixture, package: complete, context: context, presentation: ["title": "Button", "expanded": tree], actions: [["id": "open", "title": "Open"]])
        XCTAssertEqual(fixture.activity(pluginID: complete.manifest.id)?.actions, [.init(id: "open", title: "Open")])
    }

    func testPatchMergeRejectsRemovedReferencesAtomicallyAndReusesOmittedMetadata() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, presentation: ["title": "Button", "expanded": ["type": "button", "actionID": "open", "label": ["type": "text", "content": "Open"]]], actions: [["id": "open", "title": "Open"]])
        let before = fixture.activity()
        let rejected = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "priority": "background", "actions": []])
        XCTAssertEqual(errorCode(rejected), "invalidArguments")
        XCTAssertEqual(fixture.activity(), before)
        let replacement = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Toggle", "expanded": ["type": "toggle", "title": "Open", "isOn": false, "actionID": "open"]]])
        XCTAssertEqual(replacement["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity()?.actions, before?.actions)
        let clear = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Summary"], "actions": []])
        XCTAssertEqual(clear["ok"] as? Bool, true)
        XCTAssertNil(fixture.activity()?.presentation.expanded)
        XCTAssertTrue(fixture.activity()?.actions.isEmpty == true)
    }

    func testStructurallyValidOversizedFormsUseExistingHostFallback() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let minimal: [String: Any] = ["type": "hStack", "children": [["type": "text", "content": "Too much for minimal"]]]
        let compact: [String: Any] = ["type": "vStack", "children": [["type": "text", "content": "Row one"], ["type": "text", "content": "Row two"]]]
        try await publish(fixture, package: package, context: context, presentation: ["title": "Safe summary", "minimal": minimal, "compact": compact, "expanded": countedTree(nodeCount: 128)])
        let presentation = try XCTUnwrap(fixture.activity()?.presentation)
        XCTAssertNotNil(presentation.minimal)
        XCTAssertNotNil(presentation.compact)
        XCTAssertNotNil(presentation.expanded)
        for mode in ActivityPresentation.Mode.allCases {
            let resolved = IslandRenderer.resolvedNode(in: presentation, for: mode)
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(resolved, for: mode))
            XCTAssertNotEqual(Optional(resolved), mode == .minimal ? presentation.minimal : mode == .compact ? presentation.compact : presentation.expanded)
        }
    }

    func testMalformedTreeUpdatesDoNotMutateActivityOrConsumeWriteBudget() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, presentation: ["title": "Original", "expanded": ["type": "text", "content": "Original"]])
        let before = fixture.activity()
        for _ in 0..<25 {
            let rejected = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "priority": "background", "presentation": ["title": "Must not commit", "expanded": ["type": "text", "content": "Evil", "selector": "perform:"]]])
            XCTAssertEqual(errorCode(rejected), "invalidArguments")
            XCTAssertEqual(fixture.activity(), before)
        }
        for index in 1..<20 {
            let admitted = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "\(index)", "expanded": ["type": "text", "content": "\(index)"]]])
            XCTAssertEqual(admitted["ok"] as? Bool, true)
        }
        let exhausted = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Too fast", "expanded": ["type": "text", "content": "Too fast"]]])
        XCTAssertEqual(errorCode(exhausted), "rateLimited")
        XCTAssertEqual(fixture.activity()?.presentation.title, "19")
    }

    func testRevokedNodeExecutionCannotReviveOwnedActivities() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, presentation: ["title": "Owned", "minimal": ["type": "text", "content": "Owned"]])
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        let rejected = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "ui", "presentation": ["title": "Late", "minimal": ["type": "text", "content": "Late"]]])
        XCTAssertEqual(errorCode(rejected), "inactiveExecution")
        XCTAssertNil(fixture.activity())
        XCTAssertNil(fixture.manager.current)
    }

    func testNestedDuplicateJSONFieldsAreRejectedBeforeCore() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let source = #"{"apiVersion":"1.0.0","method":"activity.publish","params":{"id":"ui","presentation":{"title":"Duplicate","expanded":{"type":"image","source":{"type":"pluginAsset","id":"safe","id":"unsafe"}}}}}"#
        let rejected = try decode(await fixture.service.handle(source, package: package, context: context))
        XCTAssertEqual(errorCode(rejected), "invalidArguments")
        XCTAssertNil(fixture.activity())
    }

    func testRealJavaScriptRejectsGettersToJSONCyclesNonfiniteAndUnknownTrees() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let source = """
            function onStart() {
                void island.activity.publish({id:'ui',lifecycle:{policy:'persistent'},presentation:{title:'Original',expanded:{type:'text',content:'Original'}}}).then(() => {
                    globalThis.getterCalls = 0; globalThis.toJSONCalls = 0;
                    const getter = {type:'text'};
                    Object.defineProperty(getter,'content',{enumerable:true,get(){getterCalls++;return 'Getter';}});
                    const encoded = {type:'text',content:'Encoded',toJSON(){toJSONCalls++;return {type:'text',content:'Executed'};}};
                    const cycle = {type:'hStack',children:[]}; cycle.children.push(cycle);
                    return Promise.all([getter,encoded,cycle,{type:'progress',value:NaN},{type:'progress',value:Infinity},
                        {type:'text',content:'Unknown',selector:'perform:'},{type:'NSView'},null].map(tree =>
                        island.activity.update({id:'ui',presentation:{title:'Must not commit',expanded:tree}}).catch(error => error.code)));
                }).then(codes => {globalThis.safe = codes.every(code => code === 'invalidArguments') && getterCalls === 0 && toJSONCalls === 0;globalThis.done = true;})
                .catch(error => {globalThis.failure = error.code;globalThis.done = true;});
            }
            """
        let runtime = try fixture.loadJavaScript(package(source: source))
        try await marker(runtime, "done")
        let safe = try await runtime.evaluateForTesting("safe")
        let failureType = try await runtime.evaluateForTesting("typeof failure")
        XCTAssertEqual(safe, .boolean(true))
        XCTAssertEqual(failureType, .string("undefined"))
        XCTAssertEqual(fixture.activity()?.presentation.title, "Original")
        XCTAssertEqual(fixture.activity()?.presentation.expanded, .text(.init("Original")))
    }

    func testRealJavaScriptDepthEightImageArrivesAndDepthNineIsRejected() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let source = """
            function nested(depth) {
                let node = {type:'image',source:{type:'pluginAsset',id:'cover'},size:'artwork'};
                for (let level=1;level<depth;level++) node={type:'hStack',children:[node]};
                return node;
            }
            function onStart() {
                void island.activity.publish({id:'ui',lifecycle:{policy:'persistent'},presentation:{title:'Deep',expanded:nested(8)}})
                    .then(() => island.activity.update({id:'ui',presentation:{title:'Too deep',expanded:nested(9)}}).catch(error => error.code))
                    .then(code => {globalThis.code=code;globalThis.done=true;})
                    .catch(error => {globalThis.failure=error.code;globalThis.done=true;});
            }
            """
        let runtime = try fixture.loadJavaScript(package(source: source))
        try await marker(runtime, "done")
        let code = try await runtime.evaluateForTesting("code")
        let failureType = try await runtime.evaluateForTesting("typeof failure")
        XCTAssertEqual(code, .string("quotaExceeded"))
        XCTAssertEqual(failureType, .string("undefined"))
        XCTAssertEqual(fixture.activity()?.presentation.title, "Deep")
        XCTAssertEqual(fixture.activity()?.presentation.expanded, try parse(nested(["type": "image", "source": ["type": "pluginAsset", "id": "cover"], "size": "artwork"], depth: 8)))
    }

    func testStorageDepthLimitRemainsIndependentOfExpandedUITransportLimit() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package(capabilities: [.publishActivity, .updateActivity, .islandNodeUI, .localStorage], permissions: [.localStorage])
        let context = try fixture.load(package)
        var accepted: Any = 1
        for _ in 1..<8 { accepted = ["value": accepted] }
        let written = try await request(fixture, package: package, context: context, method: "storage.set", params: ["key": "depth", "value": accepted])
        XCTAssertEqual(written["ok"] as? Bool, true)
        let rejected = try await request(fixture, package: package, context: context, method: "storage.set", params: ["key": "depth", "value": ["value": accepted]])
        XCTAssertEqual(errorCode(rejected), "quotaExceeded")
        let read = try await request(fixture, package: package, context: context, method: "storage.get", params: ["key": "depth"])
        XCTAssertEqual(try json(try XCTUnwrap(read["value"])), try json(accepted))
    }

    func testRealNodeMockUpdatesAllThreeFormsInSameHostingViewAndActivityInstance() async throws {
        let fixture = NodeBridgeFixture()
        defer { fixture.shutdown() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let exampleSource = repository.appendingPathComponent("docs/plugin-system/examples/node-mock", isDirectory: true)
        let exampleContainer = FileManager.default.temporaryDirectory.appendingPathComponent("t25-node-mock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exampleContainer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exampleContainer) }
        let exampleRoot = exampleContainer.appendingPathComponent("node-mock", isDirectory: true)
        try FileManager.default.copyItem(at: exampleSource, to: exampleRoot)
        let package = try PluginValidator().validateExpandedPackage(at: exampleRoot,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: exampleContainer))
        XCTAssertEqual(package.manifest.id, "com.example.node-mock")
        XCTAssertTrue(package.manifest.permissions.isEmpty)
        XCTAssertEqual(Set(package.manifest.capabilities), [.publishActivity, .updateActivity, .endActivity, .islandNodeUI])
        let runtime = try fixture.loadJavaScript(package)
        try await logMarker(fixture, pluginID: package.manifest.id, message: "node.ready")
        let original = try XCTUnwrap(fixture.activity("build", pluginID: package.manifest.id))
        XCTAssertEqual(original.id, "plugin:com.example.node-mock:build")
        XCTAssertEqual(original.source, .init(kind: .plugin, identifier: package.manifest.id))
        try assertNodeMockLayouts(original, progress: 0.1, percentage: "10%")
        let token = try XCTUnwrap(fixture.manager.currentSnapshot?.instanceToken)
        let state = NodeBridgeRenderState()
        let view = NSHostingView(rootView: NodeBridgeRenderedView(manager: fixture.manager, state: state).environment(\.colorScheme, .dark))
        view.frame = CGRect(x: 0, y: 0, width: 480, height: 200)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var before: [Data] = []
        for mode in ActivityPresentation.Mode.allCases {
            state.mode = mode
            before.append(try await render(view))
        }
        XCTAssertEqual(Set(before).count, 3)
        for progress in ["0.5", "1"] {
            _ = try await runtime.evaluateForTesting("mockNodeProgress(\(progress)); void 0")
            try await logMarker(fixture, pluginID: package.manifest.id, message: "node.progress:\(progress)")
            let updated = try XCTUnwrap(fixture.activity("build", pluginID: package.manifest.id))
            XCTAssertEqual(updated.id, original.id)
            XCTAssertEqual(updated.source, original.source)
            XCTAssertEqual(updated.createdAt, original.createdAt)
            XCTAssertEqual(updated.lifecycle, original.lifecycle)
            XCTAssertEqual(updated.actions, original.actions)
            XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, token)
            try assertNodeMockLayouts(updated, progress: try XCTUnwrap(Double(progress)), percentage: progress == "1" ? "100%" : "50%")
            var images: [Data] = []
            for (index, mode) in ActivityPresentation.Mode.allCases.enumerated() {
                state.mode = mode
                let after = try await render(view)
                XCTAssertNotEqual(after, before[index])
                images.append(after)
            }
            XCTAssertEqual(Set(images).count, 3)
            before = images
        }
        XCTAssertTrue(fixture.service.logs(for: package.manifest.id).allSatisfy { !$0.message.hasPrefix("node.error:") })
        let actionsSupported = try await runtime.evaluateForTesting("island.actions.supported")
        XCTAssertEqual(actionsSupported, .boolean(true))
        _ = try await runtime.evaluateForTesting("mockNodeEnd(); void 0")
        try await logMarker(fixture, pluginID: package.manifest.id, message: "node.ended")
        XCTAssertNil(fixture.activity("build", pluginID: package.manifest.id))
        XCTAssertNil(fixture.manager.current)
    }

    func testPluginImageReferencesCannotResolveBuiltInMusicArtwork() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let service = MusicActivityTestService(info: NowPlayingInfo(isPlaying: true, title: "Owned artwork", artist: "Artist", album: "Album", trackIdentifier: "node-resource-scope", artworkData: try XCTUnwrap(image.tiffRepresentation)))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.pluginLifecycle.shutdown() }
        let builtin = IslandNode.ImageSource.brokerResource(id: MusicActivityProvider.artworkResourceID)
        XCTAssertNotNil(runtime.resolveImage(builtin, for: MusicActivityProvider.source))
        let plugin = ActivitySource(kind: .plugin, identifier: "com.example.node")
        XCTAssertNil(runtime.resolveImage(builtin, for: plugin))
        let parsed = try parse(["type": "image", "source": ["type": "brokerResource", "id": MusicActivityProvider.artworkResourceID]])
        guard case .image(let node) = parsed else { return XCTFail("Expected data-only image") }
        XCTAssertNil(runtime.resolveImage(node.source, for: plugin))
        XCTAssertNil(runtime.resolveImage(.pluginAsset(id: "cover"), for: plugin))
    }

    // MARK: Helpers

    private func json(_ value: Any) throws -> PluginBridgeJSON {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try PluginBridgeJSON.parse(String(decoding: data, as: UTF8.self), maximumDepth: 22)
    }

    private func parse(_ value: Any) throws -> IslandNode { try PluginIslandNodeConverter.parse(json(value)) }

    private func assertNodeMockLayouts(_ activity: IslandActivity, progress: Double, percentage: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let color: IslandSemanticColorToken = progress == 1 ? .success : .accent
        XCTAssertEqual(activity.presentation.progress, progress, file: file, line: line)
        XCTAssertEqual(activity.presentation.minimal, .text(.init(percentage, color: color)), file: file, line: line)
        XCTAssertEqual(activity.presentation.compact, .hStack(.init([
            .icon(.init(progress == 1 ? "checkmark.circle" : "hammer")),
            .text(.init("构建 " + percentage, color: color))
        ])), file: file, line: line)
        guard case .vStack(let stack) = try XCTUnwrap(activity.presentation.expanded, file: file, line: line),
              case .progress(let node) = try XCTUnwrap(stack.children.last, file: file, line: line) else {
            return XCTFail("Authored expanded progress tree was not preserved", file: file, line: line)
        }
        XCTAssertEqual(node.value, progress, file: file, line: line)
        XCTAssertEqual(node.color, color, file: file, line: line)
        XCTAssertEqual(node.style, .linear, file: file, line: line)
    }

    private func assertInvalid(_ value: PluginBridgeJSON, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PluginIslandNodeConverter.parse(value), file: file, line: line) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .invalidArguments, file: file, line: line)
        }
    }

    private func assertQuota(_ value: PluginBridgeJSON, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PluginIslandNodeConverter.parse(value), file: file, line: line) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded, file: file, line: line)
        }
    }

    private func nested(_ leaf: [String: Any], depth: Int) -> [String: Any] {
        var value = leaf
        for _ in 1..<depth { value = ["type": "hStack", "children": [value]] }
        return value
    }

    private func countedTree(nodeCount: Int) -> [String: Any] {
        // 1 root + 8 branch nodes + 119/120 leaves = 128/129 nodes.
        let leaves = nodeCount - 9
        let branches = (0..<8).map { index -> [String: Any] in
            let count = leaves / 8 + (index < leaves % 8 ? 1 : 0)
            return ["type": "vStack", "children": Array(repeating: ["type": "text", "content": "x"], count: count)]
        }
        return ["type": "hStack", "children": branches]
    }

    private func package(id: String = "com.example.node", source: String = "",
                         capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions],
                         permissions: [PluginPermission] = []) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Island Node Bridge Test", version: SemanticVersion("1.0.0"), engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: permissions, capabilities: capabilities)
        let data = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/node-bridge-tests/\(id)", isDirectory: true), entryRelativePath: "index.js", entrySource: data, regularFileCount: 2, totalFileBytes: UInt64(data.count))
    }

    private func publish(_ fixture: NodeBridgeFixture, package: ValidatedPluginPackage, context: PluginExecutionContext,
                         presentation: [String: Any], actions: [[String: String]] = [], file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await request(fixture, package: package, context: context, params: ["id": "ui", "lifecycle": ["policy": "persistent"], "presentation": presentation, "actions": actions])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)", file: file, line: line)
    }

    private func request(_ fixture: NodeBridgeFixture, package: ValidatedPluginPackage, context: PluginExecutionContext,
                         method: String = "activity.publish", params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": method, "params": params])
        return try decode(await fixture.service.handle(String(decoding: data, as: UTF8.self), package: package, context: context))
    }

    private func decode(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }

    private func errorCode(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while true {
            if runtime.snapshot.state == .running, try await runtime.evaluateForTesting("globalThis['\(name)'] === true") == .boolean(true) { return }
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else {
                XCTFail("JavaScript marker \(name) failed: \(runtime.snapshot)")
                throw NodeBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func logMarker(_ fixture: NodeBridgeFixture, pluginID: String, message: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !fixture.service.logs(for: pluginID).contains(where: { $0.message == message }) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Log \(message) did not arrive: \(fixture.service.logs(for: pluginID))")
                throw NodeBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func render<Content: View>(_ view: NSHostingView<Content>) async throws -> Data {
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class NodeBridgeFixture {
    let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 95_000))
    let rateClock = NodeBridgeRateClock()
    let permissions = PermissionManager()
    let service: PluginJSBridge
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    private let factory: NodeBridgeFactory

    init() {
        let clock = rateClock
        service = PluginJSBridge(permissions: permissions, activityRateClock: { clock.now })
        var configuration = ActivityScheduler.Configuration.immediate
        configuration.maximumQueuedNormal = 32
        manager = ActivityManager(clock: activityClock, configuration: configuration)
        let factory = NodeBridgeFactory(service: service)
        self.factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), permissions: permissions) { package in
            let runtime = factory.usesJavaScript ? PluginRuntime(package: package, bridge: factory.service) : nil
            if let runtime { factory.runtimes.append(runtime) }
            return NodeBridgeTestRuntime(factory: factory, runtime: runtime)
        }
    }

    func load(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        try approveLocalStorage(package)
        factory.usesJavaScript = false
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.contexts.last)
    }

    func loadJavaScript(_ package: ValidatedPluginPackage) throws -> PluginRuntime {
        try approveLocalStorage(package)
        factory.usesJavaScript = true
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.runtimes.last)
    }

    private func approveLocalStorage(_ package: ValidatedPluginPackage) throws {
        let review = permissions.request(package: package)
        if package.manifest.permissions.contains(.localStorage),
           package.manifest.capabilities.contains(.localStorage) {
            try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        }
    }

    func id(_ localID: String = "ui", pluginID: String = "com.example.node") -> String { PluginJSBridge.activityID(pluginID: pluginID, localID: localID) }
    func activity(_ localID: String = "ui", pluginID: String = "com.example.node") -> IslandActivity? { manager.activity(id: id(localID, pluginID: pluginID)) }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class NodeBridgeRateClock { var now: TimeInterval = 1_000 }

@MainActor
private final class NodeBridgeFactory {
    let service: PluginJSBridge
    var usesJavaScript = false
    var contexts: [PluginExecutionContext] = []
    var runtimes: [PluginRuntime] = []
    init(service: PluginJSBridge) { self.service = service }
}

@MainActor
private final class NodeBridgeTestRuntime: PluginLifecycleRuntime {
    let factory: NodeBridgeFactory
    let runtime: PluginRuntime?
    init(factory: NodeBridgeFactory, runtime: PluginRuntime?) { self.factory = factory; self.runtime = runtime }
    func onStart(context: PluginExecutionContext) throws { factory.contexts.append(context); try runtime?.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime?.onStop(reason: reason) }
    func teardown() { runtime?.teardown() }
}

@MainActor
private final class NodeBridgeRenderState: ObservableObject { @Published var mode: ActivityPresentation.Mode = .minimal }

private struct NodeBridgeRenderedView: View {
    @ObservedObject var manager: ActivityManager
    @ObservedObject var state: NodeBridgeRenderState
    var body: some View {
        Group {
            if let activity = manager.current {
                IslandRenderer(presentation: activity.presentation, mode: state.mode,
                               shellSize: state.mode == .expanded ? .init(width: 480, height: 200) : .init(width: 300, height: 32))
            } else { Text("No Activity") }
        }
        .frame(width: 480, height: 200)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}

private enum NodeBridgeTestError: Error { case timedOut }
