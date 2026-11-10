import Combine
import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginToolPlacementStoreTests: XCTestCase {
    private let alpha = "com.example.placement.alpha"
    private let beta = "com.example.placement.beta"

    func testUnassignedPluginsDefaultToToolsAndAreasHaveHostTitles() async throws {
        let store = PluginToolPlacementStore()
        XCTAssertEqual(store.area(forPluginID: alpha), .tools)
        XCTAssertTrue(store.placements.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(PluginToolArea.allCases, [.timer, .tools])
        XCTAssertEqual(PluginToolArea.timer.title, "计时区")
        XCTAssertEqual(PluginToolArea.tools.title, "工具区")
        XCTAssertEqual(try JSONDecoder().decode(PluginToolArea.self, from: JSONEncoder().encode(PluginToolArea.timer)), .timer)
        try store.setArea(.timer, forPluginID: alpha)
        XCTAssertEqual(store.area(forPluginID: alpha), .timer)
        XCTAssertEqual(PluginToolPlacementStore().area(forPluginID: alpha), .tools)
    }

    func testPerPluginChoicesAndReturnToToolsSurviveRestartWithPrivateFileModes() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        try store.setArea(.timer, forPluginID: alpha)
        try store.setArea(.timer, forPluginID: beta)
        try store.setArea(.tools, forPluginID: beta)

        let restarted = PluginToolPlacementStore(configuration: workspace.configuration)
        XCTAssertNil(restarted.lastError)
        XCTAssertEqual(restarted.placements, [alpha: .timer, beta: .tools])
        XCTAssertEqual(restarted.area(forPluginID: alpha), .timer)
        XCTAssertEqual(restarted.area(forPluginID: beta), .tools)
        XCTAssertEqual(try mode(workspace.configuration.rootDirectoryURL), 0o700)
        XCTAssertEqual(try mode(workspace.configuration.directoryURL), 0o700)
        XCTAssertEqual(try mode(workspace.file), 0o600)
        var status = stat()
        XCTAssertEqual(lstat(workspace.file.path, &status), 0)
        XCTAssertEqual(status.st_uid, geteuid())
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testMissingFileStartsEmptyWithoutWritingPlacementFile() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        try FileManager.default.removeItem(at: workspace.configuration.rootDirectoryURL)
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        XCTAssertTrue(store.placements.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.file.path))
        XCTAssertEqual(try mode(workspace.configuration.directoryURL), 0o700)
    }

    func testEachEditRereadsDiskAndKeepsOtherHostInstanceChoices() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let first = PluginToolPlacementStore(configuration: workspace.configuration)
        let second = PluginToolPlacementStore(configuration: workspace.configuration)
        try first.setArea(.timer, forPluginID: alpha)
        try second.setArea(.timer, forPluginID: beta)
        XCTAssertEqual(second.placements, [alpha: .timer, beta: .timer])
        try first.reload()
        XCTAssertEqual(first.placements, second.placements)
    }

    func testInvalidIDsDoNotChangeMemoryOrPersistentChoices() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        try store.setArea(.timer, forPluginID: alpha)
        let before = try Data(contentsOf: workspace.file)
        for id in ["../escape", "single", "Upper.example.plugin", "com.example/escape", "com.example.-plugin", ""] {
            assertFailure(.invalidArguments) { try store.setArea(.tools, forPluginID: id) }
            XCTAssertEqual(store.lastError, .invalidArguments)
        }
        XCTAssertEqual(store.placements, [alpha: .timer])
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
    }

    func testCorruptFutureAndDuplicateJSONCannotBeOverwrittenByUserChoice() async throws {
        let sources = [
            "{\"schemaVersion\":2,\"placements\":{}}",
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"placements\":{}}",
            "{\"schemaVersion\":1,\"placements\":{},\"unknown\":true}",
            "{\"schemaVersion\":1,\"placements\":{\"\(alpha)\":\"timer\",\"\(alpha)\":\"tools\"}}",
            "{\"schemaVersion\":1,\"placements\":{\"\(alpha)\":\"future-area\"}}",
            "{\"schemaVersion\":1,\"placements\":{\"\(alpha)\":true}}",
            "{\"schemaVersion\":1,\"placements\":{\"../escape\":\"timer\"}}",
            "{\"schemaVersion\":1,\"placements\":[]}",
            "{\"schemaVersion\":1,\"placements\":{}} trailing",
            "not JSON"
        ]
        for source in sources { try assertCorrupt(Data(source.utf8)) }
        try assertCorrupt(Data([0xff, 0xfe, 0x00]))
        try assertCorrupt(Data(repeating: 32, count: 65_537))
        let tooMany = Dictionary(uniqueKeysWithValues: (0..<129).map { ("com.example.plugin\($0)", "timer") })
        try assertCorrupt(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "placements": tooMany]))
    }

    func testExternalCorruptionPreservesLastKnownChoiceAndErrorRemainsVisible() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        try store.setArea(.timer, forPluginID: alpha)
        let corrupt = Data("{\"schemaVersion\":2,\"placements\":{}}".utf8)
        try workspace.seed(corrupt)
        assertFailure(.readFailed) { try store.setArea(.tools, forPluginID: alpha) }
        XCTAssertEqual(store.area(forPluginID: alpha), .timer)
        XCTAssertEqual(store.lastError, .readFailed)
        assertFailure(.readFailed) { try store.reload() }
        XCTAssertEqual(store.placements, [alpha: .timer])
        XCTAssertEqual(try Data(contentsOf: workspace.file), corrupt)
    }

    func testReloadAfterValidRepairClearsFailureAndPublishesRestoredChoices() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        try workspace.seed(Data("broken".utf8))
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        XCTAssertEqual(store.lastError, .readFailed)
        try workspace.seed(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "placements": [alpha: "timer"]]))
        try store.reload()
        XCTAssertEqual(store.area(forPluginID: alpha), .timer)
        XCTAssertNil(store.lastError)
    }

    func testAtomicWriteFailureKeepsDiskAndPublishedPlacementAndCleansTemporaryFile() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        try store.setArea(.timer, forPluginID: alpha)
        let before = try Data(contentsOf: workspace.file)
        let replacer = PlacementStoreFailingReplacer()
        let failing = PluginToolPlacementStore(configuration: workspace.configuration, replacer: replacer)
        var published: [[String: PluginToolArea]] = []
        let observation = failing.$placements.sink { published.append($0) }
        defer { observation.cancel() }

        assertFailure(.writeFailed) { try failing.setArea(.tools, forPluginID: alpha) }

        XCTAssertEqual(failing.lastError, .writeFailed)
        XCTAssertEqual(failing.area(forPluginID: alpha), .timer)
        XCTAssertEqual(published, [[alpha: .timer]])
        XCTAssertEqual(replacer.calls, 1)
        XCTAssertEqual(replacer.preparedMode, 0o600)
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.configuration.directoryURL.path),
                       [workspace.file.lastPathComponent])
    }

    func testSuccessfulPlacementPublicationReflectsAlreadyCommittedBytes() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        var committed: [[String: PluginToolArea]] = []
        let observation = store.$placements.dropFirst().sink { choices in
            let restarted = PluginToolPlacementStore(configuration: workspace.configuration)
            XCTAssertEqual(restarted.placements, choices)
            committed.append(choices)
        }
        defer { observation.cancel() }
        try store.setArea(.timer, forPluginID: alpha)
        try store.setArea(.tools, forPluginID: alpha)
        XCTAssertEqual(committed, [[alpha: .timer], [alpha: .tools]])
    }

    func testSymlinkHardlinkAndWritableFileDoNotReadOrOverwriteTargets() async throws {
        for kind in ["symlink", "hardlink", "mode"] {
            let workspace = try PlacementStoreWorkspace()
            defer { workspace.remove() }
            let store = PluginToolPlacementStore(configuration: workspace.configuration)
            try store.setArea(.timer, forPluginID: alpha)
            let before = try Data(contentsOf: workspace.file)
            let external = workspace.configuration.rootDirectoryURL.appendingPathComponent("external.json")
            try before.write(to: external)
            XCTAssertEqual(chmod(external.path, 0o600), 0)
            if kind == "symlink" {
                try FileManager.default.removeItem(at: workspace.file)
                try FileManager.default.createSymbolicLink(at: workspace.file, withDestinationURL: external)
            } else if kind == "hardlink" {
                try FileManager.default.removeItem(at: workspace.file)
                XCTAssertEqual(link(external.path, workspace.file.path), 0)
            } else { XCTAssertEqual(chmod(workspace.file.path, 0o666), 0) }
            let restarted = PluginToolPlacementStore(configuration: workspace.configuration)
            XCTAssertEqual(restarted.lastError, .readFailed)
            XCTAssertTrue(restarted.placements.isEmpty)
            assertFailure(.readFailed) { try store.reload() }
            assertFailure(.readFailed) { try store.setArea(.tools, forPluginID: alpha) }
            XCTAssertEqual(try Data(contentsOf: external), before)
        }
    }

    func testSymlinkAndWritableStateDirectoriesFailClosedWithoutWritingElsewhere() async throws {
        for kind in ["symlink", "mode"] {
            let workspace = try PlacementStoreWorkspace()
            defer { workspace.remove() }
            let external = workspace.configuration.rootDirectoryURL.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(at: workspace.configuration.directoryURL, withDestinationURL: external)
            } else {
                try FileManager.default.createDirectory(at: workspace.configuration.directoryURL, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: NSNumber(value: 0o777)])
                XCTAssertEqual(chmod(workspace.configuration.directoryURL.path, 0o777), 0)
            }
            let store = PluginToolPlacementStore(configuration: workspace.configuration)
            XCTAssertEqual(store.lastError, .readFailed)
            assertFailure(.readFailed) { try store.setArea(.timer, forPluginID: alpha) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        }
    }

    func testSymlinkRootAndForeignOwnedRootFailClosed() async throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        let alias = workspace.configuration.rootDirectoryURL.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace.configuration.rootDirectoryURL)
        let symlink = PluginToolPlacementStore(configuration: .init(rootDirectoryURL: alias))
        XCTAssertEqual(symlink.lastError, .readFailed)
        assertFailure(.readFailed) { try symlink.setArea(.timer, forPluginID: alpha) }
        let foreign = URL(fileURLWithPath: "/private/var/empty", isDirectory: true)
        var status = stat()
        if lstat(foreign.path, &status) == 0, status.st_uid != geteuid() {
            let store = PluginToolPlacementStore(configuration: .init(rootDirectoryURL: foreign))
            XCTAssertEqual(store.lastError, .readFailed)
            assertFailure(.readFailed) { try store.setArea(.timer, forPluginID: alpha) }
        }
    }

    func testFIFOAndDirectoryInPlaceOfFileCannotBlockOrBecomePlacements() async throws {
        for kind in ["fifo", "directory"] {
            let workspace = try PlacementStoreWorkspace()
            defer { workspace.remove() }
            try FileManager.default.createDirectory(at: workspace.configuration.directoryURL, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if kind == "fifo" { XCTAssertEqual(mkfifo(workspace.file.path, 0o600), 0) }
            else {
                try FileManager.default.createDirectory(at: workspace.file, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
            }
            let store = PluginToolPlacementStore(configuration: workspace.configuration)
            XCTAssertEqual(store.lastError, .readFailed)
            assertFailure(.readFailed) { try store.setArea(.timer, forPluginID: alpha) }
            var status = stat()
            XCTAssertEqual(lstat(workspace.file.path, &status), 0)
            XCTAssertEqual(status.st_mode & S_IFMT, kind == "fifo" ? S_IFIFO : S_IFDIR)
        }
    }

    func testQuotaFailurePreservesChoicesAndExistingPluginCanStillMove() async throws {
        let store = PluginToolPlacementStore()
        for index in 0..<128 { try store.setArea(.timer, forPluginID: "com.example.plugin\(index)") }
        assertFailure(.quotaExceeded) { try store.setArea(.tools, forPluginID: "com.example.overflow") }
        XCTAssertEqual(store.placements.count, 128)
        XCTAssertNil(store.placements["com.example.overflow"])
        try store.setArea(.tools, forPluginID: "com.example.plugin0")
        XCTAssertEqual(store.placements["com.example.plugin0"], .tools)
        XCTAssertNil(store.lastError)
    }

    private func assertFailure<T>(_ expected: PluginToolPlacementStoreError,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> T) {
        do { _ = try body(); XCTFail("Expected fixed placement persistence error.", file: file, line: line) }
        catch let error as PluginToolPlacementStoreError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type.", file: file, line: line) }
    }

    private func assertCorrupt(_ bytes: Data) throws {
        let workspace = try PlacementStoreWorkspace()
        defer { workspace.remove() }
        try workspace.seed(bytes)
        let store = PluginToolPlacementStore(configuration: workspace.configuration)
        XCTAssertEqual(store.lastError, .readFailed)
        XCTAssertTrue(store.placements.isEmpty)
        assertFailure(.readFailed) { try store.reload() }
        assertFailure(.readFailed) { try store.setArea(.timer, forPluginID: alpha) }
        XCTAssertEqual(store.lastError, .readFailed)
        XCTAssertEqual(try Data(contentsOf: workspace.file), bytes)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private struct PlacementStoreWorkspace {
    let configuration: PluginToolPlacementStoreConfiguration
    var file: URL { configuration.fileURL }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-tool-placement-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        configuration = .init(rootDirectoryURL: root)
    }

    func seed(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try bytes.write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw PluginToolPlacementStoreError.writeFailed }
    }

    func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
}

private nonisolated final class PlacementStoreFailingReplacer: PluginToolPlacementFileReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private var observedCalls = 0
    private var observedMode = 0

    var calls: Int { lock.lock(); defer { lock.unlock() }; return observedCalls }
    var preparedMode: Int { lock.lock(); defer { lock.unlock() }; return observedMode }

    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        var status = stat()
        _ = fstatat(directoryDescriptor, preparedFile.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW)
        lock.lock()
        observedCalls += 1
        observedMode = Int(status.st_mode & 0o777)
        lock.unlock()
        throw PluginToolPlacementStoreError.writeFailed
    }
}
