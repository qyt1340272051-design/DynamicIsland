import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginNetworkBrokerTests: XCTestCase {
    private let alpha = "com.example.network.alpha"

    func testRequestParserAppliesDefaultsAndRejectsUnexpectedFieldsTypesMethodsAndTimeouts() throws {
        let parsed = try PluginNetworkRequest.parse(.object(["url": .string("https://api.github.com/repos/test/builds")]))
        XCTAssertEqual(parsed.url.absoluteString, "https://api.github.com/repos/test/builds")
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.headers, [:])
        XCTAssertEqual(parsed.timeoutSeconds, 10)
        let head = try PluginNetworkRequest.parse(.object([
            "url": .string("https://api.github.com/"), "method": .string("HEAD"), "timeoutMs": .number(100)
        ]))
        XCTAssertEqual(head.method, "HEAD")
        XCTAssertEqual(head.timeoutSeconds, 0.1, accuracy: 0.000_001)
        let maximum = try PluginNetworkRequest.parse(.object(["url": .string("https://api.github.com/"), "timeoutMs": .number(30_000)]))
        XCTAssertEqual(maximum.timeoutSeconds, 30)
        let lowercase = try PluginNetworkRequest.parse(.object(["url": .string("https://api.github.com/"), "method": .string("get")]))
        XCTAssertEqual(lowercase.method, "GET")

        let invalid: [PluginBridgeJSON] = [
            .null, .array([]), .object([:]), .object(["url": .number(1)]),
            .object(["url": .string("not a URL")]),
            .object(["url": .string("https://api.github.com/"), "body": .string("forbidden")]),
            .object(["url": .string("https://api.github.com/"), "method": .string("POST")]),
            .object(["url": .string("https://api.github.com/"), "timeoutMs": .number(99)]),
            .object(["url": .string("https://api.github.com/"), "timeoutMs": .number(30_001)]),
            .object(["url": .string("https://api.github.com/"), "timeoutMs": .number(100.5)]),
            .object(["url": .string("https://api.github.com/"), "timeoutMs": .string("1000")])
        ]
        for value in invalid { assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(value) } }
    }

    func testRequestHeadersRejectControlsForbiddenNamesAndBoundedUTF8Budgets() throws {
        let url = PluginBridgeJSON.string("https://api.github.com/")
        let sixteen = Dictionary(uniqueKeysWithValues: (0..<16).map { ("X-Test-\($0)", PluginBridgeJSON.string("ok")) })
        XCTAssertEqual(try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(sixteen)])).headers.count, 16)
        let boundary = String(repeating: "界", count: 341) + "x"
        XCTAssertEqual(boundary.utf8.count, 1_024)
        _ = try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(["X-Test": .string(boundary)])]))

        for name in ["Host", "hOsT", "Cookie", "cOoKiE", "Proxy-Authorization", "Proxy-Connection"] {
            assertNetworkThrow(.policyDenied) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object([name: .string("value")])])) }
        }
        for name in ["bad name", "X-\nInjected"] {
            assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object([name: .string("value")])])) }
        }
        for value in ["line\nInjected: yes", "carriage\rreturn", "nul\u{0000}value"] {
            assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(["X-Test": .string(value)])])) }
        }
        assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .array([])])) }
        assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(["X-Test": .number(1)])])) }
        let seventeen = Dictionary(uniqueKeysWithValues: (0..<17).map { ("X-Test-\($0)", PluginBridgeJSON.string("ok")) })
        assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(seventeen)])) }
        assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(["X-Test": .string(boundary + "x")])])) }
        let aggregate = Dictionary(uniqueKeysWithValues: (0..<5).map { ("X-Test-\($0)", PluginBridgeJSON.string(String(repeating: "a", count: 900))) })
        assertNetworkThrow(.invalidArguments) { try PluginNetworkRequest.parse(.object(["url": url, "headers": .object(aggregate)])) }
    }

    func testHTTPSExactHostPolicyRejectsCredentialsPortsIPLocalNamesAndSubdomainsBeforeTransport() async throws {
        let authorization = try authorization()
        let broker = makeBroker()
        let invalid = [
            "http://api.github.com/", "https://api.github.com:444/", "https://user:password@api.github.com/",
            "https://127.0.0.1/", "https://[::1]/", "https://localhost/", "https://service.local/",
            "https://evil.api.github.com/", "https://api.github.com.evil.example/", "https://github.com/"
        ]
        for source in invalid {
            let request = PluginNetworkRequest(url: try XCTUnwrap(URL(string: source)), method: "GET", headers: [:], timeoutSeconds: 1)
            let recorder = begin(broker, request: request, lease: authorization.lease)
            try await assertFailure(recorder, .policyDenied)
        }
        let route = NetworkTestRoute(body: Data("public HTTPS".utf8))
        defer { route.remove() }
        let result = begin(broker, request: request(route.url), lease: authorization.lease)
        let response = try await success(result)
        XCTAssertEqual(response.body, "public HTTPS")
        XCTAssertEqual(route.startedCount, 1)
    }

    func testDNSRejectsAnyPrivateAnswerIncludingIPv4MappedIPv6AndEmptyResolution() async throws {
        let authorization = try authorization()
        let blocked = [
            [String](), ["127.0.0.1"], ["10.0.0.1"], ["172.16.0.1"], ["192.168.0.1"],
            ["169.254.169.254"], ["0.0.0.0"], ["224.0.0.1"], ["::1"], ["::"], ["fe80::1"], ["fc00::1"],
            ["::ffff:127.0.0.1"], ["::ffff:7f00:1"], ["8.8.8.8", "192.168.1.1"], ["8.8.8.8", "::ffff:10.0.0.1"]
        ]
        for addresses in blocked {
            let route = NetworkTestRoute(body: Data("must not arrive".utf8))
            defer { route.remove() }
            let broker = makeBroker(resolver: { _ in addresses })
            let result = begin(broker, request: request(route.url), lease: authorization.lease)
            try await assertFailure(result, .policyDenied)
            XCTAssertEqual(route.startedCount, 0, "Blocked DNS answers reached URLSession: \(addresses).")
        }
        let route = NetworkTestRoute(body: Data("safe mixed public answers".utf8))
        defer { route.remove() }
        let broker = makeBroker(resolver: { _ in ["8.8.8.8", "2606:4700:4700::1111"] })
        let publicResponse = try await success(begin(broker, request: request(route.url), lease: authorization.lease))
        XCTAssertEqual(publicResponse.body, "safe mixed public answers")
    }

    func testResponseLimitAllows64KiBAndRejectsOversizedChunksAndAdvertisedLength() async throws {
        let authorization = try authorization()
        let broker = makeBroker()
        let boundary = NetworkTestRoute(chunks: [Data(repeating: 97, count: 32_768), Data(repeating: 98, count: 32_768)])
        defer { boundary.remove() }
        let response = try await success(begin(broker, request: request(boundary.url), lease: authorization.lease))
        XCTAssertEqual(response.body.utf8.count, 65_536)

        let oversized = NetworkTestRoute(chunks: [Data(repeating: 97, count: 32_768), Data(repeating: 98, count: 32_769)])
        defer { oversized.remove() }
        try await assertFailure(begin(broker, request: request(oversized.url), lease: authorization.lease), .responseTooLarge)
        let advertised = NetworkTestRoute(headers: ["Content-Length": "65537"], body: Data())
        defer { advertised.remove() }
        try await assertFailure(begin(broker, request: request(advertised.url), lease: authorization.lease), .responseTooLarge)
        let fresh = NetworkTestRoute(body: Data("slot released".utf8))
        defer { fresh.remove() }
        let freshResponse = try await success(begin(broker, request: request(fresh.url), lease: authorization.lease))
        XCTAssertEqual(freshResponse.body, "slot released")
    }

    func testInvalidUTF8NonHTTPResponseAndTransportErrorsFailWithoutPartialBody() async throws {
        let authorization = try authorization()
        let broker = makeBroker()
        let invalidUTF8 = NetworkTestRoute(body: Data([0xff, 0xfe]))
        defer { invalidUTF8.remove() }
        try await assertFailure(begin(broker, request: request(invalidUTF8.url), lease: authorization.lease), .invalidResponse)
        let nonHTTP = NetworkTestRoute(body: Data("not HTTP".utf8), nonHTTP: true)
        defer { nonHTTP.remove() }
        try await assertFailure(begin(broker, request: request(nonHTTP.url), lease: authorization.lease), .invalidResponse)
        let failed = NetworkTestRoute(failure: URLError(.cannotConnectToHost))
        defer { failed.remove() }
        try await assertFailure(begin(broker, request: request(failed.url), lease: authorization.lease), .transportFailed)
    }

    func testDeadlineCancelsHeldRequestsAndReleasesPluginSlotsForAnotherRequest() async throws {
        let authorization = try authorization()
        let broker = makeBroker()
        let first = NetworkTestRoute(hold: true)
        let second = NetworkTestRoute(hold: true)
        defer { first.remove(); second.remove() }
        let firstResult = begin(broker, request: request(first.url, timeout: 0.2), lease: authorization.lease)
        let secondResult = begin(broker, request: request(second.url, timeout: 0.2), lease: authorization.lease)
        try await waitUntil { first.startedCount == 1 && second.startedCount == 1 }
        try await assertFailure(firstResult, .timeout)
        try await assertFailure(secondResult, .timeout)
        try await waitUntil { first.stoppedCount > 0 && second.stoppedCount > 0 }
        let fresh = NetworkTestRoute(body: Data("after timeout".utf8))
        defer { fresh.remove() }
        let freshResponse = try await success(begin(broker, request: request(fresh.url), lease: authorization.lease))
        XCTAssertEqual(freshResponse.body, "after timeout")
        XCTAssertEqual(firstResult.count, 1)
        XCTAssertEqual(secondResult.count, 1)
    }

    func testTwoPerPluginAndEightHostRequestsRejectImmediatelyWithoutQueueAndReleaseAfterCancellation() async throws {
        let broker = makeBroker()
        var routes: [NetworkTestRoute] = []
        var admissions: [PluginNetworkAdmission] = []
        var results: [NetworkResultRecorder] = []
        defer { admissions.forEach { $0.revoke() }; routes.forEach { $0.remove() } }
        let authorizations = try (0..<5).map { try authorization(id: "com.example.network.p\($0)") }
        for index in 0..<4 {
            for _ in 0..<2 {
                let route = NetworkTestRoute(hold: true)
                let admission = PluginNetworkAdmission()
                routes.append(route)
                admissions.append(admission)
                results.append(begin(broker, request: request(route.url), lease: authorizations[index].lease, admission: admission))
            }
            if index == 0 {
                let overflow = NetworkTestRoute(hold: true)
                routes.append(overflow)
                try await assertFailure(begin(broker, request: request(overflow.url), lease: authorizations[0].lease), .quotaExceeded)
                XCTAssertEqual(overflow.startedCount, 0)
            }
        }
        let hostOverflow = NetworkTestRoute(hold: true)
        routes.append(hostOverflow)
        try await assertFailure(begin(broker, request: request(hostOverflow.url), lease: authorizations[4].lease), .quotaExceeded)
        XCTAssertEqual(hostOverflow.startedCount, 0)
        admissions[0].revoke()
        try await assertFailure(results[0], .inactiveExecution)
        let fresh = NetworkTestRoute(body: Data("released capacity".utf8))
        routes.append(fresh)
        let freshResponse = try await success(begin(broker, request: request(fresh.url), lease: authorizations[4].lease))
        XCTAssertEqual(freshResponse.body, "released capacity")
        for index in 1..<admissions.count {
            admissions[index].revoke()
            try await assertFailure(results[index], .inactiveExecution)
        }
    }

    func testRequestsDisableCookieAndCacheUseAndNeverFollowRedirects() async throws {
        let authorization = try authorization()
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [NetworkTestURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.urlCredentialStorage = URLCredentialStorage.shared
        configuration.urlCache = URLCache(memoryCapacity: 1_048_576, diskCapacity: 0, diskPath: nil)
        let broker = PluginNetworkBroker(configuration: configuration, resolver: { _ in ["8.8.8.8"] })
        let first = NetworkTestRoute(headers: ["Set-Cookie": "session=private; Path=/; Secure"], body: Data("fresh".utf8))
        let second = NetworkTestRoute(body: Data("also fresh".utf8))
        defer { first.remove(); second.remove() }
        let cachedResponse = try XCTUnwrap(HTTPURLResponse(url: first.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        configuration.urlCache?.storeCachedResponse(CachedURLResponse(response: cachedResponse, data: Data("cached".utf8)), for: URLRequest(url: first.url))
        let freshResponse = try await success(begin(broker, request: request(first.url), lease: authorization.lease))
        XCTAssertEqual(freshResponse.body, "fresh")
        _ = try await success(begin(broker, request: request(second.url), lease: authorization.lease))
        for route in [first, second] {
            let actual = try XCTUnwrap(route.requests.first)
            XCTAssertFalse(actual.httpShouldHandleCookies)
            XCTAssertNotEqual(actual.cachePolicy, .useProtocolCachePolicy)
            XCTAssertNil(actual.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(actual.value(forHTTPHeaderField: "Proxy-Authorization"))
            XCTAssertNil(actual.value(forHTTPHeaderField: "Authorization"))
        }
        let target = NetworkTestRoute(body: Data("must not follow even an allowed host".utf8))
        let redirected = NetworkTestRoute(status: 302, headers: ["Location": target.url.absoluteString])
        defer { redirected.remove(); target.remove() }
        try await assertFailure(begin(broker, request: request(redirected.url), lease: authorization.lease), .policyDenied)
        XCTAssertEqual(redirected.startedCount, 1)
        XCTAssertEqual(target.startedCount, 0)
    }

    func testAdmissionCancellationAndPermissionRevocationPreventLateDeliveryAndSettleOnlyOnce() async throws {
        let authorization = try authorization()
        let broker = makeBroker()
        let cancelled = NetworkTestRoute(body: Data("late private response".utf8), hold: true)
        defer { cancelled.remove() }
        let admission = PluginNetworkAdmission()
        let cancelledResult = begin(broker, request: request(cancelled.url), lease: authorization.lease, admission: admission)
        try await waitUntil { cancelled.startedCount == 1 }
        admission.revoke()
        try await assertFailure(cancelledResult, .inactiveExecution)
        try await waitUntil { cancelled.stoppedCount > 0 }
        cancelled.finishHeld()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelledResult.count, 1)

        let revoked = NetworkTestRoute(body: Data("must not leak".utf8), hold: true)
        defer { revoked.remove() }
        let revokedResult = begin(broker, request: request(revoked.url), lease: authorization.lease)
        try await waitUntil { revoked.startedCount == 1 }
        try authorization.permissions.applyHostDecision(decision: .revoked, review: authorization.review, permission: .network)
        revoked.finishHeld()
        try await assertFailure(revokedResult, .permissionRevoked)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(revokedResult.count, 1)
        let rejected = NetworkTestRoute(body: Data("old lease".utf8))
        defer { rejected.remove() }
        try await assertFailure(begin(broker, request: request(rejected.url), lease: authorization.lease), .permissionRevoked)
        XCTAssertEqual(rejected.startedCount, 0)
    }

    func testRealJavaScriptGitHubJSONLargerThanStorageBudgetHasFrozenResponseTextAndJSON() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": "GitHub fixture", "payload": String(repeating: "x", count: 6_000), "items": [["id": 7]]])
        let route = NetworkTestRoute(headers: ["Content-Type": "application/json"], body: body)
        let invalidJSON = NetworkTestRoute(body: Data("not JSON".utf8))
        defer { route.remove(); invalidJSON.remove() }
        let fixture = NetworkRuntimeFixture(broker: makeBroker())
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() {
                island.network.fetch('\(route.url.absoluteString)').then(async response => {
                    const text = await response.text();
                    const parsed = await response.json();
                    globalThis.valid = response.status === 200 && response.ok === true &&
                        Object.isFrozen(response) && Object.isFrozen(response.headers) &&
                        text.length > 4096 && parsed.payload.length === 6000 && parsed.items[0].id === 7 &&
                        Object.isFrozen(parsed) && Object.isFrozen(parsed.items) && Object.isFrozen(parsed.items[0]);
                    globalThis.repeatedText = (await response.text()) === text;
                    try { await island.storage.set('oversized', parsed.payload); }
                    catch (error) { globalThis.storageError = error.code; }
                    const invalid = await island.network.fetch('\(invalidJSON.url.absoluteString)');
                    try { await invalid.json(); }
                    catch (error) { globalThis.jsonError = error.code; }
                    globalThis.done = true;
                }).catch(error => { globalThis.unexpected = error.code; globalThis.done = true; });
            }
            """)
        let review = fixture.permissions.request(package: package)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .network)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let runtime = fixture.load(package)
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "valid && repeatedText", equals: .boolean(true))
        try await assertJavaScript(runtime, "storageError", equals: .string("quotaExceeded"))
        try await assertJavaScript(runtime, "jsonError", equals: .string("invalidResponse"))
        try await assertJavaScript(runtime, "typeof unexpected", equals: .string("undefined"))
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testRealJavaScriptSlowFetchDoesNotBlockStorageActivityOrPermissionErrorsWhileVMRuns() async throws {
        let route = NetworkTestRoute(body: Data("private network body".utf8), hold: true)
        defer { route.remove() }
        let fixture = NetworkRuntimeFixture(broker: makeBroker())
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() { globalThis.started = true; }
            function probe() {
                globalThis.networkDone = false;
                island.network.fetch('\(route.url.absoluteString)').then(() => {
                    globalThis.networkCode = 'ok'; globalThis.networkDone = true;
                }, error => { globalThis.networkCode = error.code; globalThis.networkDone = true; });
            }
            function concurrentOperations() {
                Promise.all([island.storage.set('ready', true), island.activity.publish({
                    id:'independent', presentation:{title:'Fetch waiting'}
                })]).then(() => { globalThis.independentDone = true; });
            }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        let review = try fixture.permissions.snapshot(package: package).review
        _ = try await runtime.evaluateForTesting("probe(); void 0")
        try await marker(runtime, "networkDone")
        try await assertJavaScript(runtime, "networkCode", equals: .string("permissionNotGranted"))
        XCTAssertEqual(route.startedCount, 0)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .network)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        _ = try await runtime.evaluateForTesting("probe(); concurrentOperations(); void 0")
        try await waitUntil { route.startedCount == 1 }
        try await marker(runtime, "independentDone")
        try await assertJavaScript(runtime, "networkDone", equals: .boolean(false))
        let stored = try await fixture.store.get(pluginID: alpha, key: "ready")
        XCTAssertEqual(stored, .boolean(true))
        XCTAssertEqual(fixture.manager.current?.presentation.title, "Fetch waiting")
        try fixture.permissions.applyHostDecision(decision: .revoked, review: review, permission: .network)
        route.finishHeld()
        try await marker(runtime, "networkDone")
        try await assertJavaScript(runtime, "networkCode", equals: .string("permissionRevoked"))
        _ = try await runtime.evaluateForTesting("probe(); void 0")
        try await marker(runtime, "networkDone")
        try await assertJavaScript(runtime, "networkCode", equals: .string("permissionRevoked"))
        XCTAssertEqual(route.startedCount, 1)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    private func makeBroker(resolver: @escaping @Sendable (String) throws -> [String] = { _ in ["8.8.8.8"] }) -> PluginNetworkBroker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkTestURLProtocol.self]
        return PluginNetworkBroker(configuration: configuration, resolver: resolver)
    }

    private func authorization(id: String = "com.example.network.alpha") throws -> NetworkAuthorizationFixture {
        let permissions = PermissionManager()
        let package = try package(id: id)
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .network)
        return .init(permissions: permissions, review: review, lease: try permissions.require(permission: .network, package: package))
    }

    private func request(_ url: URL, timeout: TimeInterval = 2) -> PluginNetworkRequest {
        .init(url: url, method: "GET", headers: [:], timeoutSeconds: timeout)
    }

    private func begin(_ broker: PluginNetworkBroker, request: PluginNetworkRequest, lease: PluginPermissionLease,
                       admission: PluginNetworkAdmission = PluginNetworkAdmission()) -> NetworkResultRecorder {
        let recorder = NetworkResultRecorder()
        do {
            try broker.start(request: request, pluginID: lease.pluginID, authorization: lease, admission: admission) { recorder.record($0) }
        } catch {
            guard let networkError = error as? PluginNetworkError else {
                XCTFail("Unexpected start error: \(error).")
                recorder.record(.failure(.transportFailed))
                return recorder
            }
            recorder.record(.failure(networkError))
        }
        return recorder
    }

    private func assertNetworkThrow<T>(_ expected: PluginNetworkError, file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () throws -> T) {
        do { _ = try operation(); XCTFail("Expected \(expected).", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginNetworkError, expected, file: file, line: line) }
    }

    private func assertFailure(_ recorder: NetworkResultRecorder, _ expected: PluginNetworkError,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil { recorder.count > 0 }
        guard case .failure(let error) = try XCTUnwrap(recorder.first, file: file, line: line) else {
            XCTFail("Expected \(expected), received a successful response.", file: file, line: line)
            return
        }
        XCTAssertEqual(error, expected, file: file, line: line)
        XCTAssertEqual(recorder.count, 1, file: file, line: line)
    }

    private func success(_ recorder: NetworkResultRecorder) async throws -> PluginNetworkResponse {
        try await waitUntil { recorder.count > 0 }
        return try XCTUnwrap(recorder.first).get()
    }

    private func package(id: String = "com.example.network.alpha", source: String = "") throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Network Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.network, .localStorage], capabilities: [.localStorage, .publishActivity])
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/network-tests/\(id)", isDirectory: true),
                     entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Network test timed out."); throw NetworkTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        try await waitUntil { runtime.snapshot.state == .running || runtime.snapshot.lastFailure != nil }
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { XCTFail("JavaScript marker \(name) did not settle."); throw NetworkTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertJavaScript(_ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await runtime.evaluateForTesting(source)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

@MainActor
private struct NetworkAuthorizationFixture {
    let permissions: PermissionManager
    let review: PluginPermissionReview
    let lease: PluginPermissionLease
}

private nonisolated final class NetworkResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<PluginNetworkResponse, PluginNetworkError>] = []
    var count: Int { lock.withLock { values.count } }
    var first: Result<PluginNetworkResponse, PluginNetworkError>? { lock.withLock { values.first } }
    func record(_ result: Result<PluginNetworkResponse, PluginNetworkError>) { lock.withLock { values.append(result) } }
}

private nonisolated final class NetworkProtocolRegistry: @unchecked Sendable {
    static let shared = NetworkProtocolRegistry()
    private let lock = NSLock()
    private var routes: [String: NetworkTestRoute] = [:]
    func register(_ route: NetworkTestRoute) { lock.withLock { routes[route.url.absoluteString] = route } }
    func remove(_ url: URL) { _ = lock.withLock { routes.removeValue(forKey: url.absoluteString) } }
    func route(_ url: URL?) -> NetworkTestRoute? { lock.withLock { url.flatMap { routes[$0.absoluteString] } } }
}

private nonisolated final class NetworkTestRoute: @unchecked Sendable {
    let url: URL
    private let status: Int
    private let headers: [String: String]
    private let chunks: [Data]
    private let hold: Bool
    private let redirect: URL?
    private let failure: URLError?
    private let nonHTTP: Bool
    private let lock = NSLock()
    private var protocols: [NetworkTestURLProtocol] = []
    private var seenRequests: [URLRequest] = []
    private var stops = 0
    var requests: [URLRequest] { lock.withLock { seenRequests } }
    var startedCount: Int { lock.withLock { seenRequests.count } }
    var stoppedCount: Int { lock.withLock { stops } }

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(), chunks: [Data]? = nil,
         hold: Bool = false, redirect: URL? = nil, failure: URLError? = nil, nonHTTP: Bool = false) {
        url = URL(string: "https://api.github.com/network-tests/\(UUID().uuidString)")!
        self.status = status
        self.headers = headers
        self.chunks = chunks ?? [body]
        self.hold = hold
        self.redirect = redirect
        self.failure = failure
        self.nonHTTP = nonHTTP
        NetworkProtocolRegistry.shared.register(self)
    }

    func start(_ protocolInstance: NetworkTestURLProtocol) {
        lock.withLock { protocols.append(protocolInstance); seenRequests.append(protocolInstance.request) }
        if !hold { respond(protocolInstance) }
    }

    func stop() { lock.withLock { stops += 1 } }
    func remove() { NetworkProtocolRegistry.shared.remove(url) }
    func finishHeld() { lock.withLock { protocols }.forEach { respond($0) } }

    private func respond(_ protocolInstance: NetworkTestURLProtocol) {
        guard let client = protocolInstance.client else { return }
        if let failure { client.urlProtocol(protocolInstance, didFailWithError: failure); return }
        if let redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client.urlProtocol(protocolInstance, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        let response: URLResponse
        if nonHTTP { response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: chunks.reduce(0) { $0 + $1.count }, textEncodingName: "utf-8") }
        else { response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)! }
        client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
        chunks.forEach { client.urlProtocol(protocolInstance, didLoad: $0) }
        client.urlProtocolDidFinishLoading(protocolInstance)
    }
}

private nonisolated final class NetworkTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let route = NetworkProtocolRegistry.shared.route(request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        route.start(self)
    }
    override func stopLoading() { NetworkProtocolRegistry.shared.route(request.url)?.stop() }
}

@MainActor
private final class NetworkRuntimeFixture {
    let permissions = PermissionManager()
    let store = PluginStorage()
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    private let factory = NetworkRuntimeFactory()

    init(broker: PluginNetworkBroker) {
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 100_000)), configuration: .immediate)
        self.manager = manager
        let service = PluginJSBridge(storage: store, permissions: permissions, network: broker)
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), permissions: permissions, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return NetworkRuntimeForwarder(runtime: runtime)
        })
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class NetworkRuntimeFactory { var runtimes: [PluginRuntime] = [] }

@MainActor
private final class NetworkRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    init(runtime: PluginRuntime) { self.runtime = runtime }
    func onStart(context: PluginExecutionContext) throws { try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated enum NetworkTestError: Error { case timedOut }
