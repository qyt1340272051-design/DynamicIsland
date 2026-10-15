import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownDeliveryTests: XCTestCase {
    func testCompletionUsesTypedBoundedSnapshotWithoutAnActivityOrActionActivation() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        let started = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()

        XCTAssertNil(fixture.activities.currentSnapshot)
        let event = try XCTUnwrap(capture.events.first)
        if case .countdown = event.kind {} else { XCTFail("Completion entered the action receiver") }
        XCTAssertEqual(event.registrationID, "c1")
        XCTAssertLessThanOrEqual(event.eventJSON.utf8.count, 1_024)
        XCTAssertEqual(try PluginBridgeJSON.parse(event.eventJSON), .object([
            "id": .string("focus"), "generation": .string(started.generation.rawValue),
            "state": .string("completed"), "durationMs": .number(1_000), "remainingMs": .number(0)
        ]))
        XCTAssertTrue(event.isValid())
        XCTAssertTrue(session.matches(context: context))
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(try fixture.broker.get(owner: owner, id: "focus")?.state, .completed)
    }

    func testReplacingEvenTheSameRegistrationIDAndUnregisterInvalidateQueuedCompletions() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        let old = try XCTUnwrap(capture.events.first)
        XCTAssertTrue(old.isValid())
        old.didReceive?()
        try session.register(registrationID: "c1")
        XCTAssertFalse(old.isValid())

        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(2)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 2)
        let replaced = capture.events[1]
        XCTAssertTrue(replaced.isValid())
        try session.unregister()
        XCTAssertFalse(replaced.isValid())

        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(3)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 2)
        try session.register(registrationID: "c2")
        XCTAssertEqual(capture.events.count, 3)
        XCTAssertEqual(capture.events[2].registrationID, "c2")
        XCTAssertTrue(capture.events[2].isValid())
    }

    func testRevokingAnOlderSessionRemovesOnlyItsOwnObserverAndPreservesTheRecord() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let oldCapture = CountdownDeliveryCapture()
        let old = try session(package, context: context, capture: oldCapture)
        defer { old.revoke() }
        try old.register(registrationID: "old")
        let newCapture = CountdownDeliveryCapture()
        let replacement = try session(package, context: context, capture: newCapture)
        defer { replacement.revoke() }
        try replacement.register(registrationID: "new")
        let started = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        old.revoke()
        XCTAssertEqual(try fixture.broker.get(owner: owner, id: "focus"), started)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        XCTAssertTrue(oldCapture.events.isEmpty)
        XCTAssertEqual(newCapture.events.count, 1)
        XCTAssertTrue(newCapture.events[0].isValid())
        XCTAssertThrowsError(try old.register(registrationID: "again")) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .inactiveExecution)
        }
    }

    func testRestartAndStopInvalidateQueuedCompletedGeneration() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        let first = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        XCTAssertTrue(try XCTUnwrap(capture.events.first).isValid())
        let second = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertFalse(capture.events[0].isValid())
        fixture.clock.now = .seconds(2)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 2)
        XCTAssertTrue(capture.events[1].isValid())
        try fixture.broker.stop(owner: owner, id: "focus", generation: second.generation)
        XCTAssertFalse(capture.events[1].isValid())
    }

    func testRevokedResourceAdmissionRejectsDeliveryWhileLifecycleContextIsStillActive() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        let event = try XCTUnwrap(capture.events.first)
        context.resourceAdmission.revoke()
        XCTAssertNoThrow(try context.perform {})
        XCTAssertFalse(event.isValid())
        XCTAssertThrowsError(try session.register(registrationID: "c2")) {
            XCTAssertEqual($0 as? PluginResourceError, .inactiveExecution)
        }
        XCTAssertEqual(try fixture.broker.get(owner: owner, id: "focus")?.state, .completed)
    }

    func testCapabilitySourceAndRegistrationValidationCannotManufactureAnObserver() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let unprivileged = try package(capabilities: [])
        let context = try fixture.load(unprivileged)
        XCTAssertNil(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let unprivilegedSession = try session(unprivileged, context: context, capture: capture)
        defer { unprivilegedSession.revoke() }
        XCTAssertThrowsError(try unprivilegedSession.register(registrationID: "c1")) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .capabilityRequired)
        }
        XCTAssertThrowsError(try session(try package(), context: context, capture: capture)) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .inactiveExecution)
        }
        XCTAssertThrowsError(try session(try package(id: "com.example.another"), context: context, capture: capture)) {
            XCTAssertEqual($0 as? PluginExecutionError, .sourceMismatch)
        }

        let privileged = try package(id: "com.example.privileged")
        let privilegedContext = try fixture.load(privileged)
        let privilegedSession = try session(privileged, context: privilegedContext, capture: capture)
        defer { privilegedSession.revoke() }
        for invalid in ["", "with space", "with/slash", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try privilegedSession.register(registrationID: invalid)) {
                XCTAssertEqual($0 as? PluginBridgeErrorCode, .invalidArguments)
            }
        }
        XCTAssertFalse(unprivilegedSession.matches(context: privilegedContext))
        XCTAssertTrue(capture.events.isEmpty)
    }

    func testDisableInvalidatesOldContextAndCannotClearReplacementRecord() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        let old = try XCTUnwrap(capture.events.first)
        fixture.lifecycle.pluginDidChangeEnablement(id: context.id, isEnabled: false)
        XCTAssertFalse(old.isValid())
        XCTAssertEqual(fixture.broker.diagnostics.recordCount, 0)
        fixture.lifecycle.pluginDidChangeEnablement(id: context.id, isEnabled: true)
        let replacementContext = try fixture.context(id: context.id)
        let replacementOwner = try XCTUnwrap(replacementContext.countdownOwner)
        XCTAssertFalse(context === replacementContext)
        XCTAssertNotEqual(owner, replacementOwner)
        let replacement = try fixture.broker.start(owner: replacementOwner, id: "focus", durationMilliseconds: 2_000)
        session.discardRecordIfExecutionStillActive()
        XCTAssertEqual(try fixture.broker.get(owner: replacementOwner, id: "focus"), replacement)
        XCTAssertThrowsError(try session.register(registrationID: "old")) {
            XCTAssertEqual($0 as? PluginExecutionError, .inactiveExecution)
        }
    }

    func testSuspensionRetainsBusinessDeadlineButOnlyResumedContextReceivesCompletion() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let oldCapture = CountdownDeliveryCapture()
        let oldSession = try session(package, context: context, capture: oldCapture)
        defer { oldSession.revoke() }
        try oldSession.register(registrationID: "old")
        let started = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .milliseconds(500)
        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        oldSession.discardRecordIfExecutionStillActive()
        oldSession.revoke()
        fixture.clock.now = .seconds(2)
        fixture.broker.processDue()
        XCTAssertEqual(fixture.broker.diagnostics.recordCount, 1)
        XCTAssertTrue(oldCapture.events.isEmpty)

        fixture.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        let resumed = try fixture.context(id: context.id)
        XCTAssertFalse(context === resumed)
        XCTAssertEqual(resumed.countdownOwner, owner)
        let capture = CountdownDeliveryCapture()
        let resumedSession = try session(package, context: resumed, capture: capture)
        defer { resumedSession.revoke() }
        try resumedSession.register(registrationID: "new")
        let event = try XCTUnwrap(capture.events.first)
        XCTAssertTrue(event.isValid())
        XCTAssertEqual(event.registrationID, "new")
        XCTAssertTrue(event.eventJSON.contains(started.generation.rawValue))
        XCTAssertEqual(try fixture.broker.get(owner: owner, id: "focus")?.state, .completed)
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertTrue(oldCapture.events.isEmpty)
    }

    func testReentrantPendingCompletionCannotOverwriteNewerObserverToken() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        let capture = CountdownDeliveryCapture()
        let reference = CountdownDeliverySessionReference()
        let session = try PluginCountdownSession(package: package, context: context) { event in
            capture.events.append(event)
            if event.registrationID == "first" {
                do {
                    try reference.session?.unregister()
                    try reference.session?.register(registrationID: "second")
                } catch { XCTFail("Reentrant registration failed: \(error)") }
            }
        }
        reference.session = session
        defer { session.revoke() }
        try session.register(registrationID: "first")
        XCTAssertEqual(capture.events.count, 2)
        XCTAssertFalse(capture.events[0].isValid())
        XCTAssertEqual(capture.events[1].registrationID, "second")
        capture.events[1].didReceive?()
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(2)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 3)
        XCTAssertEqual(capture.events[2].registrationID, "second")
        XCTAssertTrue(capture.events[2].isValid())

        session.revoke()
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(3)
        fixture.broker.processDue()
        let freshCapture = CountdownDeliveryCapture()
        let fresh = try self.session(package, context: context, capture: freshCapture)
        defer { fresh.revoke() }
        try fresh.register(registrationID: "fresh")
        XCTAssertEqual(capture.events.count, 3)
        XCTAssertEqual(freshCapture.events.count, 1)
        XCTAssertTrue(freshCapture.events[0].isValid())
    }

    func testUnreceivedCompletionSurvivesSuspensionAndOldReceiptCannotConsumeNewOffer() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let oldCapture = CountdownDeliveryCapture()
        let oldSession = try session(package, context: context, capture: oldCapture)
        try oldSession.register(registrationID: "old")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        let queued = try XCTUnwrap(oldCapture.events.first)
        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        oldSession.revoke()
        XCTAssertFalse(queued.isValid())
        fixture.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        let resumed = try fixture.context(id: context.id)
        let capture = CountdownDeliveryCapture()
        let newSession = try session(package, context: resumed, capture: capture)
        defer { newSession.revoke() }
        try newSession.register(registrationID: "new")
        XCTAssertEqual(capture.events.count, 1)
        queued.didReceive?()
        queued.didNotReceive?()
        try newSession.register(registrationID: "replacement")
        XCTAssertEqual(capture.events.count, 2)
        XCTAssertFalse(capture.events[0].isValid())
        capture.events[1].didReceive?()
        try newSession.register(registrationID: "after-receipt")
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 2)
    }

    func testRejectedWorkerOfferCanBeRetriedByGetWithoutRecursiveDelivery() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        capture.events[0].didNotReceive?()
        XCTAssertEqual(capture.events.count, 1)
        _ = try fixture.broker.get(owner: owner, id: "focus")
        XCTAssertEqual(capture.events.count, 2)
        capture.events[1].didReceive?()
        _ = try fixture.broker.get(owner: owner, id: "focus")
        XCTAssertEqual(capture.events.count, 2)
    }

    func testDirectTeardownCleanupClearsOnlyBusinessRecordAndPreservesOwnerObserver() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let owner = try XCTUnwrap(context.countdownOwner)
        let capture = CountdownDeliveryCapture()
        let session = try session(package, context: context, capture: capture)
        defer { session.revoke() }
        try session.register(registrationID: "c1")
        _ = try fixture.broker.start(owner: owner, id: "focus", durationMilliseconds: 60_000)
        XCTAssertNoThrow(try context.perform {})
        session.discardRecordIfExecutionStillActive()
        XCTAssertNil(try fixture.broker.get(owner: owner, id: "focus"))
        XCTAssertEqual(fixture.broker.diagnostics.recordCount, 0)
        XCTAssertNil(fixture.broker.diagnostics.nextDeadline)
        XCTAssertEqual(fixture.broker.diagnostics.ownerCount, 1)

        _ = try fixture.broker.start(owner: owner, id: "new", durationMilliseconds: 1_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertTrue(capture.events[0].isValid())
    }

    func testTwoOwnersWithSameLocalIDReceiveOnlyTheirOwnSnapshot() throws {
        let fixture = CountdownDeliveryFixture()
        defer { fixture.shutdown() }
        let alpha = try package(id: "com.example.alpha")
        let beta = try package(id: "com.example.beta")
        let alphaContext = try fixture.load(alpha)
        let betaContext = try fixture.load(beta)
        let alphaOwner = try XCTUnwrap(alphaContext.countdownOwner)
        let betaOwner = try XCTUnwrap(betaContext.countdownOwner)
        let alphaCapture = CountdownDeliveryCapture()
        let betaCapture = CountdownDeliveryCapture()
        let alphaSession = try session(alpha, context: alphaContext, capture: alphaCapture)
        let betaSession = try session(beta, context: betaContext, capture: betaCapture)
        defer { alphaSession.revoke(); betaSession.revoke() }
        try alphaSession.register(registrationID: "c1")
        try betaSession.register(registrationID: "c1")
        let alphaRecord = try fixture.broker.start(owner: alphaOwner, id: "focus", durationMilliseconds: 1_000)
        let betaRecord = try fixture.broker.start(owner: betaOwner, id: "focus", durationMilliseconds: 2_000)
        fixture.clock.now = .seconds(1)
        fixture.broker.processDue()
        XCTAssertEqual(alphaCapture.events.count, 1)
        XCTAssertTrue(betaCapture.events.isEmpty)
        XCTAssertTrue(alphaCapture.events[0].eventJSON.contains(alphaRecord.generation.rawValue))
        fixture.clock.now = .seconds(2)
        fixture.broker.processDue()
        XCTAssertEqual(betaCapture.events.count, 1)
        XCTAssertTrue(betaCapture.events[0].eventJSON.contains(betaRecord.generation.rawValue))
        XCTAssertFalse(betaCapture.events[0].eventJSON.contains(alphaRecord.generation.rawValue))
        XCTAssertTrue(alphaCapture.events[0].isValid())
        XCTAssertTrue(betaCapture.events[0].isValid())
    }

    func testResumingFactoryThatReentersSleepDoesNotReactivateRetainedCountdown() throws {
        let activities = ActivityManager(configuration: .immediate)
        let clock = CountdownDeliveryClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        let recorder = CountdownDeliveryRecorder()
        var lifecycle: PluginLifecycleBridge!
        var factories = 0
        lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
                                          countdownBroker: broker, runtimeFactory: { _ in
            factories += 1
            if factories == 2 { lifecycle.setEnvironment(isSleeping: true, isLowBattery: false) }
            return CountdownDeliveryRuntime(recorder: recorder)
        })
        defer { lifecycle.shutdown() }
        let package = try package()
        lifecycle.pluginDidLoad(package, isEnabled: true)
        let owner = try XCTUnwrap(recorder.contexts.first?.countdownOwner)
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 10_000)
        lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(factories, 2)
        XCTAssertEqual(recorder.contexts.count, 1)
        XCTAssertFalse(lifecycle.allowsExecution(id: package.manifest.id))
        XCTAssertNil(broker.diagnostics.nextDeadline)
        XCTAssertThrowsError(try broker.get(owner: owner, id: "focus")) {
            XCTAssertEqual($0 as? PluginCountdownError, .inactiveOwner)
        }
        clock.now = .seconds(12)
        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(recorder.contexts.count, 2)
        let resumed = try XCTUnwrap(try broker.get(owner: owner, id: "focus"))
        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(resumed.generation, started.generation)
    }

    private func session(_ package: ValidatedPluginPackage, context: PluginExecutionContext,
                         capture: CountdownDeliveryCapture) throws -> PluginCountdownSession {
        try PluginCountdownSession(package: package, context: context) { capture.events.append($0) }
    }

    private func package(id: String = "com.example.countdown", capabilities: [PluginCapability] = [.countdown]) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(
            id: id, name: "Countdown Delivery", version: SemanticVersion("1.0.0"), engine: .javaScriptCore,
            entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities
        )
        let source = Data("function onStart() {}".utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/countdown-delivery-tests/\(id)"),
                     entryRelativePath: "index.js", entrySource: source, regularFileCount: 2, totalFileBytes: UInt64(source.count))
    }
}

@MainActor
private final class CountdownDeliveryCapture { var events: [PluginActionDelivery] = [] }

@MainActor
private final class CountdownDeliverySessionReference { weak var session: PluginCountdownSession? }

@MainActor
private final class CountdownDeliveryClock { var now: Duration = .zero }

@MainActor
private final class CountdownDeliveryRecorder { var contexts: [PluginExecutionContext] = [] }

@MainActor
private final class CountdownDeliveryRuntime: PluginLifecycleRuntime {
    let recorder: CountdownDeliveryRecorder
    init(recorder: CountdownDeliveryRecorder) { self.recorder = recorder }
    func onStart(context: PluginExecutionContext) { recorder.contexts.append(context) }
    func onStop(reason: PluginStopReason) {}
    func teardown() {}
}

@MainActor
private final class CountdownDeliveryFixture {
    let clock = CountdownDeliveryClock()
    let activities: ActivityManager
    let broker: PluginCountdownBroker
    let lifecycle: PluginLifecycleBridge
    private let recorder = CountdownDeliveryRecorder()

    init() {
        let clock = clock
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        self.broker = broker
        let activities = ActivityManager(configuration: .immediate)
        self.activities = activities
        let recorder = recorder
        lifecycle = PluginLifecycleBridge(
            activityManager: activities, actionRouter: ActionRouter(manager: activities), countdownBroker: broker,
            runtimeFactory: { _ in CountdownDeliveryRuntime(recorder: recorder) }
        )
    }

    func load(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try context(id: package.manifest.id)
    }

    func context(id: String) throws -> PluginExecutionContext {
        try XCTUnwrap(recorder.contexts.last { $0.id == id })
    }

    func shutdown() { lifecycle.shutdown() }
}
