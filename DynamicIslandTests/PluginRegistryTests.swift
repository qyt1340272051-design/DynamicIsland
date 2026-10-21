import CryptoKit
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginRegistryTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private let catalogURL = URL(string: "https://raw.githubusercontent.com/example/plugins/main/Registry/registry.json")!

    func testRepositoryCatalogPinsPublishedOfficialPluginReleaseAssets() throws {
        let data = try Data(contentsOf: repository.appendingPathComponent("Registry/registry.json"))
        let entries = try PluginRegistryCatalog.decode(data).entries
        let expected = [
            (id: "com.dynamicisland.pomodoro", name: "番茄钟", version: "0.2.1", archive: "pomodoro-0.2.1.dip",
             hash: "444647bb7a2f40dc0c66418b62e94210c76f2b890f3df2681c2fd179ce5e25b2"),
            (id: "com.dynamicisland.github", name: "GitHub", version: "0.1.0", archive: "github-0.1.0.dip",
             hash: "5a090cbc251b48d34ffed3bd82d8fd5ff42214e7c6386b769e1ba70477bae0fa")
        ]
        XCTAssertEqual(entries.count, expected.count)
        XCTAssertEqual(Set(entries.map(\.id)), Set(expected.map { $0.id }))
        let source = "https://github.com/qyt1340272051-design/DynamicIsland"
        for specification in expected {
            let entry = try XCTUnwrap(entries.first { $0.id == specification.id })
            XCTAssertEqual(entry.name, specification.name)
            XCTAssertEqual(entry.version.description, specification.version)
            XCTAssertEqual(entry.source.absoluteString, source)
            XCTAssertEqual(entry.download.absoluteString, source + "/releases/download/plugins-0.6.0/" + specification.archive)
            XCTAssertEqual(entry.minHostVersion.description, "0.6.0")
            XCTAssertEqual(entry.hash, specification.hash)
        }
    }

    func testCatalogPreservesExactIdentityAndRejectsDuplicateIDs() throws {
        var item = fields()
        item["version"] = "1.0.0-beta.2+build.7"
        let entry = try XCTUnwrap(PluginRegistryCatalog.decode(catalog([item])).entries.first)
        XCTAssertEqual(entry.version.description, "1.0.0-beta.2+build.7")
        XCTAssertEqual(entry.minHostVersion.description, "0.6.0")
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog([item, item]))) {
            XCTAssertEqual($0 as? PluginRegistryError, .duplicatePlugin)
        }
    }

    func testCatalogRejectsMalformedClosedFieldsAndUnsafeNames() throws {
        for (field, value) in [
            ("unknown", "x"), ("id", "COM.example.bad"), ("id", "one.two"), ("name", "hidden\u{202E}name"),
            ("version", "01.0.0"), ("minHostVersion", "0.6"), ("hash", "abc"), ("hash", String(repeating: "A", count: 64))
        ] {
            var item = fields(); item[field] = value
            XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog([item])), field)
        }
        var missing = fields(); missing.removeValue(forKey: "hash")
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog([missing])))
        for json in ["{}", "{\"schemaVersion\":true,\"plugins\":[]}",
                     "{\"schemaVersion\":1,\"schemaVersion\":1,\"plugins\":[]}",
                     "{\"schemaVersion\":1,\"plugins\":[],\"extra\":null}",
                     "{\"schemaVersion\":1,\"plugins\":null}", "{\"schemaVersion\":1,\"plugins\":[true]}"] {
            XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data(json.utf8)))
        }
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data("{\"schemaVersion\":2,\"plugins\":[]}".utf8))) {
            XCTAssertEqual($0 as? PluginRegistryError, .unsupportedSchema)
        }
        let valid = try catalog([fields()])
        let duplicate = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"hash\":", with: "\"hash\":\"duplicate\",\"hash\":")
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data(duplicate.utf8)))
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data([0xEF, 0xBB, 0xBF]) + valid))
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data([0xFF])))
    }

    func testCatalogBoundsAndURLPoliciesRejectAlternativeDestinations() throws {
        let hundred = (0..<100).map { number -> [String: String] in
            var item = fields(); item["id"] = "com.example.plugin\(number)"; return item
        }
        XCTAssertEqual(try PluginRegistryCatalog.decode(catalog(hundred)).entries.count, 100)
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog(hundred + [fields()])))
        XCTAssertThrowsError(try PluginRegistryCatalog.decode(Data(repeating: 32, count: PluginRegistryCatalog.maximumBytes + 1))) {
            XCTAssertEqual($0 as? PluginRegistryError, .tooLarge)
        }
        for source in ["http://github.com/example/plugins", "https://github.com.evil.test/example/plugins",
                       "https://user@github.com/example/plugins", "https://github.com:443/example/plugins",
                       "https://github.com/example/plugins?x=1", "https://github.com/example/plugins#x",
                       "https://github.com/example/%2e%2e", "https://github.com/example/plugins/",
                       "https://github.com/example//plugins", "https://127.0.0.1/example/plugins"] {
            var item = fields(); item["source"] = source
            XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog([item])), source)
        }
        for download in ["https://github.com/other/plugins/releases/download/v1/example.dip",
                         "https://github.com/example/plugins/releases/latest/download/example.dip",
                         "https://github.com/example/plugins/releases/download/../example.dip",
                         "https://github.com/example/plugins/releases/download/v1/example.js",
                         "https://github.com/example/plugins/releases/download/v1/example.dip?token=x",
                         "https://raw.githubusercontent.com/example/plugins/main/example.dip"] {
            var item = fields(); item["download"] = download
            XCTAssertThrowsError(try PluginRegistryCatalog.decode(catalog([item])), download)
        }
        XCTAssertNoThrow(try PluginRegistryURLPolicy.catalog(catalogURL))
        XCTAssertThrowsError(try PluginRegistryURLPolicy.catalog(URL(string: "https://example.com/Registry/registry.json")!))
        XCTAssertNoThrow(try PluginRegistryURLPolicy.redirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc-123?sig=value")!))
        for value in ["https://github.com/example/plugins", "http://release-assets.githubusercontent.com/a/b",
                      "https://release-assets.githubusercontent.com.evil.test/a/b",
                      "https://release-assets.githubusercontent.com/a/%2e%2e", "https://user:pass@release-assets.githubusercontent.com/a/b"] {
            XCTAssertThrowsError(try PluginRegistryURLPolicy.redirect(URL(string: value)!))
        }
    }

    func testDownloadedArchiveUsesSameBufferHashAndInstallsOnlyAfterReview() async throws {
        let f = try await RegistryInstallerFixture()
        defer { f.cleanup() }
        let bytes = try helloArchive()
        let item = try entry(hash: hash(bytes))
        RegistryURLProtocol.reset(body: bytes)
        let client = PluginRegistryClient(protocolClasses: [RegistryURLProtocol.self])
        let review = try await client.prepareDownload(item, installer: f.installer)
        XCTAssertEqual(review.id, item.id)
        let before = await f.manager.plugins()
        XCTAssertTrue(before.isEmpty, "Downloading and previewing may not install or execute.")
        let installed = try await f.installer.commit(review)
        XCTAssertFalse(installed.isEnabled)
        XCTAssertEqual(installed.manifest.version, item.version)
        let validated = await f.manager.validatedPackage(id: item.id)
        let actual = try XCTUnwrap(validated)
        XCTAssertEqual(actual.entrySource, try Data(contentsOf: repository.appendingPathComponent("SDK/examples/hello-world/index.js")))
        XCTAssertTrue(actual.manifest.permissions.isEmpty)
        XCTAssertTrue(try f.stagingEntries().isEmpty)
    }

    func testHashMismatchRejectsBeforeExtractionAndCanRetry() async throws {
        let f = try await RegistryInstallerFixture()
        defer { f.cleanup() }
        let bytes = try helloArchive()
        var corrupted = bytes; corrupted[0] ^= 1
        let item = try entry(hash: hash(bytes))
        do {
            _ = try await f.installer.prepare(archiveData: corrupted, registryEntry: item)
            XCTFail("Corrupted download reached preview")
        } catch { XCTAssertEqual(error as? PluginInstallerError, .archiveChecksumMismatch) }
        XCTAssertTrue(try f.stagingEntries().isEmpty)
        let review = try await f.installer.prepare(archiveData: bytes, registryEntry: item)
        try await f.installer.cancel(review)
        XCTAssertTrue(try f.stagingEntries().isEmpty)
    }

    func testCatalogMetadataCannotReplaceValidatedManifestOrLeaveStaging() async throws {
        let f = try await RegistryInstallerFixture()
        defer { f.cleanup() }
        let bytes = try helloArchive()
        for (key, replacement) in [("id", "com.example.other"), ("name", "Different"),
                                   ("version", "0.2.0"), ("minHostVersion", "0.5.0")] {
            var item = fields(hash: hash(bytes)); item[key] = replacement
            let metadata = try XCTUnwrap(PluginRegistryCatalog.decode(catalog([item])).entries.first)
            do {
                _ = try await f.installer.prepare(archiveData: bytes, registryEntry: metadata)
                XCTFail("Mismatched \(key) reached preview")
            } catch { XCTAssertEqual(error as? PluginInstallerError, .registryMismatch) }
            XCTAssertTrue(try f.stagingEntries().isEmpty)
        }
        let installed = await f.manager.plugins()
        XCTAssertTrue(installed.isEmpty)
    }

    func testMatchingHashDoesNotBypassZIPOrMinimumHostValidation() async throws {
        let f = try await RegistryInstallerFixture(host: "0.5.0")
        defer { f.cleanup() }
        let invalid = Data("not a zip".utf8)
        do {
            _ = try await f.installer.prepare(archiveData: invalid, registryEntry: entry(hash: hash(invalid)))
            XCTFail("Hash alone admitted an invalid package")
        } catch { XCTAssertEqual(error as? PluginInstallerError, .archiveRejected) }
        let bytes = try helloArchive()
        do {
            _ = try await f.installer.prepare(archiveData: bytes, registryEntry: entry(hash: hash(bytes)))
            XCTFail("Registry bypassed minimumHostVersion")
        } catch { XCTAssertEqual(error as? PluginInstallerError, .incompatibleHost) }
        XCTAssertTrue(try f.stagingEntries().isEmpty)
    }

    func testCatalogTransportIsEphemeralAndRejectsStatusAndSize() async throws {
        let client = PluginRegistryClient(protocolClasses: [RegistryURLProtocol.self])
        RegistryURLProtocol.reset(body: try catalog([fields()]))
        let received = try await client.loadCatalog(from: catalogURL)
        XCTAssertEqual(received.entries.count, 1)
        let request = try XCTUnwrap(RegistryURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
        RegistryURLProtocol.reset(body: Data(), status: 404)
        do { _ = try await client.loadCatalog(from: catalogURL); XCTFail("Accepted HTTP failure") }
        catch { XCTAssertEqual(error as? PluginRegistryError, .httpStatus) }
        for declaredLength in [nil, 1, PluginRegistryCatalog.maximumBytes + 1] as [Int?] {
            RegistryURLProtocol.reset(body: Data(repeating: 32, count: PluginRegistryCatalog.maximumBytes + 1),
                                      length: declaredLength)
            do { _ = try await client.loadCatalog(from: catalogURL); XCTFail("Accepted oversized catalog") }
            catch { XCTAssertEqual(error as? PluginRegistryError, .tooLarge) }
        }
    }

    func testCancelledDownloadReleasesClientAndNeverCreatesAReview() async throws {
        let f = try await RegistryInstallerFixture()
        defer { f.cleanup() }
        RegistryURLProtocol.reset(body: Data(), hold: true)
        let client = PluginRegistryClient(protocolClasses: [RegistryURLProtocol.self])
        let item = try entry(hash: String(repeating: "0", count: 64))
        let task = Task { try await client.prepareDownload(item, installer: f.installer) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while RegistryURLProtocol.requests.isEmpty {
            guard ContinuousClock.now < deadline else { task.cancel(); throw RegistryTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        do { _ = try await client.loadCatalog(from: catalogURL); XCTFail("Accepted overlapping request") }
        catch { XCTAssertEqual(error as? PluginRegistryError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download produced a preview") }
        catch { XCTAssertEqual(error as? PluginRegistryError, .cancelled) }
        XCTAssertTrue(try f.stagingEntries().isEmpty)
        RegistryURLProtocol.reset(body: try catalog([]))
        let empty = try await client.loadCatalog(from: catalogURL)
        XCTAssertTrue(empty.entries.isEmpty)
    }

    func testRedirectDelegateStripsHeadersBoundsHopsAndRefusesCatalogRedirects() async throws {
        // Deliver actual URLSession delegate callbacks without a live request.
        // URLProtocol itself does not support redirect simulation on all OS versions.
        let initial = URL(string: fields()["download"]!)!
        let cdn = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?sig=value")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: initial) // Never resumed.
        let response = try XCTUnwrap(HTTPURLResponse(url: initial, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        var request = URLRequest(url: cdn)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=private", forHTTPHeaderField: "Cookie")
        let transfer = PluginRegistryTransfer(url: initial, kind: .archive, protocolClasses: nil)
        for _ in 0..<3 {
            let forwarded: URLRequest? = await withCheckedContinuation { continuation in
                transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
            }
            let clean = try XCTUnwrap(forwarded)
            XCTAssertEqual(clean.url, cdn)
            XCTAssertEqual(clean.httpMethod, "GET")
            XCTAssertNil(clean.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(clean.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(clean.httpShouldHandleCookies)
        }
        let fourth: URLRequest? = await withCheckedContinuation { continuation in
            transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(fourth)
        let catalogTransfer = PluginRegistryTransfer(url: catalogURL, kind: .catalog, protocolClasses: nil)
        let redirectedCatalog: URLRequest? = await withCheckedContinuation { continuation in
            catalogTransfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(redirectedCatalog)
        let foreignTransfer = PluginRegistryTransfer(url: initial, kind: .archive, protocolClasses: nil)
        let foreign: URLRequest? = await withCheckedContinuation { continuation in
            foreignTransfer.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.com/plugin.dip")!)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(foreign)
    }

    func testArchiveTransferHasIndependentStreamingAndDeclaredBounds() async throws {
        let transport = PluginRegistryTransport(protocolClasses: [RegistryURLProtocol.self])
        let url = URL(string: fields()["download"]!)!
        let limit = PluginPackageArchiveExtractor.maximumArchiveBytes
        RegistryURLProtocol.reset(body: Data(), length: limit + 1)
        do { _ = try await transport.fetch(url: url, kind: .archive); XCTFail("Accepted declared archive overflow") }
        catch { XCTAssertEqual(error as? PluginRegistryError, .tooLarge) }
        RegistryURLProtocol.reset(body: Data(repeating: 65, count: limit + 1))
        do { _ = try await transport.fetch(url: url, kind: .archive); XCTFail("Accepted streamed archive overflow") }
        catch { XCTAssertEqual(error as? PluginRegistryError, .tooLarge) }
        RegistryURLProtocol.reset(body: Data())
    }

    func testCancellationBeforeStartingMakesNoNetworkRequest() async throws {
        RegistryURLProtocol.reset(body: Data())
        let client = PluginRegistryClient(protocolClasses: [RegistryURLProtocol.self])
        let task = Task { try await client.loadCatalog(from: catalogURL) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Pre-cancelled request completed") }
        catch { XCTAssertTrue(error is CancellationError || error as? PluginRegistryError == .cancelled) }
        XCTAssertTrue(RegistryURLProtocol.requests.isEmpty)
    }

    private func fields(hash: String = String(repeating: "0", count: 64)) -> [String: String] {
        ["id": "com.example.hello-world", "name": "你好，计数器", "version": "0.1.0", "minHostVersion": "0.6.0",
         "source": "https://github.com/example/plugins", "download": "https://github.com/example/plugins/releases/download/v0.1.0/hello.dip", "hash": hash]
    }
    private func catalog(_ entries: [[String: String]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "plugins": entries], options: [.sortedKeys])
    }
    private func entry(hash: String) throws -> PluginRegistryEntry {
        try XCTUnwrap(PluginRegistryCatalog.decode(catalog([fields(hash: hash)])).entries.first)
    }
    private func helloArchive() throws -> Data {
        try Data(contentsOf: repository.appendingPathComponent("SDK/tests/fixtures/hello-world.dip"))
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

@MainActor
private final class RegistryInstallerFixture {
    let root: URL
    let configuration: PluginManagerConfiguration
    let manager: PluginManager
    let installer: PluginInstaller
    init(host: String = "0.6.0") async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion(host))
        manager = PluginManager(configuration: configuration)
        installer = PluginInstaller(manager: manager, configuration: configuration)
        let discovered = await manager.discover()
        XCTAssertTrue(discovered.failures.isEmpty)
    }
    func stagingEntries() throws -> [String] {
        let url = configuration.stagingDirectoryURL
        return FileManager.default.fileExists(atPath: url.path) ? try FileManager.default.contentsOfDirectory(atPath: url.path) : []
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private enum RegistryTestError: Error { case timeout }

private nonisolated final class RegistryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var length: Int?
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { seen } }
    static func reset(body nextBody: Data, status nextStatus: Int = 200, length nextLength: Int? = nil, hold nextHold: Bool = false) {
        lock.withLock { body = nextBody; status = nextStatus; length = nextLength; hold = nextHold; seen = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.lock.withLock { Self.seen.append(request); return (Self.body, Self.status, Self.length, Self.hold) }
        if value.3 { return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: value.1, httpVersion: "HTTP/1.1",
            headerFields: value.2.map { ["Content-Length": String($0)] }) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Small chunks exercise the running bound independently of headers.
        var offset = 0
        while offset < value.0.count {
            let end = min(offset + 8_192, value.0.count)
            client?.urlProtocol(self, didLoad: value.0.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
