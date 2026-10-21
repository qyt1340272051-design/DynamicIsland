import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownNodeBridgeTests: XCTestCase {
    func testPublishResolvesOwnedCountdownInAllThreeLayoutsWithoutJavaScript() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let started = try fixture.start(package, duration: 90_000)
        let reference = fixture.reference(started)
        let node = fixture.node(reference)
        let response = try await fixture.request(package, method: "activity.publish", fields: [
            "id": .string("controls"), "lifecycle": .object(["policy": .string("persistent")]),
            "presentation": .object([
                "title": .string("Countdown"), "minimal": node,
                "compact": .object(["type": .string("hStack"), "children": .array([node])]),
                "expanded": .object(["type": .string("vStack"), "children": .array([
                    .object(["type": .string("zStack"), "children": .array([
                        .object(["type": .string("button"), "actionID": .string("start"), "label": node])
                    ])])
                ])])
            ]),
            "actions": .array([.object(["id": .string("start"), "title": .string("Start")])])
        ])
        XCTAssertEqual(response["ok"], .boolean(true))
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        let presentation = snapshot.activity.presentation
        for layout in [presentation.minimal, presentation.compact, presentation.expanded] {
            let references = PluginIslandNodeConverter.countdownNodes(in: try XCTUnwrap(layout))
            XCTAssertEqual(references, [reference])
        }
        XCTAssertEqual(fixture.lifecycle.resolveCountdown(reference, for: snapshot),
                       .init(text: "01:30", progress: 0, requiresTick: true))
        fixture.clock.now = .seconds(45)
        XCTAssertEqual(fixture.lifecycle.resolveCountdown(reference, for: snapshot),
                       .init(text: "00:45", progress: 0.5, requiresTick: true))
        let paused = try fixture.broker.pause(owner: fixture.owner(package), id: started.id, generation: started.generation)
        let pausedReference = fixture.reference(paused)
        let pausedUpdate = try await fixture.request(package, method: "activity.update", fields: [
            "id": .string("controls"), "presentation": .object([
                "title": .string("Paused"), "minimal": fixture.node(pausedReference)
            ])
        ])
        XCTAssertEqual(pausedUpdate["ok"], .boolean(true))
        fixture.clock.now = .seconds(100)
        XCTAssertEqual(fixture.lifecycle.resolveCountdown(pausedReference, for: try XCTUnwrap(fixture.manager.currentSnapshot)),
                       .init(text: "00:45", progress: 0.5, requiresTick: false))
        XCTAssertEqual(fixture.captures.starts[package.manifest.id], 1)
    }

    func testForeignGenerationIsRejectedInEveryLayoutWithoutPartiallyChangingActivity() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let foreignPackage = try fixture.load(id: "com.example.countdown-node-foreign")
        let own = try fixture.start(package)
        let foreign = try fixture.start(foreignPackage)
        try await fixture.publish(package, reference: fixture.reference(own))
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        let foreignReference = fixture.reference(foreign)
        XCTAssertEqual(own.id, foreign.id)
        XCTAssertNotEqual(own.generation, foreign.generation)

        for layout in ["minimal", "compact", "expanded"] {
            let response = try await fixture.request(package, method: "activity.update", fields: [
                "id": .string("controls"), "priority": .string("background"),
                "presentation": .object([
                    "title": .string("Must not replace"),
                    layout: .object(["type": .string("hStack"), "children": .array([fixture.node(foreignReference)])])
                ])
            ])
            XCTAssertEqual(fixture.errorCode(response), "staleCountdown")
            XCTAssertEqual(fixture.manager.currentSnapshot, original)
            XCTAssertNil(fixture.lifecycle.resolveCountdown(foreignReference, for: original))
        }
        let rejectedPublish = try await fixture.request(package, method: "activity.publish", fields:
            fixture.publishFields(reference: foreignReference, localID: "foreign"))
        XCTAssertEqual(fixture.errorCode(rejectedPublish), "staleCountdown")
        XCTAssertNil(fixture.manager.activity(id: PluginJSBridge.activityID(pluginID: package.manifest.id, localID: "foreign")))
        XCTAssertEqual(fixture.manager.currentSnapshot, original)
    }

    func testMissingCapabilitiesRejectPublishAndPriorityOnlyUpdateOfRetainedCountdown() async throws {
        for missing in [PluginCapability.countdown, .islandNodeUI] {
            let fixture = CountdownNodeBridgeFixture()
            defer { fixture.shutdown() }
            let package = try fixture.load(capabilities: CountdownNodeBridgeFixture.capabilities.filter { $0 != missing })
            let context = try fixture.context(package)
            let reference: IslandNode.Countdown
            if missing == .countdown {
                reference = .init(id: "focus", generation: UUID().uuidString.lowercased())
            } else {
                reference = fixture.reference(try fixture.start(package))
            }
            let publish = try await fixture.request(package, method: "activity.publish", fields:
                fixture.publishFields(reference: reference))
            XCTAssertEqual(fixture.errorCode(publish), "capabilityRequired")
            XCTAssertNil(fixture.manager.currentSnapshot)

            // Host-owned retained data must undergo the same final Activity
            // checks even when a partial request contains no new layout.
            try fixture.seedRetainedActivity(package, reference: reference)
            let retained = try XCTUnwrap(fixture.manager.currentSnapshot)
            let update = try await fixture.request(package, method: "activity.update", fields: [
                "id": .string("controls"), "priority": .string("background")
            ])
            XCTAssertEqual(fixture.errorCode(update), "capabilityRequired")
            XCTAssertEqual(fixture.manager.currentSnapshot, retained)
            XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: retained))
            XCTAssertNoThrow(try context.perform {})
        }
    }

    func testPriorityOnlyUpdateCannotRetainAnObsoleteCountdownGeneration() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let originalTimer = try fixture.start(package)
        let reference = fixture.reference(originalTimer)
        try await fixture.publish(package, reference: reference)
        let originalActivity = try XCTUnwrap(fixture.manager.currentSnapshot)
        let replacement = try fixture.start(package)
        XCTAssertNotEqual(originalTimer.generation, replacement.generation)

        let response = try await fixture.request(package, method: "activity.update", fields: [
            "id": .string("controls"), "priority": .string("background")
        ])
        XCTAssertEqual(fixture.errorCode(response), "staleCountdown")
        XCTAssertEqual(fixture.manager.currentSnapshot, originalActivity)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: originalActivity))
        XCTAssertNotNil(fixture.broker.snapshotForDisplay(owner: try fixture.owner(package), id: replacement.id,
                                                         generation: replacement.generation))
    }

    func testResolverRejectsOldPresentationAndSameIDReplacementSnapshots() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let reference = fixture.reference(try fixture.start(package))
        try await fixture.publish(package, reference: reference)
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        let response = try await fixture.request(package, method: "activity.update", fields: [
            "id": .string("controls"), "presentation": .object([
                "title": .string("Updated"), "minimal": fixture.node(reference)
            ])
        ])
        XCTAssertEqual(response["ok"], .boolean(true))
        let updated = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(updated.instanceToken, original.instanceToken)
        XCTAssertNotEqual(updated.activity, original.activity)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: original))
        XCTAssertNotNil(fixture.lifecycle.resolveCountdown(reference, for: updated))

        var alteredActivity = updated.activity
        alteredActivity.presentation.title = "Forged snapshot"
        let altered = ActivitySnapshot(activity: alteredActivity, instanceToken: updated.instanceToken)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: altered))
        try fixture.context(package).endActivity(id: updated.activity.id)
        try await fixture.publish(package, reference: reference)
        let replacement = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(replacement.activity.id, original.activity.id)
        XCTAssertNotEqual(replacement.instanceToken, updated.instanceToken)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: updated))
        XCTAssertNotNil(fixture.lifecycle.resolveCountdown(reference, for: replacement))

        let nativeSource = ActivitySource(kind: .builtIn, identifier: "countdown-node-test-native")
        try fixture.manager.publish(.init(id: "native", source: nativeSource, priority: .important,
            lifecycle: .init(policy: .persistent), presentation: .init(title: "Native"), createdAt: Date()))
        let native = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(native.activity.source, nativeSource)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: native))
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: replacement))
    }

    func testSuspensionRetainsOwnerButDisableInvalidatesItAndBothCloseDisplay() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let owner = try fixture.owner(package)
        let reference = fixture.reference(try fixture.start(package))
        try await fixture.publish(package, reference: reference)
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: original))
        XCTAssertEqual(fixture.broker.diagnostics.recordCount, 1)
        fixture.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(try fixture.owner(package), owner)
        try await fixture.publish(package, reference: reference)
        let resumed = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertNotEqual(original.instanceToken, resumed.instanceToken)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: original))
        XCTAssertNotNil(fixture.lifecycle.resolveCountdown(reference, for: resumed))

        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: resumed))
        XCTAssertEqual(fixture.broker.diagnostics.recordCount, 0)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        XCTAssertNotEqual(try fixture.owner(package), owner)
        let rejected = try await fixture.request(package, method: "activity.publish", fields:
            fixture.publishFields(reference: reference))
        XCTAssertEqual(fixture.errorCode(rejected), "staleCountdown")
        try fixture.seedRetainedActivity(package, reference: reference)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: try XCTUnwrap(fixture.manager.currentSnapshot)))
    }

    func testResourceRevocationClosesDisplayWhileLifecycleAndSnapshotRemainCurrent() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let context = try fixture.context(package)
        let reference = fixture.reference(try fixture.start(package))
        try await fixture.publish(package, reference: reference)
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertNotNil(fixture.lifecycle.resolveCountdown(reference, for: snapshot))
        context.resourceAdmission.revoke()
        XCTAssertNoThrow(try context.perform {})
        XCTAssertEqual(fixture.manager.currentSnapshot, snapshot)
        XCTAssertNil(fixture.lifecycle.resolveCountdown(reference, for: snapshot))
    }

    func testExpiredDisplayReadsProjectCompletionWithoutOfferingObserverOrMutatingBroker() async throws {
        let fixture = CountdownNodeBridgeFixture()
        defer { fixture.shutdown() }
        let package = try fixture.load()
        let owner = try fixture.owner(package)
        let reference = fixture.reference(try fixture.start(package, duration: 1_000))
        let capture = CountdownNodeBridgeCompletions()
        _ = try fixture.broker.observeCompletions(owner: owner) { capture.events.append($0) }
        try await fixture.publish(package, reference: reference)
        let snapshot = try XCTUnwrap(fixture.manager.currentSnapshot)
        let before = fixture.broker.diagnostics
        fixture.clock.now = .seconds(1)
        for _ in 0..<3 {
            XCTAssertEqual(fixture.lifecycle.resolveCountdown(reference, for: snapshot),
                           .init(text: "00:00", progress: 1, requiresTick: false))
        }
        XCTAssertTrue(capture.events.isEmpty)
        XCTAssertEqual(fixture.broker.diagnostics, before)
        XCTAssertEqual(fixture.captures.starts[package.manifest.id], 1)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(fixture.broker.diagnostics.completedCount, 1)
        XCTAssertEqual(fixture.lifecycle.resolveCountdown(reference, for: snapshot),
                       .init(text: "00:00", progress: 1, requiresTick: false))
        XCTAssertEqual(capture.events.count, 1)
    }
}

@MainActor
private final class CountdownNodeBridgeFixture {
    static let capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .islandNodeUI, .handleActions, .countdown]
    let clock = CountdownNodeBridgeClock()
    let captures = CountdownNodeBridgeContexts()
    let manager = ActivityManager(configuration: .immediate)
    private var bridgeTime: TimeInterval = 0
    private lazy var router = ActionRouter(manager: manager)
    lazy var broker = PluginCountdownBroker(clock: { [clock] in clock.now }, automaticScheduling: false)
    lazy var bridge = PluginJSBridge(activityRateClock: { [unowned self] in self.bridgeTime })
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, countdownBroker: broker,
        runtimeFactory: { [captures] _ in CountdownNodeBridgeRuntime(captures: captures) })

    func load(id: String = "com.example.countdown-node",
              capabilities: [PluginCapability] = CountdownNodeBridgeFixture.capabilities) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Countdown Node Bridge", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [], capabilities: capabilities)
        let package = ValidatedPluginPackage(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/countdown-node-bridge/\(id)"),
            entryRelativePath: "index.js", entrySource: Data(), regularFileCount: 2, totalFileBytes: 0)
        lifecycle.pluginDidLoad(package, isEnabled: true)
        _ = try context(package)
        return package
    }

    func context(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        try XCTUnwrap(captures.contexts[package.manifest.id])
    }

    func owner(_ package: ValidatedPluginPackage) throws -> PluginCountdownOwner { try XCTUnwrap(context(package).countdownOwner) }

    func start(_ package: ValidatedPluginPackage, duration: Int = 60_000) throws -> PluginCountdownSnapshot {
        try broker.start(owner: owner(package), id: "focus", durationMilliseconds: duration)
    }

    func reference(_ snapshot: PluginCountdownSnapshot) -> IslandNode.Countdown {
        .init(id: snapshot.id, generation: snapshot.generation.rawValue)
    }

    func node(_ reference: IslandNode.Countdown) -> PluginBridgeJSON {
        .object(["type": .string("countdown"), "id": .string(reference.id), "generation": .string(reference.generation)])
    }

    func publishFields(reference: IslandNode.Countdown, localID: String = "controls") -> [String: PluginBridgeJSON] {
        ["id": .string(localID), "lifecycle": .object(["policy": .string("persistent")]),
         "presentation": .object(["title": .string("Countdown"), "minimal": node(reference)])]
    }

    func publish(_ package: ValidatedPluginPackage, reference: IslandNode.Countdown) async throws {
        let response = try await request(package, method: "activity.publish", fields: publishFields(reference: reference))
        XCTAssertEqual(response["ok"], .boolean(true))
    }

    func seedRetainedActivity(_ package: ValidatedPluginPackage, reference: IslandNode.Countdown) throws {
        let context = try context(package)
        try context.publish(.init(id: PluginJSBridge.activityID(pluginID: context.id, localID: "controls"),
            source: context.source, priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Retained", minimal: .countdown(reference)), createdAt: Date()))
    }

    func request(_ package: ValidatedPluginPackage, method: String,
                 fields: [String: PluginBridgeJSON]) async throws -> [String: PluginBridgeJSON] {
        bridgeTime += 1
        let request = try PluginBridgeJSON.object([
            "apiVersion": .string(PluginJSBridge.apiVersion), "method": .string(method), "params": .object(fields)
        ]).encodedString()
        let reply = await bridge.handle(request, package: package, context: try context(package))
        guard case .object(let fields) = try PluginBridgeJSON.parse(reply) else {
            throw CountdownNodeBridgeError.invalidResponse
        }
        return fields
    }

    func errorCode(_ fields: [String: PluginBridgeJSON]) -> String? {
        guard case .object(let error) = fields["error"], case .string(let code) = error["code"] else { return nil }
        return code
    }

    func shutdown() { lifecycle.shutdown() }
}

private enum CountdownNodeBridgeError: Error { case invalidResponse }

@MainActor
private final class CountdownNodeBridgeClock { var now: Duration = .zero }

@MainActor
private final class CountdownNodeBridgeContexts {
    var contexts: [String: PluginExecutionContext] = [:]
    var starts: [String: Int] = [:]
}

@MainActor
private final class CountdownNodeBridgeCompletions { var events: [PluginCountdownCompletion] = [] }

@MainActor
private final class CountdownNodeBridgeRuntime: PluginLifecycleRuntime {
    private let captures: CountdownNodeBridgeContexts
    init(captures: CountdownNodeBridgeContexts) { self.captures = captures }
    func onStart(context: PluginExecutionContext) throws {
        captures.contexts[context.id] = context
        captures.starts[context.id, default: 0] += 1
    }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}
