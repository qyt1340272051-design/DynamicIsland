import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginLinkBridgeTests: XCTestCase {
    func testRealVMRequiresButtonAndOpensOncePerActivationWithGlobalCooldown() async throws {
        let f = try LinkBridgeFixture()
        defer { f.lifecycle.shutdown() }
        _ = try await f.load()
        try await f.assertJS("startupError", .string("activationRequired"))
        XCTAssertTrue(f.opened.isEmpty)
        try f.act("open")
        try await f.wait("openSuccess === 1")
        XCTAssertEqual(f.opened.map(\.absoluteString), [LinkBridgeFixture.address])
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        XCTAssertEqual(f.opened.count, 1)

        f.clock.instant = f.clock.instant.advanced(by: .milliseconds(999))
        try f.act("open")
        try await f.wait("actionError === 'rateLimited'")
        f.clock.instant = f.clock.instant.advanced(by: .milliseconds(1))
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        try f.act("open")
        try await f.wait("openSuccess === 2")
        XCTAssertEqual(f.opened.count, 2)
        try await f.assertJS("lastReply === null", .boolean(true))
    }

    func testNetworkGrantDoesNotAuthorizeLinksAndFailedPermissionAttemptStaysConsumed() async throws {
        let f = try LinkBridgeFixture(permissions: [.network, .openLinks])
        defer { f.lifecycle.shutdown() }
        _ = try await f.load(grant: false)
        try f.decide(.granted, permission: .network)
        try f.act("open")
        try await f.wait("actionError === 'permissionNotGranted'")
        XCTAssertTrue(f.opened.isEmpty)
        try f.decide(.denied)
        try f.act("open")
        try await f.wait("actionError === 'permissionDenied'")
        try f.decide(.granted)
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        try f.act("open")
        try await f.wait("openSuccess === 1")

        try f.decide(.revoked)
        try f.act("open")
        try await f.wait("actionError === 'permissionRevoked'")
        try f.decide(.granted)
        f.clock.instant = f.clock.instant.advanced(by: .seconds(1))
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        XCTAssertEqual(f.opened.count, 1)
    }

    func testCapabilityAndPermissionDeclarationsAreIndependentHostRequirements() async throws {
        // Countdown can mint a genuine action ticket, but cannot grant the separate Links capability.
        let noCapability = try LinkBridgeFixture(capabilities: [.publishActivity, .handleActions, .countdown])
        defer { noCapability.lifecycle.shutdown() }
        _ = try await noCapability.load()
        try noCapability.act("open")
        try await noCapability.wait("actionError === 'capabilityRequired'")
        XCTAssertTrue(noCapability.opened.isEmpty)

        let noPermission = try LinkBridgeFixture(permissions: [.network])
        defer { noPermission.lifecycle.shutdown() }
        _ = try await noPermission.load(grant: false)
        try noPermission.decide(.granted, permission: .network)
        try noPermission.act("open")
        try await noPermission.wait("actionError === 'permissionRequired'")
        XCTAssertTrue(noPermission.opened.isEmpty)
    }

    func testFinalOpenGateRejectsPermissionAndResourceRevocationAfterConsumption() async throws {
        for revokePermission in [true, false] {
            let f = try LinkBridgeFixture()
            defer { f.lifecycle.shutdown() }
            _ = try await f.load()
            let context = try XCTUnwrap(f.contexts.last)
            f.clock.onRead = {
                if revokePermission {
                    do { try f.decide(.revoked) }
                    catch { XCTFail("Could not revoke the test permission.") }
                }
                else { context.resourceAdmission.revoke() }
            }
            try f.act("open")
            try await f.wait(revokePermission
                ? "actionError === 'permissionRevoked'" : "actionError === 'inactiveExecution'")
            XCTAssertTrue(f.opened.isEmpty)
            if revokePermission { try f.decide(.granted) }
            try await f.replay()
            try await f.wait("replayError === 'activationRequired'")
            XCTAssertTrue(f.opened.isEmpty)
        }
    }

    func testSavedActivationCannotOpenReplacementActivityWithSameID() async throws {
        let f = try LinkBridgeFixture()
        defer { f.lifecycle.shutdown() }
        _ = try await f.load()
        try f.act("save")
        try await f.wait("saved === 1")
        let old = try XCTUnwrap(f.manager.currentSnapshot)
        let context = try XCTUnwrap(f.contexts.last)
        try context.endActivity(id: old.activity.id)
        try context.publish(.init(id: old.activity.id, source: context.source, priority: .normal,
            lifecycle: .init(policy: .persistent), presentation: .init(title: "Replacement build"),
            createdAt: f.activityClock.now(), actions: [.init(id: "open", title: "Open"), .init(id: "save", title: "Save")]))
        XCTAssertNotEqual(f.manager.currentSnapshot?.instanceToken, old.instanceToken)
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        XCTAssertTrue(f.opened.isEmpty)
        XCTAssertEqual(f.router.dispatch(id: old.activity.id, source: old.activity.source,
            instanceToken: old.instanceToken, action: .init(actionID: "open", value: .none)), .inactiveActivity)
    }

    func testSDKRejectsMalformedSnapshotsWithoutExecutingAccessorsAndHostRejectsExtraFields() async throws {
        let f = try LinkBridgeFixture()
        defer { f.lifecycle.shutdown() }
        let vm = try await f.load()
        _ = try await vm.evaluateForTesting("""
            globalThis.getterReads=0; globalThis.invalidRejected=0; globalThis.invalidCodes=[];
            const validURL='https://github.com/octocat/Hello-World/actions/runs/1';
            const getter={activation:'ticket'};
            Object.defineProperty(getter,'url',{enumerable:true,get(){getterReads++;return validURL;}});
            const inherited=Object.create({url:validURL,activation:'ticket'});
            const inputs=[
                ()=>island.links.open(), ()=>island.links.open(null),
                ()=>island.links.open({url:validURL,activation:'ticket'},'extra'),
                ()=>island.links.open({url:validURL,activation:'ticket',owner:'other'}),
                ()=>island.links.open(getter), ()=>island.links.open(inherited),
                ()=>island.links.open({url:7,activation:'ticket'}),
                ()=>island.links.open({url:validURL,activation:7}),
                ()=>island.links.open({url:'https://github.com/a b',activation:'ticket'})
            ];
            inputs.forEach(call=>call().then(()=>invalidCodes.push('unexpectedSuccess'),error=>{
                invalidCodes.push(error.code);invalidRejected++;
            }));
            """)
        try await f.wait("invalidRejected === 9")
        try await f.assertJS("getterReads", .number(0))
        try await f.assertJS("invalidCodes.every(code=>code === 'invalidArguments')", .boolean(true))
        XCTAssertTrue(f.opened.isEmpty)
        try f.act("save")
        try await f.wait("saved === 1")
        _ = try await vm.evaluateForTesting("void island.links.open({url:'https://github.com.attacker.example/run',activation:savedActivation}).catch(error=>{globalThis.policyError=error.code;});")
        try await f.wait("globalThis.policyError === 'linkPolicyDenied'")
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        let reply = try await f.hostRequest(fields: [
            "url": .string(LinkBridgeFixture.address), "activation": .string("forged"), "owner": .string("other")
        ])
        XCTAssertEqual(reply, "invalidArguments")
        let wrongVersion = try await f.hostRequest(fields: [
            "url": .string(LinkBridgeFixture.address), "activation": .string("forged")
        ], version: "2.0.0")
        XCTAssertEqual(wrongVersion, "unsupportedVersion")
        XCTAssertTrue(f.opened.isEmpty)
    }

    func testSystemOpenFailureIsFixedAndDoesNotRestoreActionTicketOrLeakURL() async throws {
        let f = try LinkBridgeFixture(openerSucceeds: false)
        defer { f.lifecycle.shutdown() }
        _ = try await f.load()
        try f.act("open")
        try await f.wait("actionError === 'linkOpenFailed'")
        XCTAssertEqual(f.opened.count, 1)
        try await f.replay()
        try await f.wait("replayError === 'activationRequired'")
        XCTAssertEqual(f.opened.count, 1)
        XCTAssertFalse(f.bridge.logs(for: f.id).contains { $0.message.contains(LinkBridgeFixture.address) })
    }
}

@MainActor
private final class LinkBridgeClock {
    var instant = ContinuousClock.now
    var onRead: (() -> Void)?
    func read() -> ContinuousClock.Instant {
        let callback = onRead
        onRead = nil
        callback?()
        return instant
    }
}

@MainActor
private final class LinkBridgeFixture {
    static let address = "https://github.com/octocat/Hello-World/actions/runs/1"
    let id = "com.example.link-bridge"
    let clock = LinkBridgeClock()
    let activityClock: TestActivityClock
    let permissions = PermissionManager()
    let package: ValidatedPluginPackage
    let manager: ActivityManager
    var opened: [URL] = []
    var contexts: [PluginExecutionContext] = []
    var runtimes: [PluginRuntime] = []
    private let openerSucceeds: Bool
    lazy var router = ActionRouter(manager: manager)
    lazy var links = PluginLinkBroker(now: { [clock] in clock.read() }, opener: { [unowned self] url in
        opened.append(url)
        return openerSucceeds
    })
    lazy var bridge = PluginJSBridge(permissions: permissions, links: links)
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router,
        permissions: permissions, runtimeFactory: { [unowned self] package in
            let vm = PluginRuntime(package: package, bridge: bridge)
            runtimes.append(vm)
            return LinkCapturingRuntime(runtime: vm) { [weak self] in self?.contexts.append($0) }
        })

    init(permissions declaredPermissions: [PluginPermission] = [.openLinks],
         capabilities: [PluginCapability] = [.publishActivity, .handleActions, .openLinks],
         openerSucceeds: Bool = true) throws {
        self.openerSucceeds = openerSucceeds
        let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 145_000))
        self.activityClock = activityClock
        manager = ActivityManager(clock: activityClock, configuration: .immediate)
        let manifest = try PluginManifest(id: "com.example.link-bridge", name: "Link Bridge", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: declaredPermissions, capabilities: capabilities)
        let source = """
            globalThis.ready=false; globalThis.startupError=''; globalThis.actionError='';
            globalThis.openSuccess=0; globalThis.saved=0; globalThis.savedActivation='';
            globalThis.lastReply='pending';globalThis.replayError='';
            function attempt(activation){return island.links.open({url:'\(Self.address)',activation});}
            function onStart(){
                Promise.all([
                    island.actions.on('open',event=>{
                        savedActivation=event.activation;
                        return attempt(event.activation).then(value=>{lastReply=value;openSuccess++;},error=>{actionError=error.code;});
                    }),
                    island.actions.on('save',event=>{savedActivation=event.activation;saved++;})
                ]).then(()=>island.activity.publish({id:'build',lifecycle:{policy:'persistent'},
                    presentation:{title:'Build result'},actions:[{id:'open',title:'Open'},{id:'save',title:'Save'}]}))
                .then(()=>attempt('forged').then(()=>{startupError='unexpectedSuccess';},error=>{startupError=error.code;}))
                .then(()=>{ready=true;});
            }
            function onStop(){}
            """
        package = .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/link-bridge-tests/"),
            entryRelativePath: "index.js", entrySource: Data(source.utf8), regularFileCount: 2,
            totalFileBytes: UInt64(source.utf8.count))
    }

    func load(grant: Bool = true) async throws -> PluginRuntime {
        _ = permissions.request(package: package)
        if grant { try decide(.granted) }
        lifecycle.pluginDidLoad(package, isEnabled: true)
        try await wait("ready === true")
        return try XCTUnwrap(runtimes.last)
    }

    func decide(_ decision: PluginPermissionDecision, permission: PluginPermission = .openLinks) throws {
        let review = try permissions.snapshot(package: package).review
        try permissions.applyHostDecision(decision: decision, review: review, permission: permission)
    }

    func act(_ actionID: String) throws {
        let snapshot = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)), .handled)
    }

    func replay() async throws {
        let vm = try XCTUnwrap(runtimes.last)
        _ = try await vm.evaluateForTesting("replayError='';void attempt(savedActivation).then(()=>{replayError='unexpectedSuccess';},error=>{replayError=error.code;});")
    }

    func wait(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let vm = try XCTUnwrap(runtimes.last, file: file, line: line)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if try await vm.evaluateForTesting(expression) == .boolean(true) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Link JavaScript did not settle: \(expression)", file: file, line: line)
    }

    func assertJS(_ expression: String, _ expected: PluginJavaScriptValue,
                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await XCTUnwrap(runtimes.last).evaluateForTesting(expression)
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    func hostRequest(fields: [String: PluginBridgeJSON], version: String = "1.0.0") async throws -> String? {
        let json = try PluginBridgeJSON.object(["apiVersion": .string(version), "method": .string("links.open"),
                                                "params": .object(fields)]).encodedString()
        let context = try XCTUnwrap(contexts.last)
        let response = await bridge.handle(json, package: package, context: context)
        guard case .object(let envelope) = try PluginBridgeJSON.parse(response),
              case .object(let error)? = envelope["error"], case .string(let code)? = error["code"] else { return nil }
        return code
    }
}

@MainActor
private final class LinkCapturingRuntime: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let capture: (PluginExecutionContext) -> Void
    init(runtime: PluginRuntime, capture: @escaping (PluginExecutionContext) -> Void) {
        self.runtime = runtime
        self.capture = capture
    }
    func onStart(context: PluginExecutionContext) throws { capture(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}
