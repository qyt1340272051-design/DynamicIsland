import Foundation
import Combine
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginPresentationBridgeTests: XCTestCase {
    func testSynchronousDisableDuringPresentationCannotReturnAcceptedForOldExecution() async throws {
        let fixture = try PresentationBridgeFixture()
        defer { fixture.shutdown() }
        let handle = try await fixture.render()
        var didDisable = false
        let observation = fixture.manager.$currentSnapshot.sink { snapshot in
            guard !didDisable, snapshot?.activity.source.identifier == fixture.package.manifest.id else { return }
            didDisable = true
            fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: false)
        }
        defer { observation.cancel() }
        let response = try await fixture.send("superisland.presentation", ["operation": "activate", "handle": handle, "autoDismiss": true])
        XCTAssertTrue(didDisable)
        XCTAssertEqual(code(response), "inactiveExecution")
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertNil(fixture.manager.current)
        XCTAssertTrue(fixture.manager.toolSnapshots.isEmpty)
    }

    func testHostRejectsNativeModeAndUndeclaredCapabilityWithoutGrantingPresentation() async throws {
        let native = try PresentationBridgeFixture(engine: .javaScriptCore)
        defer { native.shutdown() }
        let unsupported = try await native.send("superisland.presentation", ["operation": "activate", "handle": "opaque", "autoDismiss": true])
        XCTAssertEqual(code(unsupported), "unsupportedMethod")

        let undeclared = try PresentationBridgeFixture(capabilities: [.publishActivity, .updateActivity, .islandNodeUI])
        defer { undeclared.shutdown() }
        let handle = try await undeclared.render()
        let response = try await undeclared.present(handle)
        XCTAssertEqual(response["status"] as? String, "rejected")
        XCTAssertEqual(response["reason"] as? String, "capabilityRequired")
        XCTAssertNil(undeclared.manager.currentSnapshot)
        XCTAssertEqual(undeclared.service.diagnostics.records(for: undeclared.package.manifest.id).last?.code, "presentationRejected")
        XCTAssertTrue(undeclared.service.diagnostics.records(for: undeclared.package.manifest.id).allSatisfy { $0.category == .presentationDecision })
    }

    func testRequestShapeCannotSupplyIdentityDurationOrCoerceBoolean() async throws {
        let fixture = try PresentationBridgeFixture()
        defer { fixture.shutdown() }
        let handle = try await fixture.render()
        let malformed: [[String: Any]] = [
            ["operation": "activate", "handle": handle],
            ["operation": "activate", "handle": handle, "autoDismiss": "true"],
            ["operation": "activate", "handle": handle, "autoDismiss": 1],
            ["operation": "activate", "handle": handle, "autoDismiss": true, "id": "another"],
            ["operation": "activate", "handle": handle, "autoDismiss": true, "source": "another"],
            ["operation": "activate", "handle": handle, "autoDismiss": true, "duration": 999],
            ["operation": "dismiss", "handle": handle, "autoDismiss": true],
            ["operation": "end", "handle": handle],
            ["operation": "activate", "handle": "../foreign", "autoDismiss": true]
        ]
        for params in malformed {
            let response = try await fixture.send("superisland.presentation", params)
            XCTAssertEqual(code(response), "invalidArguments")
        }
        XCTAssertNil(fixture.manager.currentSnapshot)
        let accepted = try await fixture.present(handle)
        XCTAssertEqual(accepted["reason"] as? String, "granted")
        XCTAssertNil(fixture.manager.selectedToolSnapshot, "A request must not masquerade as a user choice.")
    }

    func testHandleCannotRetargetReplacementWithSameIDOrRevokeItsLaterLease() async throws {
        let fixture = try PresentationBridgeFixture()
        defer { fixture.shutdown() }
        let oldHandle = try await fixture.render()
        let original = try XCTUnwrap(fixture.manager.toolSnapshots.first)
        try fixture.context.endActivity(id: original.activity.id)
        try fixture.context.publish(IslandActivity(id: original.activity.id, source: fixture.context.source,
            priority: .background, lifecycle: .init(policy: .persistent), presentation: original.activity.presentation,
            createdAt: fixture.clock.now()))
        let rejected = try await fixture.present(oldHandle)
        XCTAssertEqual(rejected["reason"] as? String, "staleInstance")
        XCTAssertNil(fixture.manager.currentSnapshot)
        let newHandle = try await fixture.render()
        XCTAssertNotEqual(oldHandle, newHandle)
        let accepted = try await fixture.present(newHandle)
        XCTAssertEqual(accepted["reason"] as? String, "granted")
        let replacement = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertNotEqual(original.instanceToken, replacement.instanceToken)
        let staleDismiss = try await fixture.send("superisland.presentation", ["operation": "dismiss", "handle": oldHandle])
        XCTAssertEqual((staleDismiss["value"] as? [String: Any])?["reason"] as? String, "staleInstance")
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, replacement.instanceToken)
    }

    func testHandlesAreOwnedByExecutionAndCannotCrossPluginBoundary() async throws {
        let fixture = try PresentationBridgeFixture()
        defer { fixture.shutdown() }
        let oldHandle = try await fixture.render()
        let oldContext = fixture.context
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: false)
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: true)
        let newHandle = try await fixture.render()
        XCTAssertNotEqual(newHandle, oldHandle)
        let stale = try await fixture.send("superisland.presentation", ["operation": "activate", "handle": oldHandle, "autoDismiss": true], context: oldContext)
        XCTAssertEqual(code(stale), "inactiveExecution")
        let foreign = try PresentationBridgeFixture(id: "com.example.presentation-other")
        defer { foreign.shutdown() }
        _ = try await foreign.render()
        let rejected = try await foreign.present(newHandle)
        XCTAssertEqual(rejected["reason"] as? String, "staleInstance")
        XCTAssertNil(foreign.manager.currentSnapshot)
        let accepted = try await fixture.present(newHandle)
        XCTAssertEqual(accepted["reason"] as? String, "granted")
        let token = fixture.manager.currentSnapshot?.instanceToken
        let oldDismiss = try await fixture.send("superisland.presentation", ["operation": "dismiss", "handle": oldHandle], context: oldContext)
        XCTAssertEqual(code(oldDismiss), "inactiveExecution")
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, token)
    }

    func testRefusedPolicyIsDataAndBoundedGrantExpiryDoesNotEndModule() async throws {
        let fixture = try PresentationBridgeFixture()
        defer { fixture.shutdown() }
        let handle = try await fixture.render()
        fixture.manager.setPresentationRequestsAllowed(false)
        let rejected = try await fixture.present(handle)
        XCTAssertEqual(rejected["status"] as? String, "rejected")
        XCTAssertEqual(rejected["reason"] as? String, "hostUnavailable")
        fixture.manager.setPresentationRequestsAllowed(true)
        let degraded = try await fixture.present(handle, autoDismiss: false)
        XCTAssertEqual(degraded["status"] as? String, "degraded")
        XCTAssertEqual(degraded["reason"] as? String, "boundedDuration")
        fixture.clock.advance(by: 31)
        fixture.manager.processDeadlines()
        XCTAssertNil(fixture.manager.currentSnapshot)
        XCTAssertEqual(fixture.manager.toolSnapshots.count, 1)
        XCTAssertEqual(fixture.service.diagnostics.records(for: fixture.package.manifest.id).map(\.code), ["presentationRejected", "presentationDegraded"])
    }

    private func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
}

@MainActor
private final class PresentationBridgeFixture {
    let clock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 107_000))
    let service = PluginJSBridge(activityRateClock: { 1_000 })
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    let package: ValidatedPluginPackage
    private let capture: PresentationContextCapture
    var context: PluginExecutionContext { capture.contexts[capture.contexts.count - 1] }

    init(id: String = "com.example.presentation", engine: PluginEngine = .superIsland,
         capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .islandNodeUI, .requestPresentation]) throws {
        let manifest = try PluginManifest(id: id, name: "Presentation", version: SemanticVersion("1.0.0"),
            engine: engine, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities)
        package = .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/presentation-tests/\(id)"),
                        entryRelativePath: "index.js", entrySource: Data(), regularFileCount: 2, totalFileBytes: 0)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        self.manager = manager
        let capture = PresentationContextCapture()
        self.capture = capture
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager),
            runtimeFactory: { _ in PresentationCaptureRuntime(capture: capture) })
        manager.setPresentationRequestsAllowed(true)
        lifecycle.pluginDidLoad(package, isEnabled: true)
    }

    func render() async throws -> String {
        let response = try await send("superisland.render", ["compact": ["type": "text", "value": "Compact"],
                                                           "expanded": ["type": "text", "value": "Expanded"]])
        let value = try XCTUnwrap(response["value"] as? [String: Any])
        return try XCTUnwrap(value["presentationHandle"] as? String)
    }
    func present(_ handle: String, autoDismiss: Bool = true) async throws -> [String: Any] {
        let response = try await send("superisland.presentation", ["operation": "activate", "autoDismiss": autoDismiss, "handle": handle])
        return try XCTUnwrap(response["value"] as? [String: Any])
    }
    func send(_ method: String, _ params: [String: Any], context: PluginExecutionContext? = nil) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": method, "params": params])
        let response = await service.handle(String(decoding: data, as: UTF8.self), package: package, context: context ?? self.context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class PresentationContextCapture { var contexts: [PluginExecutionContext] = [] }
@MainActor
private final class PresentationCaptureRuntime: PluginLifecycleRuntime {
    let capture: PresentationContextCapture
    init(capture: PresentationContextCapture) { self.capture = capture }
    func onStart(context: PluginExecutionContext) throws { capture.contexts.append(context) }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}
