import AppKit
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginUserResourceBrokerTests: XCTestCase {
    private let alpha = "com.example.resources.alpha"

    func testFileRequestOnlyAcceptsEmptyObjectAndCannotCarryArbitraryPathsOrNativeHandles() throws {
        _ = try PluginFileRequest.parse(.object([:]))
        let invalid: [PluginBridgeJSON] = [
            .null, .array([]), .string("/etc/passwd"), .number(1),
            .object(["path": .string("/etc/passwd")]),
            .object(["url": .string("file:///etc/passwd")]),
            .object(["bookmark": .string("encoded bookmark")]),
            .object(["fileDescriptor": .number(3)]),
            .object(["extensions": .array([.string("*")])]),
            .object(["text": .string("preselected")])
        ]
        for value in invalid {
            assertThrows(PluginFileError.invalidArguments) { try PluginFileRequest.parse(value) }
        }
    }

    func testClipboardReadAndWriteGrantsAreIndependentAndOldLeasesStayRevokedAfterRegrant() throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let broker = PluginClipboardBroker(pasteboard: board)
        let permissions = PermissionManager()
        let package = try package()
        let review = permissions.request(package: package)
        assertThrows(PluginPermissionError.notGranted) { try permissions.require(permission: .readClipboard, package: package) }
        assertThrows(PluginPermissionError.notGranted) { try permissions.require(permission: .writeClipboard, package: package) }
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .writeClipboard)
        let writeLease = try permissions.require(permission: .writeClipboard, package: package)
        try broker.writeText("written with write only", pluginID: alpha, authorization: writeLease)
        assertThrows(PluginPermissionError.notGranted) { try permissions.require(permission: .readClipboard, package: package) }
        try permissions.applyHostDecision(decision: .denied, review: review, permission: .readClipboard)
        assertThrows(PluginPermissionError.denied) { try permissions.require(permission: .readClipboard, package: package) }
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .readClipboard)
        let readLease = try permissions.require(permission: .readClipboard, package: package)
        XCTAssertEqual(try broker.readText(pluginID: alpha, authorization: readLease), "written with write only")
        try permissions.applyHostDecision(decision: .revoked, review: review, permission: .readClipboard)
        assertThrows(PluginPermissionError.revoked) { try broker.readText(pluginID: alpha, authorization: readLease) }
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .readClipboard)
        assertThrows(PluginPermissionError.revoked) { try broker.readText(pluginID: alpha, authorization: readLease) }
        XCTAssertEqual(try broker.readText(pluginID: alpha, authorization: permissions.require(permission: .readClipboard, package: package)), "written with write only")
        try broker.writeText("write grant survived", pluginID: alpha, authorization: writeLease)
    }

    func testClipboardEmptyTextRoundTripAnd4096UTF8BoundaryPreservePreviousValueOnRejectedWrite() throws {
        let authorization = try authorization(permission: .writeClipboard)
        try authorization.permissions.applyHostDecision(decision: .granted, review: authorization.review, permission: .readClipboard)
        let readLease = try authorization.permissions.require(permission: .readClipboard, package: authorization.package)
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let broker = PluginClipboardBroker(pasteboard: board)
        board.clearContents()
        XCTAssertNil(try broker.readText(pluginID: alpha, authorization: readLease))
        try broker.writeText("", pluginID: alpha, authorization: authorization.lease)
        XCTAssertNil(try broker.readText(pluginID: alpha, authorization: readLease))
        let boundary = String(repeating: "界", count: 1_365) + "x"
        XCTAssertEqual(boundary.utf8.count, 4_096)
        try broker.writeText(boundary, pluginID: alpha, authorization: authorization.lease)
        XCTAssertEqual(try broker.readText(pluginID: alpha, authorization: readLease), boundary)
        let unchangedCount = board.changeCount
        assertThrows(PluginClipboardError.quotaExceeded) {
            try broker.writeText(boundary + "x", pluginID: alpha, authorization: authorization.lease)
        }
        XCTAssertEqual(board.changeCount, unchangedCount)
        XCTAssertEqual(board.string(forType: .string), boundary)
    }

    func testClipboardRejectsNonTextFileReferencesMultipleItemsAndOversizedReads() throws {
        let authorization = try authorization(permission: .readClipboard)
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let broker = PluginClipboardBroker(pasteboard: board)
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        assertThrows(PluginClipboardError.unsupportedContent) { try broker.readText(pluginID: alpha, authorization: authorization.lease) }
        board.clearContents()
        board.setString("a plain representation cannot hide a file reference", forType: .string)
        board.setString("file:///private/resource.txt", forType: .fileURL)
        assertThrows(PluginClipboardError.unsupportedContent) { try broker.readText(pluginID: alpha, authorization: authorization.lease) }
        board.clearContents()
        let one = NSPasteboardItem()
        let two = NSPasteboardItem()
        one.setString("one", forType: .string)
        two.setString("two", forType: .string)
        XCTAssertTrue(board.writeObjects([one, two]))
        assertThrows(PluginClipboardError.unsupportedContent) { try broker.readText(pluginID: alpha, authorization: authorization.lease) }
        board.clearContents()
        board.setString(String(repeating: "x", count: 4_097), forType: .string)
        assertThrows(PluginClipboardError.quotaExceeded) { try broker.readText(pluginID: alpha, authorization: authorization.lease) }
        board.clearContents()
        board.setData(Data([0xff, 0xfe]), forType: .string)
        assertThrows(PluginClipboardError.readFailed) { try broker.readText(pluginID: alpha, authorization: authorization.lease) }
    }

    func testClipboardLeasesCannotCrossReadWritePermissionOrPluginIdentity() throws {
        let read = try authorization(permission: .readClipboard)
        let write = try authorization(permission: .writeClipboard)
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        board.setString("must remain", forType: .string)
        let broker = PluginClipboardBroker(pasteboard: board)
        let before = board.changeCount
        assertThrows(PluginPermissionError.undeclared) { try broker.readText(pluginID: alpha, authorization: write.lease) }
        assertThrows(PluginPermissionError.undeclared) { try broker.writeText("wrong lease", pluginID: alpha, authorization: read.lease) }
        assertThrows(PluginPermissionError.undeclared) { try broker.readText(pluginID: "com.example.resources.other", authorization: read.lease) }
        assertThrows(PluginPermissionError.undeclared) { try broker.writeText("other owner", pluginID: "com.example.resources.other", authorization: write.lease) }
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "must remain")
    }

    func testSelectedTextBoundaryReturnsOnlyNameMIMETextAndSize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "界", count: 21_845) + "x"
        XCTAssertEqual(text.utf8.count, 65_536)
        let file = directory.appendingPathComponent("chosen.md")
        try Data(text.utf8).write(to: file)
        let authorization = try authorization(permission: .userSelectedFiles)
        let chooser = ResourceSelectionHarness(automaticURL: file)
        let selected = try await success(begin(chooser.broker(), lease: authorization.lease))
        let response = try XCTUnwrap(selected)
        XCTAssertEqual(response.name, "chosen.md")
        XCTAssertEqual(response.type, "text/markdown")
        XCTAssertEqual(response.text, text)
        XCTAssertEqual(response.size, 65_536)
        XCTAssertEqual(chooser.selectionCount, 1)
        XCTAssertFalse(String(reflecting: response).contains(directory.path))
    }

    func testSelectedResourceRejectsSymlinkDirectoryUnsupportedTypeInvalidUTF8AndNUL() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("safe.txt")
        try Data("safe text".utf8).write(to: target)
        let symbolic = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        let childDirectory = directory.appendingPathComponent("directory.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: false)
        let image = directory.appendingPathComponent("image.png")
        try Data("text disguised as image".utf8).write(to: image)
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data([0xff, 0xfe]).write(to: invalid)
        let binary = directory.appendingPathComponent("binary.txt")
        try Data([65, 0, 66]).write(to: binary)
        let authorization = try authorization(permission: .userSelectedFiles)
        for url in [symbolic, childDirectory, image] {
            let chooser = ResourceSelectionHarness(automaticURL: url)
            try await assertFailure(begin(chooser.broker(), lease: authorization.lease), .policyDenied)
        }
        for url in [invalid, binary] {
            let chooser = ResourceSelectionHarness(automaticURL: url)
            try await assertFailure(begin(chooser.broker(), lease: authorization.lease), .invalidText)
        }
    }

    func testSelectedOversizedTextFailsBeforeDeliveringPartialContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("too-large.json")
        try Data(repeating: 97, count: 65_537).write(to: oversized)
        let authorization = try authorization(permission: .userSelectedFiles)
        let chooser = ResourceSelectionHarness(automaticURL: oversized)
        try await assertFailure(begin(chooser.broker(), lease: authorization.lease), .tooLarge)
    }

    func testFileWrongPermissionOrOwnerAndInactiveAdmissionNeverPresentChooser() throws {
        let file = try authorization(permission: .userSelectedFiles)
        let clipboard = try authorization(permission: .readClipboard)
        let chooser = ResourceSelectionHarness()
        let broker = chooser.broker()
        let completion: @Sendable (Result<PluginFileResponse?, PluginFileError>) -> Void = { _ in XCTFail("An inadmissible request completed.") }
        assertThrows(PluginPermissionError.undeclared) {
            try broker.start(request: PluginFileRequest(), pluginID: alpha, displayName: "Test",
                authorization: clipboard.lease, admission: PluginResourceAdmission(), completion: completion)
        }
        assertThrows(PluginPermissionError.undeclared) {
            try broker.start(request: PluginFileRequest(), pluginID: "com.example.resources.other", displayName: "Test",
                authorization: file.lease, admission: PluginResourceAdmission(), completion: completion)
        }
        let inactive = PluginResourceAdmission()
        inactive.revoke()
        assertThrows(PluginResourceError.inactiveExecution) {
            try broker.start(request: PluginFileRequest(), pluginID: alpha, displayName: "Test",
                authorization: file.lease, admission: inactive, completion: completion)
        }
        XCTAssertEqual(chooser.selectionCount, 0)
    }

    func testSharedFileBrokerRejectsAdditionalChooserWithoutQueueAndReleasesSlotAfterCancellation() async throws {
        let authorization = try authorization(permission: .userSelectedFiles)
        let other = try self.authorization(permission: .userSelectedFiles, id: "com.example.resources.other")
        let chooser = ResourceSelectionHarness()
        let broker = chooser.broker()
        let first = begin(broker, lease: authorization.lease)
        try await waitUntil { chooser.selectionCount == 1 }
        let overflow = begin(broker, lease: other.lease)
        try await assertFailure(overflow, .quotaExceeded)
        XCTAssertEqual(chooser.selectionCount, 1)
        chooser.deliver(nil)
        let firstValue = try await success(first)
        XCTAssertNil(firstValue)
        let fresh = begin(broker, lease: other.lease)
        try await waitUntil { chooser.selectionCount == 2 }
        chooser.deliver(nil, selection: 1)
        let freshValue = try await success(fresh)
        XCTAssertNil(freshValue)
        XCTAssertEqual(first.count, 1)
    }

    func testChooserCancellationReturnsNullAndCompletesOnlyOnceWithoutReadingALateURL() async throws {
        let authorization = try authorization(permission: .userSelectedFiles)
        let chooser = ResourceSelectionHarness()
        let broker = chooser.broker()
        let result = begin(broker, lease: authorization.lease)
        try await waitUntil { chooser.selectionCount == 1 }
        XCTAssertEqual(chooser.selectionCount, 1)
        chooser.deliver(nil)
        let selected = try await success(result)
        XCTAssertNil(selected)
        chooser.deliver(URL(fileURLWithPath: "/etc/passwd"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(result.count, 1)
    }

    func testLifecycleRevocationClosesHeldChooserAndIgnoresLateSelectionExactlyOnce() async throws {
        let authorization = try authorization(permission: .userSelectedFiles)
        let chooser = ResourceSelectionHarness()
        let broker = chooser.broker()
        let admission = PluginResourceAdmission()
        let result = begin(broker, lease: authorization.lease, admission: admission)
        try await waitUntil { chooser.selectionCount == 1 }
        XCTAssertEqual(chooser.selectionCount, 1)
        admission.revoke()
        try await assertFailure(result, .inactiveExecution)
        XCTAssertEqual(chooser.tokens.first?.cancellationCount, 1)
        chooser.deliver(URL(fileURLWithPath: "/etc/passwd"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(result.count, 1)
        let inactive = begin(broker, lease: authorization.lease, admission: admission)
        try await assertFailure(inactive, .inactiveExecution)
        XCTAssertEqual(chooser.selectionCount, 1)
    }

    func testFilePermissionRevocationCancelsSelectionAndRegrantCannotReviveOldOperation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("selected.txt")
        try Data("fresh grant only".utf8).write(to: file)
        let authorization = try authorization(permission: .userSelectedFiles)
        let chooser = ResourceSelectionHarness()
        let broker = chooser.broker()
        let old = begin(broker, lease: authorization.lease)
        try await waitUntil { chooser.selectionCount == 1 }
        try authorization.permissions.applyHostDecision(decision: .revoked, review: authorization.review, permission: .userSelectedFiles)
        try await assertFailure(old, .permissionRevoked)
        XCTAssertEqual(chooser.tokens.first?.cancellationCount, 1)
        try authorization.permissions.applyHostDecision(decision: .granted, review: authorization.review, permission: .userSelectedFiles)
        chooser.deliver(file)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(old.count, 1)
        let obsolete = begin(broker, lease: authorization.lease)
        try await assertFailure(obsolete, .permissionRevoked)
        XCTAssertEqual(chooser.selectionCount, 1)
        let freshLease = try authorization.permissions.require(permission: .userSelectedFiles, package: authorization.package)
        let fresh = begin(broker, lease: freshLease)
        try await waitUntil { chooser.selectionCount == 2 }
        chooser.deliver(file, selection: 1)
        let selected = try await success(fresh)
        XCTAssertEqual(try XCTUnwrap(selected).text, "fresh grant only")
    }

    func testRealJavaScriptFrozenAPIsValidateArgumentsAndReturnSelectedDTOWithoutPaths() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.json")
        let text = String(repeating: "x", count: 6_000)
        try Data(text.utf8).write(to: file)
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let chooser = ResourceSelectionHarness(automaticURL: file)
        let fixture = UserResourceRuntimeFixture(files: chooser.broker(), clipboard: PluginClipboardBroker(pasteboard: board))
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() {
                run().catch(error => { globalThis.unexpected = error.code; globalThis.done = true; });
            }
            async function run() {
                globalThis.apiFrozen = Object.isFrozen(island.files) && Object.isFrozen(island.clipboard) &&
                    island.files.supported === true && island.clipboard.supported === true;
                globalThis.invalid = [];
                for (const operation of [
                    () => island.files.chooseText('/etc/passwd'),
                    () => island.files.chooseText({path:'/etc/passwd'}),
                    () => island.clipboard.readText('extra'),
                    () => island.clipboard.writeText(123),
                    () => island.clipboard.writeText('ok', 'extra'),
                    () => island.clipboard.writeText('x'.repeat(4097))
                ]) {
                    try { await operation(); invalid.push('unexpected success'); }
                    catch (error) { invalid.push(error.code); }
                }
                await island.clipboard.writeText('selected clipboard');
                globalThis.roundtrip = await island.clipboard.readText();
                const selected = await island.files.chooseText();
                globalThis.dtoValid = Object.isFrozen(selected) && Object.getPrototypeOf(selected) === null &&
                    Object.keys(selected).sort().join(',') === 'name,size,text,type' &&
                    selected.name === 'large.json' && selected.type === 'application/json' &&
                    selected.text.length === 6000 && selected.size === 6000 &&
                    !('path' in selected) && !('url' in selected) && !('bookmark' in selected);
                globalThis.done = true;
            }
            """)
        try fixture.grant([.readClipboard, .writeClipboard, .userSelectedFiles], package: package)
        let runtime = fixture.load(package)
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "apiFrozen && dtoValid", equals: .boolean(true))
        try await assertJavaScript(runtime, "typeof unexpected", equals: .string("undefined"))
        try await assertJavaScript(runtime, "roundtrip", equals: .string("selected clipboard"))
        try await assertJavaScript(runtime, "invalid.slice(0,5).every(code => code === 'invalidArguments') && invalid[5] === 'quotaExceeded'", equals: .boolean(true))
        XCTAssertEqual(chooser.selectionCount, 1, "Invalid plugin arguments reached the Host chooser.")
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testRealJavaScriptPendingFileSelectionDoesNotBlockStorageClipboardOrActivity() async throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        let chooser = ResourceSelectionHarness()
        let fixture = UserResourceRuntimeFixture(files: chooser.broker(), clipboard: PluginClipboardBroker(pasteboard: board))
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() { globalThis.started = true; }
            function select() {
                globalThis.selectionDone = false;
                island.files.chooseText().then(value => {
                    globalThis.selectionCode = value === null ? 'cancelled' : 'ok'; globalThis.selectionDone = true;
                }, error => { globalThis.selectionCode = error.code; globalThis.selectionDone = true; });
            }
            function independent() {
                Promise.all([island.storage.set('ready', true), island.clipboard.writeText('independent'),
                    island.activity.publish({id:'independent', presentation:{title:'Chooser waiting'}})
                ]).then(() => { globalThis.independentDone = true; });
            }
            """)
        try fixture.grant([.userSelectedFiles, .writeClipboard, .localStorage], package: package)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        _ = try await runtime.evaluateForTesting("select(); independent(); void 0")
        try await waitUntil { chooser.selectionCount == 1 }
        try await marker(runtime, "independentDone")
        try await assertJavaScript(runtime, "selectionDone", equals: .boolean(false))
        let stored = try await fixture.store.get(pluginID: alpha, key: "ready")
        XCTAssertEqual(stored, .boolean(true))
        XCTAssertEqual(board.string(forType: .string), "independent")
        XCTAssertEqual(fixture.manager.current?.presentation.title, "Chooser waiting")
        let review = try fixture.permissions.snapshot(package: package).review
        try fixture.permissions.applyHostDecision(decision: .revoked, review: review, permission: .userSelectedFiles)
        try await marker(runtime, "selectionDone")
        try await assertJavaScript(runtime, "selectionCode", equals: .string("permissionRevoked"))
        chooser.deliver(URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertEqual(chooser.tokens.first?.cancellationCount, 1)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testRealJavaScriptClipboardRequestedDeniedRevokedAndRegrantStayIndependentWhileVMRuns() async throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let chooser = ResourceSelectionHarness()
        let fixture = UserResourceRuntimeFixture(files: chooser.broker(), clipboard: PluginClipboardBroker(pasteboard: board))
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() { globalThis.started = true; }
            function read() {
                globalThis.readDone = false;
                island.clipboard.readText().then(value => {
                    globalThis.readCode = 'ok'; globalThis.readValue = value; globalThis.readDone = true;
                }, error => { globalThis.readCode = error.code; globalThis.readDone = true; });
            }
            function write() {
                globalThis.writeDone = false;
                island.clipboard.writeText('approved write').then(() => {
                    globalThis.writeCode = 'ok'; globalThis.writeDone = true;
                }, error => { globalThis.writeCode = error.code; globalThis.writeDone = true; });
            }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        let review = try fixture.permissions.snapshot(package: package).review
        _ = try await runtime.evaluateForTesting("read(); write(); void 0")
        try await marker(runtime, "readDone")
        try await marker(runtime, "writeDone")
        try await assertJavaScript(runtime, "readCode", equals: .string("permissionNotGranted"))
        try await assertJavaScript(runtime, "writeCode", equals: .string("permissionNotGranted"))
        XCTAssertEqual(board.string(forType: .string), "original")
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .writeClipboard)
        _ = try await runtime.evaluateForTesting("read(); write(); void 0")
        try await marker(runtime, "readDone")
        try await marker(runtime, "writeDone")
        try await assertJavaScript(runtime, "readCode", equals: .string("permissionNotGranted"))
        try await assertJavaScript(runtime, "writeCode", equals: .string("ok"))
        try fixture.permissions.applyHostDecision(decision: .denied, review: review, permission: .readClipboard)
        _ = try await runtime.evaluateForTesting("read(); void 0")
        try await marker(runtime, "readDone")
        try await assertJavaScript(runtime, "readCode", equals: .string("permissionDenied"))
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .readClipboard)
        _ = try await runtime.evaluateForTesting("read(); void 0")
        try await marker(runtime, "readDone")
        try await assertJavaScript(runtime, "readValue", equals: .string("approved write"))
        try fixture.permissions.applyHostDecision(decision: .revoked, review: review, permission: .readClipboard)
        _ = try await runtime.evaluateForTesting("read(); write(); void 0")
        try await marker(runtime, "readDone")
        try await marker(runtime, "writeDone")
        try await assertJavaScript(runtime, "readCode", equals: .string("permissionRevoked"))
        try await assertJavaScript(runtime, "writeCode", equals: .string("ok"))
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .readClipboard)
        _ = try await runtime.evaluateForTesting("read(); void 0")
        try await marker(runtime, "readDone")
        try await assertJavaScript(runtime, "readCode", equals: .string("ok"))
        XCTAssertEqual(chooser.selectionCount, 0)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testBridgeChecksPermissionsBeforeChooserAndRejectsRawPathOrUnexpectedClipboardFields() async throws {
        let board = privatePasteboard()
        defer { board.releaseGlobally() }
        board.setString("unchanged", forType: .string)
        let chooser = ResourceSelectionHarness()
        let fixture = UserResourceRuntimeFixture(files: chooser.broker(), clipboard: PluginClipboardBroker(pasteboard: board))
        defer { fixture.shutdown() }
        let package = try package(source: "function onStart() { globalThis.started = true; }")
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        let context = try XCTUnwrap(fixture.context)
        let requested = await fixture.bridge.handle(envelope("files.chooseText", params: [:]), package: package, context: context)
        XCTAssertEqual(try errorCode(requested), "permissionNotGranted")
        let review = try fixture.permissions.snapshot(package: package).review
        try fixture.permissions.applyHostDecision(decision: .denied, review: review, permission: .userSelectedFiles)
        let denied = await fixture.bridge.handle(envelope("files.chooseText", params: [:]), package: package, context: context)
        XCTAssertEqual(try errorCode(denied), "permissionDenied")
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .userSelectedFiles)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .writeClipboard)
        for params in [["path": PluginBridgeJSON.string("/etc/passwd")], ["url": .string("file:///etc/passwd")], ["bookmark": .string("native")]] {
            let response = await fixture.bridge.handle(envelope("files.chooseText", params: params), package: package, context: context)
            XCTAssertEqual(try errorCode(response), "invalidArguments")
            XCTAssertFalse(response.contains("/etc/passwd"))
        }
        let invalidWrite = await fixture.bridge.handle(envelope("clipboard.writeText", params: ["text": .string("replacement"), "path": .string("/etc/passwd")]), package: package, context: context)
        XCTAssertEqual(try errorCode(invalidWrite), "invalidArguments")
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        XCTAssertEqual(chooser.selectionCount, 0)
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("DynamicIslandTests.resources.\(UUID().uuidString)"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PluginUserResources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func authorization(permission: PluginPermission, id: String = "com.example.resources.alpha") throws -> ResourceAuthorizationFixture {
        let permissions = PermissionManager()
        let package = try package(id: id)
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: permission)
        return .init(permissions: permissions, package: package, review: review,
                     lease: try permissions.require(permission: permission, package: package))
    }

    private func package(id: String = "com.example.resources.alpha", source: String = "") throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "User Resource Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.readClipboard, .writeClipboard, .userSelectedFiles, .localStorage],
            capabilities: [.localStorage, .publishActivity])
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/resource-tests/\(id)", isDirectory: true),
                     entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func begin(_ broker: PluginFileBroker, lease: PluginPermissionLease,
                       admission: PluginResourceAdmission = PluginResourceAdmission()) -> ResourceFileResultRecorder {
        let recorder = ResourceFileResultRecorder()
        do {
            try broker.start(request: PluginFileRequest(), pluginID: lease.pluginID, displayName: "Test Plugin",
                             authorization: lease, admission: admission) { recorder.record($0) }
        } catch let error as PluginFileError { recorder.record(.failure(error)) }
        catch PluginPermissionError.revoked { recorder.record(.failure(.permissionRevoked)) }
        catch PluginResourceError.inactiveExecution { recorder.record(.failure(.inactiveExecution)) }
        catch { XCTFail("Unexpected file start error: \(error)."); recorder.record(.failure(.readFailed)) }
        return recorder
    }

    private func success(_ recorder: ResourceFileResultRecorder) async throws -> PluginFileResponse? {
        try await waitUntil { recorder.count > 0 }
        return try XCTUnwrap(recorder.first).get()
    }

    private func assertFailure(_ recorder: ResourceFileResultRecorder, _ expected: PluginFileError,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil { recorder.count > 0 }
        guard case .failure(let error) = try XCTUnwrap(recorder.first, file: file, line: line) else {
            XCTFail("Expected \(expected), received a selected resource.", file: file, line: line)
            return
        }
        XCTAssertEqual(error, expected, file: file, line: line)
        XCTAssertEqual(recorder.count, 1, file: file, line: line)
    }

    private func assertThrows<E: Error & Equatable, T>(_ expected: E,
                                                      file: StaticString = #filePath, line: UInt = #line,
                                                      _ operation: () throws -> T) {
        do { _ = try operation(); XCTFail("Expected \(expected).", file: file, line: line) }
        catch { XCTAssertEqual(error as? E, expected, file: file, line: line) }
    }

    private func envelope(_ method: String, params: [String: PluginBridgeJSON]) -> String {
        try! PluginBridgeJSON.object(["apiVersion": .string("1.0.0"), "method": .string(method), "params": .object(params)]).encodedString()
    }

    private func errorCode(_ response: String) throws -> String? {
        let data = try XCTUnwrap(response.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        return (object["error"] as? [String: Any])?["code"] as? String
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("User resource test timed out."); throw ResourceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        try await waitUntil { runtime.snapshot.state == .running || runtime.snapshot.lastFailure != nil }
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { XCTFail("JavaScript marker \(name) did not settle."); throw ResourceTestError.timedOut }
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
private struct ResourceAuthorizationFixture {
    let permissions: PermissionManager
    let package: ValidatedPluginPackage
    let review: PluginPermissionReview
    let lease: PluginPermissionLease
}

@MainActor
private final class ResourceSelectionToken: PluginFileSelectionCancelling {
    var cancellationCount = 0
    func cancel() { cancellationCount += 1 }
}

@MainActor
private final class ResourceSelectionHarness {
    private let automaticURL: URL?
    private var callbacks: [@MainActor @Sendable (URL?) -> Void] = []
    var tokens: [ResourceSelectionToken] = []
    var selectionCount: Int { callbacks.count }

    init(automaticURL: URL? = nil) { self.automaticURL = automaticURL }

    func broker() -> PluginFileBroker {
        PluginFileBroker(selection: { [self] _, callback in
            let token = ResourceSelectionToken()
            tokens.append(token)
            callbacks.append(callback)
            if let automaticURL { callback(automaticURL) }
            return token
        })
    }

    func deliver(_ url: URL?, selection: Int = 0) { callbacks[selection](url) }
}

private nonisolated final class ResourceFileResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<PluginFileResponse?, PluginFileError>] = []
    var count: Int { lock.withLock { values.count } }
    var first: Result<PluginFileResponse?, PluginFileError>? { lock.withLock { values.first } }
    func record(_ result: Result<PluginFileResponse?, PluginFileError>) { lock.withLock { values.append(result) } }
}

@MainActor
private final class UserResourceRuntimeFixture {
    let permissions = PermissionManager()
    let store = PluginStorage()
    let manager: ActivityManager
    let bridge: PluginJSBridge
    let lifecycle: PluginLifecycleBridge
    private let factory = ResourceRuntimeFactory()
    var context: PluginExecutionContext? { factory.context }

    init(files: PluginFileBroker, clipboard: PluginClipboardBroker) {
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 100_000)), configuration: .immediate)
        self.manager = manager
        let service = PluginJSBridge(storage: store, permissions: permissions, files: files, clipboard: clipboard)
        bridge = service
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), permissions: permissions, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return ResourceRuntimeForwarder(runtime: runtime, factory: factory)
        })
    }

    func grant(_ grants: [PluginPermission], package: ValidatedPluginPackage) throws {
        let review = permissions.request(package: package)
        for permission in grants { try permissions.applyHostDecision(decision: .granted, review: review, permission: permission) }
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class ResourceRuntimeFactory {
    var runtimes: [PluginRuntime] = []
    var context: PluginExecutionContext?
}

@MainActor
private final class ResourceRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    private let factory: ResourceRuntimeFactory
    init(runtime: PluginRuntime, factory: ResourceRuntimeFactory) { self.runtime = runtime; self.factory = factory }
    func onStart(context: PluginExecutionContext) throws { factory.context = context; try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated enum ResourceTestError: Error { case timedOut }
