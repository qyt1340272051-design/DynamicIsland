import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginDocumentationTests: XCTestCase {
    func testDocumentedActivityFunctionsPublishReplaceAndEndInHost() async throws {
        let f = try DocumentationFixture()
        defer { f.shutdown() }
        try await f.start()
        try await f.expect("publishReading()", value: .object(["id": .string("reading")]))
        XCTAssertEqual(f.manager.toolSnapshots.count, 1)
        XCTAssertNil(f.manager.currentSnapshot, "Documented tool cannot force foreground presentation.")
        let first = try XCTUnwrap(f.manager.toolSnapshots.first)
        try await f.expect("updateReading(0.5)", value: .object(["id": .string("reading")]))
        let updated = try XCTUnwrap(f.manager.toolSnapshots.first)
        XCTAssertEqual(first.instanceToken, updated.instanceToken)
        guard case .progress(let progress)? = updated.activity.presentation.expanded else {
            return XCTFail("Expected the documented progress node")
        }
        XCTAssertEqual(progress.value, 0.5)
        try await f.expect("updateReading(NaN)", error: "invalidReading")
        try await f.expect("endReading()", value: .null)
        XCTAssertTrue(f.manager.toolSnapshots.isEmpty)
        try await f.expect("updateReading(0.8)", error: "activityNotFound")
        let runtime = try XCTUnwrap(f.runtime)
        f.lifecycle.pluginDidChangeEnablement(id: f.package.manifest.id, isEnabled: false)
        do {
            _ = try await runtime.evaluateForTesting("publishReading()")
            XCTFail("Stopped documentation execution remained callable")
        } catch { XCTAssertEqual(error as? PluginRuntimeError, .inactiveExecution) }
    }

    func testDocumentedSettingsDefaultWithoutGrantAndValidateStoredShape() async throws {
        let f = try DocumentationFixture()
        defer { f.shutdown() }
        try await f.start()
        try await f.expect("loadMinutes()", value: .number(25))
        try await f.expect("saveMinutes(45)", value: .boolean(false))
        let missing = try await f.storage.get(pluginID: f.package.manifest.id, key: "preferences")
        XCTAssertEqual(missing, .null)
        try f.decide(.localStorage, .granted)
        try await f.expect("saveMinutes(45)", value: .boolean(true))
        try await f.expect("loadMinutes()", value: .number(45))
        try await f.expect("saveMinutes(99)", value: .boolean(false))
        try await f.expect("loadMinutes()", value: .number(45))
        // Exercise data coming back through the actual frozen/null-prototype bridge.
        try await f.expect("island.storage.set('preferences', {schemaVersion:1, minutes:60, extra:true})", value: .null)
        try await f.expect("loadMinutes()", value: .number(25))
        let malformed = try await f.storage.get(pluginID: f.package.manifest.id, key: "preferences")
        XCTAssertEqual(malformed, .object(["schemaVersion": .number(1), "minutes": .number(60), "extra": .boolean(true)]),
                       "Fallback must not overwrite unknown stored data.")
        try await f.expect("island.storage.set('preferences', [15,25])", value: .null)
        try await f.expect("loadMinutes()", value: .number(25))
        try await f.expect("saveMinutes(15)", value: .boolean(true))
        try f.decide(.localStorage, .revoked)
        try await f.expect("loadMinutes()", value: .number(25))
        try await f.expect("saveMinutes(60)", value: .boolean(false))
        let preserved = try await f.storage.get(pluginID: f.package.manifest.id, key: "preferences")
        XCTAssertEqual(preserved, .object(["schemaVersion": .number(1), "minutes": .number(15)]))
    }

    func testDocumentedNetworkFunctionUsesHostPolicyAndValidatesBusinessJSON() async throws {
        let f = try DocumentationFixture()
        defer { f.shutdown() }
        DocumentationURLProtocol.reset()
        try await f.start()
        try await f.expect("readGitHubStars()", error: "permissionNotGranted")
        XCTAssertEqual(DocumentationURLProtocol.requests.count, 0)
        try f.decide(.network, .granted)
        DocumentationURLProtocol.reply(status: 200, body: "{\"stargazers_count\":42}")
        try await f.expect("readGitHubStars()", value: .number(42))
        let request = try XCTUnwrap(DocumentationURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/cli/cli")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        for body in ["null", "[]", "{}", "{\"stargazers_count\":\"42\"}",
                     "{\"stargazers_count\":-1}", "{\"stargazers_count\":0.5}"] {
            DocumentationURLProtocol.reply(status: 200, body: body)
            try await f.expect("readGitHubStars()", error: "invalidData")
        }
        DocumentationURLProtocol.reply(status: 429, body: "{}")
        try await f.expect("readGitHubStars()", error: "httpStatus")
        let before = DocumentationURLProtocol.requests.count
        try f.decide(.network, .revoked)
        try await f.expect("readGitHubStars()", error: "permissionRevoked")
        XCTAssertEqual(DocumentationURLProtocol.requests.count, before)
    }

    func testDocumentedLinkHandlerOnlyOpensFromCurrentAuthorizedAction() async throws {
        let f = try DocumentationFixture()
        defer { f.shutdown() }
        try await f.start()
        try await f.expect("openGitHubRepository({activityID:'links',actionID:'open',value:{type:'none'}})", value: .null)
        XCTAssertTrue(f.opened.isEmpty)
        try f.decide(.openLinks, .granted)
        try await f.expect("openGitHubRepository({activation:'forged'})", error: "activationRequired")
        XCTAssertTrue(f.opened.isEmpty)
        try await f.expect("""
            island.actions.on('open', event => openGitHubRepository(event).then(
                () => { globalThis.linkOutcome = 'opened'; },
                error => { globalThis.linkOutcome = error.code; }
            )).then(() => island.activity.publish({id:'links',lifecycle:{policy:'persistent'},
                presentation:{role:'tool',title:'Links',expanded:{type:'button',actionID:'open',
                    label:{type:'text',content:'Open'}}},actions:[{id:'open',title:'Open'}]}))
            """, value: .object(["id": .string("links")]))
        f.manager.setPresentationContext(.expanded)
        let snapshot = try XCTUnwrap(f.manager.toolSnapshots.first)
        XCTAssertTrue(f.manager.selectTool(snapshot))
        XCTAssertEqual(f.act(snapshot), .handled)
        try await f.wait("globalThis.linkOutcome === 'opened'")
        XCTAssertEqual(f.opened.map(\.absoluteString), ["https://github.com/cli/cli"])
        try f.decide(.openLinks, .revoked)
        XCTAssertEqual(f.act(snapshot), .handled)
        try await f.wait("globalThis.linkOutcome === 'permissionRevoked'")
        XCTAssertEqual(f.opened.count, 1)
        f.lifecycle.pluginDidChangeEnablement(id: f.package.manifest.id, isEnabled: false)
        XCTAssertEqual(f.act(snapshot), .inactiveActivity)
    }
}

@MainActor
private final class DocumentationFixture {
    let root: URL
    let package: ValidatedPluginPackage
    let storage = PluginStorage()
    let permissions = PermissionManager()
    let manager = ActivityManager(configuration: .immediate)
    lazy var router = ActionRouter(manager: manager)
    var runtime: PluginRuntime?
    var opened: [URL] = []
    var writeTick: TimeInterval = 1_000
    lazy var links = PluginLinkBroker(opener: { [unowned self] url in opened.append(url); return true })
    lazy var bridge = PluginJSBridge(storage: storage, permissions: permissions, network: Self.network(), links: links,
        activityRateClock: { [unowned self] in writeTick += 1; return writeTick })
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, permissions: permissions,
        runtimeFactory: { [unowned self] package in
            let vm = PluginRuntime(package: package, bridge: bridge)
            runtime = vm
            return vm
        })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("documentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SDK/docs/snippets")
        let source = try ["activity.js", "settings.js", "network.js", "open-link.js"].map {
            try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n") + "\nfunction onStart(){globalThis.documentationReady=true;}\nfunction onStop(){}\n"
        let manifest = try PluginManifest(id: "com.example.documentation", name: "Documentation", version: SemanticVersion("0.1.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.localStorage, .network, .openLinks], capabilities: [
                .publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions, .localStorage, .openLinks])
        do {
            try manifest.encodeJSON().write(to: root.appendingPathComponent("manifest.json"))
            try Data(source.utf8).write(to: root.appendingPathComponent("index.js"))
            package = try PluginValidator().validateExpandedPackage(at: root, context: .init(
                hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: root.deletingLastPathComponent()))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func network() -> PluginNetworkBroker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentationURLProtocol.self]
        return PluginNetworkBroker(configuration: configuration, resolver: { _ in ["8.8.8.8"] })
    }

    func start() async throws {
        permissions.request(package: package)
        lifecycle.pluginDidLoad(package, isEnabled: true)
        try await wait("globalThis.documentationReady === true")
    }

    func decide(_ permission: PluginPermission, _ decision: PluginPermissionDecision) throws {
        let review = try permissions.snapshot(package: package).review
        try permissions.applyHostDecision(decision: decision, review: review, permission: permission)
    }

    func expect(_ expression: String, value: PluginBridgeJSON? = nil, error: String? = nil,
                file: StaticString = #filePath, line: UInt = #line) async throws {
        let vm = try XCTUnwrap(runtime)
        _ = try await vm.evaluateForTesting("""
            globalThis.docDone=false; globalThis.docResult='';
            void (\(expression)).then(
                value=>{globalThis.docResult=JSON.stringify({value:value});globalThis.docDone=true;},
                error=>{globalThis.docResult=JSON.stringify({error:error.code});globalThis.docDone=true;});
            """)
        try await wait("globalThis.docDone === true")
        guard case .string(let result) = try await vm.evaluateForTesting("globalThis.docResult") else {
            return XCTFail("Missing documentation outcome", file: file, line: line)
        }
        let expected: PluginBridgeJSON = error.map { .object(["error": .string($0)]) } ?? .object(["value": value ?? .null])
        XCTAssertEqual(try PluginBridgeJSON.parse(result), expected, file: file, line: line)
    }

    func wait(_ expression: String) async throws {
        let vm = try XCTUnwrap(runtime)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await vm.evaluateForTesting(expression) != .boolean(true) {
            guard ContinuousClock.now < deadline else { throw DocumentationTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func act(_ snapshot: ActivitySnapshot) -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
                        action: .init(actionID: "open", value: .none))
    }

    func shutdown() {
        lifecycle.shutdown()
        permissions.revokeAll()
        try? FileManager.default.removeItem(at: root)
    }
}

private enum DocumentationTestError: Error { case timeout }

private nonisolated final class DocumentationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = "{}"
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { seen } }
    static func reset() { lock.withLock { status = 200; body = "{}"; seen = [] } }
    static func reply(status nextStatus: Int, body nextBody: String) {
        lock.withLock { status = nextStatus; body = nextBody }
    }
    // Intercept every request in this private session; no test can fall through to live networking.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.seen.append(request); return (Self.status, Self.body) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
