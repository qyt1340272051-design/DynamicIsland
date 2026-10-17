import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCompatibilityBridgeTests: XCTestCase {
    func testSuccessfulLayoutsReportTheirUnionThenReplaceOnlyWithNewSuccessfulFrame() async throws {
        let fixture = try CompatibilityBridgeFixture()
        defer { fixture.shutdown() }
        XCTAssertEqual(fixture.report?.observation, .awaitingLayout)
        let first = try await fixture.render(compact: ["type": "text", "value": "Compact"],
            expanded: ["type": "hstack", "children": [["type": "icon", "name": "star", "size": 14]]])
        XCTAssertEqual(first["ok"] as? Bool, true)
        XCTAssertEqual(fixture.report?.layoutLimitations, [.hostTextTypography, .hostTextLineLimit,
            .hostStackSpacing, .hostStackAlignment, .hostIconAppearance])
        XCTAssertEqual(fixture.report?.observation, .rendered)
        XCTAssertEqual(fixture.report?.level, .limited)
        let second = try await fixture.render(compact: ["type": "progress", "value": 0.25],
                                              expanded: ["type": "progress", "value": 0.75])
        XCTAssertEqual(second["ok"] as? Bool, true)
        XCTAssertEqual(fixture.report?.layoutLimitations, [])
        XCTAssertEqual(fixture.report?.level, .limited, "One frame without appearance substitutions cannot prove complete compatibility.")
        XCTAssertFalse(try XCTUnwrap(fixture.report).profileLimitations.isEmpty)
    }

    func testMalformedOrSelfReportedCompatibilityCannotOverwriteSuccessfulReport() async throws {
        let fixture = try CompatibilityBridgeFixture()
        defer { fixture.shutdown() }
        _ = try await fixture.render(compact: ["type": "text", "value": "Known"], expanded: ["type": "icon", "name": "star"])
        let prior = fixture.report
        for params: [String: Any] in [
            ["compact": ["type": "progress", "value": 0.5], "expanded": ["type": "NSView"]],
            ["compact": ["type": "progress", "value": 0.5], "expanded": ["type": "text", "value": String(repeating: "x", count: 257)]],
            ["compact": ["type": "progress", "value": 0.5], "expanded": ["type": "progress", "value": 0.5], "compatibilityLevel": "compatible"]
        ] {
            let response = try await fixture.send(params)
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual(fixture.report, prior)
        }
    }

    func testRateLimitAndMissingCapabilityCannotCreateOrReplaceLayoutObservation() async throws {
        let fixture = try CompatibilityBridgeFixture()
        defer { fixture.shutdown() }
        for _ in 0..<20 {
            let response = try await fixture.render(compact: ["type": "progress", "value": 0.25], expanded: ["type": "progress", "value": 0.5])
            XCTAssertEqual(response["ok"] as? Bool, true)
        }
        let before = fixture.report
        let rejected = try await fixture.render(compact: ["type": "text", "value": "Rate limited"], expanded: ["type": "icon", "name": "star"])
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? String, "rateLimited")
        XCTAssertEqual(fixture.report, before)

        let noUI = try CompatibilityBridgeFixture(capabilities: [.publishActivity, .updateActivity])
        defer { noUI.shutdown() }
        let denied = try await noUI.render(compact: ["type": "text", "value": "No capability"], expanded: ["type": "icon", "name": "star"])
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? String, "capabilityRequired")
        XCTAssertEqual(noUI.report?.observation, .awaitingLayout)
        XCTAssertEqual(noUI.report?.layoutLimitations, [])
    }

    func testSynchronousRevocationDuringPublishLeavesNoSuccessfulLayoutReport() async throws {
        let fixture = try CompatibilityBridgeFixture()
        defer { fixture.shutdown() }
        var revoked = false
        let observation = fixture.manager.$toolSnapshots.sink { values in
            guard !revoked, values.contains(where: { $0.activity.source.identifier == fixture.package.manifest.id }) else { return }
            revoked = true
            fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: false)
        }
        defer { observation.cancel() }
        let response = try await fixture.render(compact: ["type": "text", "value": "Revoked"], expanded: ["type": "icon", "name": "star"])
        XCTAssertTrue(revoked)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "inactiveExecution")
        XCTAssertEqual(fixture.report?.observation, .notRun)
        XCTAssertEqual(fixture.report?.layoutLimitations, [])
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
    }

    func testChangedEntryBytesCannotReadReportEvenWithSameIDVersionAndManifest() async throws {
        let fixture = try CompatibilityBridgeFixture()
        defer { fixture.shutdown() }
        _ = try await fixture.render(compact: ["type": "text", "value": "First"], expanded: ["type": "icon", "name": "star"])
        let changed = ValidatedPluginPackage(manifest: fixture.package.manifest,
            canonicalRootURL: fixture.package.canonicalRootURL, entryRelativePath: fixture.package.entryRelativePath,
            entrySource: Data("changed bytes".utf8), regularFileCount: 2, totalFileBytes: 13)
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: changed))
        XCTAssertEqual(fixture.report?.observation, .rendered)
        let context = fixture.context
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: false)
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: true)
        XCTAssertEqual(fixture.report?.observation, .awaitingLayout)
        XCTAssertThrowsError(try context.recordCompatibilityLayout([.hostButtonAppearance]))
        XCTAssertEqual(fixture.report?.layoutLimitations, [])
    }
}

@MainActor
private final class CompatibilityBridgeFixture {
    let service = PluginJSBridge(activityRateClock: { 1_000 })
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    let package: ValidatedPluginPackage
    private let capture: CompatibilityContextCapture
    var context: PluginExecutionContext { capture.contexts[capture.contexts.count - 1] }
    var report: PluginCompatibilitySnapshot? { lifecycle.compatibilitySnapshot(for: package) }

    init(capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .islandNodeUI]) throws {
        let manifest = try PluginManifest(id: "com.example.compatibility-report", name: "Compatibility Report", version: SemanticVersion("1.0.0"),
            engine: .superIsland, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities)
        package = .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/compatibility-report-tests"),
            entryRelativePath: "index.js", entrySource: Data(), regularFileCount: 2, totalFileBytes: 0)
        let manager = ActivityManager(configuration: .immediate)
        self.manager = manager
        let capture = CompatibilityContextCapture()
        self.capture = capture
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager),
            runtimeFactory: { _ in CompatibilityCaptureRuntime(capture: capture) })
        lifecycle.pluginDidLoad(package, isEnabled: true)
    }
    func render(compact: [String: Any], expanded: [String: Any]) async throws -> [String: Any] {
        try await send(["compact": compact, "expanded": expanded])
    }
    func send(_ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": "superisland.render", "params": params])
        let response = await service.handle(String(decoding: data, as: UTF8.self), package: package, context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }
    func shutdown() { lifecycle.shutdown() }
}
@MainActor
private final class CompatibilityContextCapture { var contexts: [PluginExecutionContext] = [] }
@MainActor
private final class CompatibilityCaptureRuntime: PluginLifecycleRuntime {
    let capture: CompatibilityContextCapture
    init(capture: CompatibilityContextCapture) { self.capture = capture }
    func onStart(context: PluginExecutionContext) throws { capture.contexts.append(context) }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}
