import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginSDKContractTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testBundledManifestSchemaIsAnExactOfflineCopyOfHostContract() throws {
        let host = try json(at: "docs/plugin-system/schema/plugin-manifest-v1.schema.json")
        let sdk = try json(at: "SDK/schema/plugin-manifest-v1.schema.json")
        XCTAssertEqual(sdk, host, "The offline authoring copy must not drift from the Host schema.")
        for relative in ["SDK/examples/hello-world/manifest.json", "docs/plugin-system/examples/pomodoro/manifest.json",
                         "docs/plugin-system/examples/github/manifest.json"] {
            let manifest = try PluginManifest.decodeJSON(Data(contentsOf: repository.appendingPathComponent(relative)))
            XCTAssertEqual(manifest.engine, .javaScriptCore)
            XCTAssertEqual(manifest.minimumHostVersion, try SemanticVersion("0.6.0"))
        }
    }

    func testSharedAuthoringCasesAgreeWithProductionManifestAndNodeConverters() throws {
        guard case .object(let document) = try json(at: "SDK/tests/fixtures/host-contract-cases.json"),
              case .array(let manifests)? = document["manifests"],
              case .array(let nodes)? = document["nodes"] else { return XCTFail("Missing SDK contract cases") }
        for item in manifests {
            guard case .object(let fields) = item, case .string(let name)? = fields["name"],
                  case .string(let source)? = fields["source"], case .boolean(let accept)? = fields["accept"]
            else { return XCTFail("Malformed manifest case") }
            do {
                _ = try PluginManifest.decodeJSON(Data(source.utf8))
                XCTAssertTrue(accept, "Host accepted rejected authoring case: \(name)")
            } catch {
                XCTAssertFalse(accept, "Host rejected accepted authoring case: \(name): \(error)")
            }
        }
        for item in nodes {
            guard case .object(let fields) = item, case .string(let name)? = fields["name"],
                  let node = fields["node"], case .boolean(let accept)? = fields["accept"]
            else { return XCTFail("Malformed node case") }
            do {
                _ = try PluginIslandNodeConverter.parse(node)
                XCTAssertTrue(accept, "Host accepted rejected authoring case: \(name)")
            } catch {
                XCTAssertFalse(accept, "Host rejected accepted authoring case: \(name): \(error)")
            }
        }
        XCTAssertGreaterThanOrEqual(manifests.count, 8)
        XCTAssertGreaterThanOrEqual(nodes.count, 12)
    }

    func testSDKPackagedHelloRunsInProductionVMAndRoutesOnlyCurrentInstances() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let expanded = temporary.appendingPathComponent("hello-world")
        try PluginPackageArchiveExtractor().extract(
            archiveURL: repository.appendingPathComponent("SDK/tests/fixtures/hello-world.dip"), destinationURL: expanded)
        let package = try PluginValidator().validateExpandedPackage(at: expanded,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: temporary))
        XCTAssertEqual(package.entrySource, try Data(contentsOf: repository.appendingPathComponent("SDK/examples/hello-world/index.js")))
        XCTAssertTrue(package.manifest.permissions.isEmpty)
        let fixture = SDKRuntimeFixture()
        defer { fixture.lifecycle.shutdown() }
        fixture.lifecycle.pluginDidLoad(package, isEnabled: false)
        XCTAssertTrue(fixture.runtimes.isEmpty, "Validation/loading disabled code must not execute it.")
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        try await wait { fixture.tool?.presentation.subtitle == "本次运行已点击 0 次" }
        XCTAssertNil(fixture.activities.currentSnapshot, "The template cannot force a foreground presentation.")
        let first = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertFalse(first.activity.presentation.isCompactVisible)
        XCTAssertNotNil(first.activity.presentation.minimal)
        XCTAssertNotNil(first.activity.presentation.compact)
        XCTAssertNotNil(first.activity.presentation.expanded)
        fixture.activities.setPresentationContext(.expanded)
        XCTAssertTrue(fixture.activities.selectTool(first))
        XCTAssertEqual(fixture.dispatch(first), .handled)
        try await wait { fixture.tool?.presentation.subtitle == "本次运行已点击 1 次" }
        XCTAssertEqual(fixture.activities.toolSnapshots.first?.instanceToken, first.instanceToken)

        let previousRuntime = try XCTUnwrap(fixture.runtimes.first)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        XCTAssertTrue(fixture.activities.toolSnapshots.isEmpty)
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        do {
            _ = try await previousRuntime.evaluateForTesting("island.activity.publish({id:'late',presentation:{title:'Late'}})")
            XCTFail("Revoked execution accepted work")
        } catch { XCTAssertEqual(error as? PluginRuntimeError, .inactiveExecution) }

        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        try await wait { fixture.tool?.presentation.subtitle == "本次运行已点击 0 次" }
        let replacement = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertNotEqual(replacement.instanceToken, first.instanceToken)
        XCTAssertTrue(fixture.activities.selectTool(replacement))
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(replacement), .handled)
        try await wait { fixture.tool?.presentation.subtitle == "本次运行已点击 1 次" }
        XCTAssertEqual(fixture.runtimes.count, 2)
        XCTAssertNil(fixture.lifecycle.snapshot(id: package.manifest.id)?.lastFailure)
    }

    func testIndependentAuthorPackageRoutesBothButtonsThroughCurrentHostInstance() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-independent-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let expanded = temporary.appendingPathComponent("status-switch")
        // Load the actual independently authored archive. The test does not
        // rewrite its entry or substitute a hand-written JavaScript fixture.
        try PluginPackageArchiveExtractor().extract(archiveURL: repository.appendingPathComponent(
            "docs/plugin-system/evidence/t39-independent-20261019/status-switch-0.1.0.dip"), destinationURL: expanded)
        let package = try PluginValidator().validateExpandedPackage(at: expanded,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: temporary))
        XCTAssertEqual(package.manifest.id, "com.example.independent-status")
        XCTAssertEqual(package.manifest.engine, .javaScriptCore)
        XCTAssertTrue(package.manifest.permissions.isEmpty)

        let fixture = SDKRuntimeFixture()
        defer { fixture.lifecycle.shutdown() }
        func showsState(_ state: String) -> Bool {
            containsText("当前状态：\(state)", in: fixture.tool?.presentation.expanded)
        }
        fixture.lifecycle.pluginDidLoad(package, isEnabled: false)
        XCTAssertTrue(fixture.runtimes.isEmpty, "Loading a disabled independent package must not execute its entry.")
        XCTAssertTrue(fixture.activities.toolSnapshots.isEmpty)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        try await wait { showsState("待选择") }
        XCTAssertNil(fixture.activities.currentSnapshot, "The independent tool cannot force a foreground presentation.")
        let first = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertEqual(Set(first.activity.actions.map(\.id)), ["focus", "rest"])
        fixture.activities.setPresentationContext(.expanded)
        XCTAssertTrue(fixture.activities.selectTool(first))

        XCTAssertEqual(fixture.dispatch(first, actionID: "focus"), .handled)
        try await wait { showsState("专注中") }
        let focused = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertEqual(focused.instanceToken, first.instanceToken)
        XCTAssertEqual(focused.activity.createdAt, first.activity.createdAt)
        XCTAssertEqual(fixture.dispatch(focused, actionID: "rest"), .handled)
        try await wait { showsState("休息中") }
        let resting = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertEqual(resting.instanceToken, first.instanceToken)

        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        XCTAssertTrue(fixture.activities.toolSnapshots.isEmpty)
        XCTAssertEqual(fixture.dispatch(focused, actionID: "focus"), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(resting, actionID: "rest"), .inactiveActivity)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        try await wait { showsState("待选择") }
        let replacement = try XCTUnwrap(fixture.activities.toolSnapshots.first)
        XCTAssertNotEqual(replacement.instanceToken, first.instanceToken)
        XCTAssertTrue(fixture.activities.selectTool(replacement))
        XCTAssertEqual(fixture.dispatch(resting, actionID: "rest"), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(replacement, actionID: "focus"), .handled)
        try await wait { showsState("专注中") }
        XCTAssertEqual(fixture.runtimes.count, 2)
        XCTAssertNil(fixture.lifecycle.snapshot(id: package.manifest.id)?.lastFailure)
    }

    private func containsText(_ content: String, in node: IslandNode?) -> Bool {
        guard let node else { return false }
        switch node {
        case .text(let text): return text.content == content
        case .hStack(let stack), .vStack(let stack):
            return stack.children.contains { containsText(content, in: $0) }
        case .button(let button): return containsText(content, in: button.label)
        default: return false
        }
    }

    private func json(at relative: String) throws -> PluginBridgeJSON {
        let source = try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
        return try PluginBridgeJSON.parse(source, maximumBytes: 65_536, maximumDepth: 32, maximumNodes: 4_096)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw SDKContractError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class SDKRuntimeFixture {
    let activities = ActivityManager(configuration: .immediate)
    lazy var router = ActionRouter(manager: activities)
    var runtimes: [PluginRuntime] = []
    lazy var lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: router, runtimeFactory: { [unowned self] package in
        let runtime = PluginRuntime(package: package)
        runtimes.append(runtime)
        return runtime
    })
    var tool: IslandActivity? { activities.toolSnapshots.first?.activity }

    func dispatch(_ snapshot: ActivitySnapshot, actionID: String = "increment") -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
                        action: .init(actionID: actionID, value: .none))
    }
}

private enum SDKContractError: Error { case timedOut }
