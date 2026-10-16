import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownActivationTests: XCTestCase {
    func testOnlyRoutedCommittedActionsMintOpaqueSingleUseActivation() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        assertInvalid(UUID().uuidString, session: fixture.session)
        XCTAssertTrue(fixture.deliveries.values.isEmpty)
        try fixture.publish()
        assertInvalid(UUID().uuidString, session: fixture.session)

        for value in [IslandRenderActionValue.none, .toggle(true), .sliderCommit(0.75)] {
            XCTAssertEqual(try fixture.dispatch(value: value), .handled)
            let delivery = try XCTUnwrap(fixture.deliveries.values.last)
            guard case .action = delivery.kind else { return XCTFail("Router events must remain action deliveries.") }
            XCTAssertTrue(delivery.isValid())
            let event = try fixture.event()
            XCTAssertEqual(Set(event.keys), Set(["activityID", "actionID", "value", "activation"]))
            XCTAssertEqual(event["activityID"] as? String, "controls")
            XCTAssertEqual(event["actionID"] as? String, "start")
            let token = try fixture.activation()
            XCTAssertNotNil(UUID(uuidString: token))
            XCTAssertNotEqual(token, delivery.registrationID)
            XCTAssertFalse(delivery.eventJSON.contains(fixture.context.source.identifier))
            XCTAssertLessThanOrEqual(delivery.eventJSON.utf8.count, 1_024)
            XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(token))
            assertInvalid(token, session: fixture.session)
        }
    }

    func testCountdownAndActionCapabilitiesAreBothRequiredAndLegacyEventStaysUnchanged() throws {
        for capabilities in [[PluginCapability](), [.countdown], [.handleActions]] {
            let fixture = try CountdownActivationFixture(capabilities: capabilities)
            defer { fixture.shutdown() }
            try fixture.publish()
            let result = try fixture.dispatch()
            if capabilities.contains(.handleActions) {
                XCTAssertEqual(result, .handled)
                let event = try fixture.event()
                XCTAssertEqual(Set(event.keys), Set(["activityID", "actionID", "value"]))
                XCTAssertNil(event["activation"])
            } else {
                XCTAssertEqual(result, .missingHandler)
                XCTAssertTrue(fixture.deliveries.values.isEmpty)
            }
            assertInvalid(UUID().uuidString, session: fixture.session)
        }
    }

    func testFiveSecondExpiryBurnsMatchingAttemptAndJustBeforeExpiryRemainsValid() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let beforeExpiry = try fixture.activation()
        fixture.activationClock.instant = fixture.activationClock.instant.advanced(by: .milliseconds(4_999))
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(beforeExpiry))

        XCTAssertEqual(try fixture.dispatch(), .handled)
        let expired = try fixture.activation()
        let issuedAt = fixture.activationClock.instant
        fixture.activationClock.instant = issuedAt.advanced(by: .seconds(5))
        assertInvalid(expired, session: fixture.session)
        // Even a faulty test clock cannot restore an already consumed ticket.
        fixture.activationClock.instant = issuedAt
        assertInvalid(expired, session: fixture.session)
    }

    func testForgedAndCrossSessionTokensDoNotDestroyEitherGenuineTicket() throws {
        let first = try CountdownActivationFixture()
        let second = try CountdownActivationFixture()
        defer { first.shutdown(); second.shutdown() }
        try first.publish()
        try second.publish()
        XCTAssertEqual(try first.dispatch(), .handled)
        XCTAssertEqual(try second.dispatch(), .handled)
        let firstToken = try first.activation()
        let secondToken = try second.activation()
        XCTAssertNotEqual(firstToken, secondToken)
        assertInvalid(UUID().uuidString, session: first.session)
        assertInvalid(secondToken, session: first.session)
        assertInvalid(firstToken, session: second.session)
        XCTAssertNoThrow(try first.session.consumeCountdownActivation(firstToken))
        XCTAssertNoThrow(try second.session.consumeCountdownActivation(secondToken))
    }

    func testNewerActionSupersedesOldTicketAcrossActionRegistrations() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let old = try fixture.activation()
        XCTAssertEqual(try fixture.dispatch(actionID: "other", value: .toggle(false)), .handled)
        let latest = try fixture.activation()
        XCTAssertNotEqual(old, latest)
        assertInvalid(old, session: fixture.session)
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(latest))
    }

    func testSliderIntermediateHasNoActivationAndInvalidatesPreviousCommittedTicket() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let old = try fixture.activation()
        XCTAssertEqual(try fixture.dispatch(value: .slider(0.25)), .handled)
        let intermediate = try fixture.event()
        XCTAssertEqual(Set(intermediate.keys), Set(["activityID", "actionID", "value"]))
        XCTAssertEqual((intermediate["value"] as? [String: Any])?["type"] as? String, "slider")
        assertInvalid(old, session: fixture.session)
        XCTAssertEqual(try fixture.dispatch(value: .sliderCommit(0.25)), .handled)
        let committed = try fixture.activation()
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(committed))
    }

    func testReplacementAndUnregisterClearOnlyTheMatchingActionTicket() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let untouched = try fixture.activation()
        try fixture.session.register(actionID: "other", registrationID: "other-r2")
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(untouched))

        for registration in ["start-r1", "start-r2"] {
            XCTAssertEqual(try fixture.dispatch(), .handled)
            let replaced = try fixture.activation()
            try fixture.session.register(actionID: "start", registrationID: registration)
            assertInvalid(replaced, session: fixture.session)
        }

        XCTAssertEqual(try fixture.dispatch(actionID: "other"), .handled)
        let other = try fixture.activation()
        try fixture.session.unregister(actionID: "start")
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(other))
        XCTAssertEqual(try fixture.dispatch(actionID: "other"), .handled)
        let unregistered = try fixture.activation()
        try fixture.session.unregister(actionID: "other")
        assertInvalid(unregistered, session: fixture.session)
    }

    func testEndedActivityWithSameIDReplacementCannotUseOriginalActivation() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let ended = try fixture.activation()
        try fixture.context.endActivity(id: original.activity.id)
        try fixture.publish()
        let replacement = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertNotEqual(original.instanceToken, replacement.instanceToken)
        assertInvalid(ended, session: fixture.session)
        XCTAssertEqual(try fixture.dispatch(snapshot: original), .inactiveActivity)
        XCTAssertEqual(try fixture.dispatch(), .handled)
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(fixture.activation()))
    }

    func testPreemptionAndDeclarationLossBurnTheMatchingAttemptBeforeLaterRestoration() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        let original = try XCTUnwrap(fixture.manager.currentSnapshot)
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let preempted = try fixture.activation()
        let statusSource = ActivitySource(kind: .builtIn, identifier: "test-status")
        try fixture.manager.publish(.init(id: "status", source: statusSource, priority: .important,
            lifecycle: .init(policy: .transient), presentation: .init(title: "Event"),
            createdAt: fixture.activityClock.now()))
        assertInvalid(preempted, session: fixture.session)
        try fixture.manager.end(id: "status", source: statusSource)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, original.instanceToken)
        assertInvalid(preempted, session: fixture.session)

        XCTAssertEqual(try fixture.dispatch(), .handled)
        let undeclared = try fixture.activation()
        var update = try XCTUnwrap(fixture.manager.current)
        let actions = update.actions
        update.actions = []
        try fixture.manager.update(update)
        assertInvalid(undeclared, session: fixture.session)
        update.actions = actions
        try fixture.manager.update(update)
        assertInvalid(undeclared, session: fixture.session)
    }

    func testDisableReenableAndSessionRevokeCannotReviveOldActivation() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let disabled = try fixture.activation()
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: false)
        XCTAssertThrowsError(try fixture.session.consumeCountdownActivation(disabled)) { error in
            XCTAssertTrue((error as? PluginExecutionError) == .inactiveExecution
                || (error as? PluginBridgeErrorCode) == .inactiveExecution
                || (error as? PluginCountdownActivationError) == .invalidActivation)
        }
        fixture.lifecycle.pluginDidChangeEnablement(id: fixture.package.manifest.id, isEnabled: true)
        let context = try XCTUnwrap(fixture.contexts.values.last)
        XCTAssertFalse(context === fixture.context)
        let session = try fixture.makeSession(context: context)
        defer { session.revoke() }
        try fixture.publish(context: context)
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let active = try fixture.activation()
        assertInvalid(disabled, session: fixture.session)
        assertInvalid(disabled, session: session)
        XCTAssertNoThrow(try session.consumeCountdownActivation(active))
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let revoked = try fixture.activation()
        session.revoke()
        assertInvalid(revoked, session: session)
    }

    func testMatchingConsumeIsBurnedBeforeReentrantAuthorizationAndRechecksDeadlineAfterIt() throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let token = try fixture.activation()
        var reentrantChecks = 0
        fixture.authorization.hook = {
            reentrantChecks += 1
            self.assertInvalid(token, session: fixture.session)
        }
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(token))
        fixture.authorization.hook = nil
        XCTAssertEqual(reentrantChecks, 1)

        XCTAssertEqual(try fixture.dispatch(), .handled)
        let expiredInAuthorization = try fixture.activation()
        let issuedAt = fixture.activationClock.instant
        fixture.authorization.hook = {
            fixture.activationClock.instant = issuedAt.advanced(by: .seconds(5))
        }
        assertInvalid(expiredInAuthorization, session: fixture.session)
        fixture.authorization.hook = nil
        fixture.activationClock.instant = issuedAt
        assertInvalid(expiredInAuthorization, session: fixture.session)
    }

    func testBridgeStartRevokedDuringActivationAuthorizationLeavesNoCountdown() async throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let token = try fixture.activation()
        let owner = try XCTUnwrap(fixture.context.countdownOwner)
        var authorizationChecks = 0
        fixture.authorization.hook = {
            authorizationChecks += 1
            fixture.context.resourceAdmission.revoke()
        }

        let response = await PluginJSBridge().handle(try PluginBridgeJSON.object([
            "apiVersion": .string(PluginJSBridge.apiVersion), "method": .string("countdown.start"),
            "params": .object(["id": .string("focus"), "durationMs": .number(60_000),
                               "activation": .string(token)])
        ]).encodedString(), package: fixture.package, context: fixture.context, actionSession: fixture.session)

        fixture.authorization.hook = nil
        assertInactiveResponse(response)
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertNoThrow(try fixture.context.perform {})
        XCTAssertNil(try fixture.context.countdownBroker.get(owner: owner, id: "focus"))
        XCTAssertEqual(fixture.context.countdownBroker.diagnostics.recordCount, 0)
        XCTAssertEqual(fixture.context.countdownBroker.diagnostics.runningCount, 0)
        XCTAssertNil(fixture.context.countdownBroker.diagnostics.nextDeadline)
        assertInvalid(token, session: fixture.session)
    }

    func testBridgeResumeRevokedDuringActivationAuthorizationPreservesPausedCountdown() async throws {
        let fixture = try CountdownActivationFixture()
        defer { fixture.shutdown() }
        let owner = try XCTUnwrap(fixture.context.countdownOwner)
        let broker = fixture.context.countdownBroker
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 60_000)
        let paused = try broker.pause(owner: owner, id: "focus", generation: started.generation)
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let token = try fixture.activation()
        var authorizationChecks = 0
        fixture.authorization.hook = {
            authorizationChecks += 1
            fixture.context.resourceAdmission.revoke()
        }

        let response = await PluginJSBridge().handle(try PluginBridgeJSON.object([
            "apiVersion": .string(PluginJSBridge.apiVersion), "method": .string("countdown.resume"),
            "params": .object(["id": .string("focus"), "generation": .string(paused.generation.rawValue),
                               "activation": .string(token)])
        ]).encodedString(), package: fixture.package, context: fixture.context, actionSession: fixture.session)

        fixture.authorization.hook = nil
        assertInactiveResponse(response)
        XCTAssertEqual(authorizationChecks, 1)
        XCTAssertNoThrow(try fixture.context.perform {})
        XCTAssertEqual(try broker.get(owner: owner, id: "focus"), paused)
        XCTAssertEqual(broker.diagnostics.runningCount, 0)
        XCTAssertEqual(broker.diagnostics.pausedCount, 1)
        XCTAssertNil(broker.diagnostics.nextDeadline)
        assertInvalid(token, session: fixture.session)
    }

    func testOpenOnlyPluginGetsButtonActivationWithoutCountdownCapability() throws {
        let fixture = try CountdownActivationFixture(capabilities: [.handleActions, .openLinks])
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let token = try fixture.activation()
        let validate = try fixture.session.consumeLinkActivation(token)
        XCTAssertNoThrow(try validate())
        XCTAssertThrowsError(try fixture.session.consumeLinkActivation(token))
        assertInvalid(token, session: fixture.session)
    }

    func testOpenAndCountdownMutuallyConsumeTheSameUserAction() throws {
        let fixture = try CountdownActivationFixture(capabilities: [.handleActions, .countdown, .openLinks])
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let opened = try fixture.activation()
        _ = try fixture.session.consumeLinkActivation(opened)
        assertInvalid(opened, session: fixture.session)
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let started = try fixture.activation()
        XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(started))
        XCTAssertThrowsError(try fixture.session.consumeLinkActivation(started))
    }

    func testOpenRequiresButtonAndBurnsOtherCommittedActionAttempts() throws {
        let fixture = try CountdownActivationFixture(capabilities: [.handleActions, .countdown, .openLinks])
        defer { fixture.shutdown() }
        try fixture.publish()
        for value: IslandRenderActionValue in [.toggle(true), .sliderCommit(0.5)] {
            XCTAssertEqual(try fixture.dispatch(value: value), .handled)
            let token = try fixture.activation()
            XCTAssertThrowsError(try fixture.session.consumeLinkActivation(token))
            assertInvalid(token, session: fixture.session)
            XCTAssertEqual(try fixture.dispatch(value: value), .handled)
            XCTAssertNoThrow(try fixture.session.consumeCountdownActivation(fixture.activation()))
        }
    }

    func testConsumedOpenScopeCannotOutliveNewActionRegistrationOrDeadline() throws {
        let fixture = try CountdownActivationFixture(capabilities: [.handleActions, .openLinks])
        defer { fixture.shutdown() }
        try fixture.publish()
        XCTAssertEqual(try fixture.dispatch(), .handled)
        let superseded = try fixture.session.consumeLinkActivation(fixture.activation())
        XCTAssertEqual(try fixture.dispatch(actionID: "other"), .handled)
        XCTAssertThrowsError(try superseded())

        let reregistered = try fixture.session.consumeLinkActivation(fixture.activation())
        try fixture.session.register(actionID: "other", registrationID: "other-r1")
        XCTAssertThrowsError(try reregistered())

        XCTAssertEqual(try fixture.dispatch(), .handled)
        let expired = try fixture.session.consumeLinkActivation(fixture.activation())
        fixture.activationClock.instant = fixture.activationClock.instant.advanced(by: .seconds(5))
        XCTAssertThrowsError(try expired())
    }

    private func assertInactiveResponse(_ response: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                                       file: file, line: line)
            XCTAssertEqual(fields["ok"] as? Bool, false, file: file, line: line)
            XCTAssertEqual((fields["error"] as? [String: Any])?["code"] as? String,
                           "inactiveExecution", file: file, line: line)
        } catch {
            XCTFail("Bridge response must contain a fixed inactive execution error.", file: file, line: line)
        }
    }

    private func assertInvalid(_ token: String, session: PluginActionSession,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try session.consumeCountdownActivation(token), file: file, line: line) {
            XCTAssertEqual($0 as? PluginCountdownActivationError, .invalidActivation, file: file, line: line)
        }
    }
}

@MainActor
private final class CountdownActivationFixture {
    let activationClock = CountdownActivationClock()
    let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 98_000))
    let deliveries = CountdownActivationDeliveries()
    let contexts = CountdownActivationContexts()
    let authorization = CountdownActivationAuthorization()
    let manager: ActivityManager
    let router: ActionRouter
    let lifecycle: PluginLifecycleBridge
    let package: ValidatedPluginPackage
    let context: PluginExecutionContext
    let session: PluginActionSession

    init(capabilities: [PluginCapability] = [.handleActions, .countdown]) throws {
        let manager = ActivityManager(clock: activityClock, configuration: .immediate)
        self.manager = manager
        let authorization = authorization
        let router = ActionRouter(manager: manager, authorizer: { _, _ in authorization.hook?(); return true })
        self.router = router
        let contexts = contexts
        let lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router,
            runtimeFactory: { _ in CountdownActivationRuntime(contexts: contexts) })
        self.lifecycle = lifecycle
        let manifest = try PluginManifest(id: "com.example.activation", name: "Countdown Activation Test",
            version: SemanticVersion("1.0.0"), engine: .javaScriptCore, entry: "index.js",
            minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities)
        let package = ValidatedPluginPackage(manifest: manifest,
            canonicalRootURL: URL(fileURLWithPath: "/countdown-activation-tests"), entryRelativePath: "index.js",
            entrySource: Data(), regularFileCount: 2, totalFileBytes: 0)
        self.package = package
        lifecycle.pluginDidLoad(package, isEnabled: true)
        let context = try XCTUnwrap(contexts.values.last)
        self.context = context
        let clock = activationClock
        let deliveries = deliveries
        let session = try PluginActionSession(package: package, context: context, now: { clock.instant },
            deliver: { deliveries.values.append($0) })
        self.session = session
        if capabilities.contains(.handleActions) {
            try session.register(actionID: "start", registrationID: "start-r1")
            try session.register(actionID: "other", registrationID: "other-r1")
        }
    }

    func makeSession(context: PluginExecutionContext) throws -> PluginActionSession {
        let clock = activationClock
        let deliveries = deliveries
        let session = try PluginActionSession(package: package, context: context, now: { clock.instant },
            deliver: { deliveries.values.append($0) })
        try session.register(actionID: "start", registrationID: "start-r1")
        try session.register(actionID: "other", registrationID: "other-r1")
        return session
    }

    func publish(context selectedContext: PluginExecutionContext? = nil) throws {
        let context = selectedContext ?? self.context
        try context.publish(.init(id: PluginJSBridge.activityID(pluginID: context.id, localID: "controls"),
            source: context.source, priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Countdown Actions"), createdAt: activityClock.now(),
            actions: [.init(id: "start", title: "Start"), .init(id: "other", title: "Other")]))
    }

    func dispatch(actionID: String = "start", value: IslandRenderActionValue = .none,
                  snapshot suppliedSnapshot: ActivitySnapshot? = nil) throws -> ActionDispatchResult {
        let snapshot = try XCTUnwrap(suppliedSnapshot ?? manager.currentSnapshot)
        return router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: value))
    }

    func event() throws -> [String: Any] {
        let delivery = try XCTUnwrap(deliveries.values.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(delivery.eventJSON.utf8)) as? [String: Any])
    }

    func activation() throws -> String { try XCTUnwrap(event()["activation"] as? String) }

    func shutdown() {
        session.revoke()
        lifecycle.shutdown()
    }
}

@MainActor
private final class CountdownActivationClock { var instant = ContinuousClock.now }
@MainActor
private final class CountdownActivationDeliveries { var values: [PluginActionDelivery] = [] }
@MainActor
private final class CountdownActivationContexts { var values: [PluginExecutionContext] = [] }
@MainActor
private final class CountdownActivationAuthorization { var hook: (() -> Void)? }

@MainActor
private final class CountdownActivationRuntime: PluginLifecycleRuntime {
    private let contexts: CountdownActivationContexts
    init(contexts: CountdownActivationContexts) { self.contexts = contexts }
    func onStart(context: PluginExecutionContext) throws { contexts.values.append(context) }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}
