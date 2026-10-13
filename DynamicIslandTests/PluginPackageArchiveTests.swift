import Darwin
import Foundation
import XCTest
import zlib
@testable import DynamicIsland

@MainActor
final class PluginPackageArchiveTests: XCTestCase {
    func testStoredAndDeflatedMembersNestedEntryAndPrivateModes() async throws {
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        let source = Data("function onStart() { globalThis.ready = true; }".utf8)
        let archive = try ZIPFixture.archive([
            .init(name: "manifest.json", body: Data("{}".utf8)),
            .init(name: "resources/main.js", body: source, method: 8),
            .directory("resources/"),
            .init(name: "resources/empty.bin", body: Data(), method: 8)
        ], reverseCentral: true, comment: Data("archive comment".utf8))
        try workspace.write(archive)
        try await ArchiveTestExecutor().extract(workspace)
        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("resources/main.js")), source)
        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("resources/empty.bin")), Data())
        XCTAssertEqual(try mode(workspace.destination), 0o700)
        XCTAssertEqual(try mode(workspace.destination.appendingPathComponent("resources")), 0o700)
        XCTAssertEqual(try mode(workspace.destination.appendingPathComponent("manifest.json")), 0o600)
        XCTAssertEqual(try mode(workspace.destination.appendingPathComponent("resources/main.js")), 0o600)
        var status = stat()
        XCTAssertEqual(lstat(workspace.destination.appendingPathComponent("resources/main.js").path, &status), 0)
        XCTAssertEqual(status.st_uid, geteuid())
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testRawDeflateAtExactBufferBoundaryAndDeclaredOutputLimit() async throws {
        let body = Data(repeating: 65, count: 65_536)
        let archive = try ZIPFixture.archive([.manifest(), .init(name: "index.js", body: body, method: 8)])
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        try workspace.write(archive)
        let limits = PluginPackageLimits(maxSingleFileBytes: 65_536, maxTotalFileBytes: 65_538)
        try await ArchiveTestExecutor().extract(workspace, limits: limits)
        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("index.js")), body)
    }

    func testSafeTimestampAndUIDExtrasDoNotNeedEqualLocalAndCentralPayloads() async throws {
        let local = ZIPFixture.extra(0x5455, Data([7] + Array(repeating: 0, count: 12)))
            + ZIPFixture.extra(0x7875, Data([1, 1, 0, 1, 0]))
        let central = ZIPFixture.extra(0x5455, Data([7] + Array(repeating: 0, count: 4)))
            + ZIPFixture.extra(0x7875, Data([1, 1, 0, 1, 0]))
        var entry = ZIPFixture.Entry.manifest()
        entry.localExtra = local; entry.centralExtra = central
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        try workspace.write(try ZIPFixture.archive([entry, .init(name: "index.js", body: Data("ok".utf8))]))
        try await ArchiveTestExecutor().extract(workspace)
        XCTAssertEqual(try mode(workspace.destination.appendingPathComponent("manifest.json")), 0o600)
    }

    func testTraversalAbsoluteDriveBackslashControlsAndEmptyComponentsAreRejected() async throws {
        for name in ["../outside", "a/../../outside", "/absolute", "C:/drive", "C:relative", "a\\b", "a//b", "./a", "a/./b", "a\u{0000}b", "a\nb", "/", "a//"] {
            try await assertRejected([.manifest(), .init(name: name, body: Data())], expected: .invalidEntry)
        }
    }

    func testDuplicateCaseFoldNFCAndImplicitParentCollisionsAreRejected() async throws {
        let pairs = [("same", "same"), ("File.txt", "file.txt"), ("café.txt", "cafe\u{0301}.txt"),
                     ("A/x", "a/y"), ("café/x", "cafe\u{0301}/y"), ("Straße/x", "STRASSE/y")]
        for (first, second) in pairs {
            try await assertRejected([.manifest(), .init(name: first, body: Data()), .init(name: second, body: Data())], expected: .invalidEntry)
        }
        try await assertRejected([.manifest(), .init(name: "folder", body: Data()), .init(name: "folder/file", body: Data())], expected: .invalidEntry)
        try await assertRejected([.manifest(), .directory("folder/"), .directory("folder/")], expected: .invalidEntry)
    }

    func testSymlinksSpecialFilesUnixSpecialBitsAndDOSVolumeLabelsAreRejected() async throws {
        for kind in [S_IFLNK, S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK] {
            var entry = ZIPFixture.Entry(name: "unsafe", body: Data("target".utf8))
            entry.attributes = UInt32(kind | 0o600) << 16
            try await assertRejected([.manifest(), entry], expected: .invalidEntry)
        }
        for mode in [0o104600, 0o102600, 0o101600] {
            var entry = ZIPFixture.Entry(name: "unsafe", body: Data())
            entry.attributes = UInt32(mode) << 16
            try await assertRejected([.manifest(), entry], expected: .invalidEntry)
        }
        var volume = ZIPFixture.Entry(name: "volume", body: Data())
        volume.creator = 20; volume.attributes = 8
        try await assertRejected([.manifest(), volume], expected: .invalidEntry)
        var directoryAsFile = ZIPFixture.Entry(name: "directory", body: Data())
        directoryAsFile.attributes = UInt32(S_IFDIR | 0o700) << 16 | 0x10
        try await assertRejected([.manifest(), directoryAsFile], expected: .invalidEntry)
        var fileAsDirectory = ZIPFixture.Entry.directory("folder/")
        fileAsDirectory.attributes = UInt32(S_IFREG | 0o600) << 16
        try await assertRejected([.manifest(), fileAsDirectory], expected: .invalidEntry)
    }

    func testEncryptedDescriptorZip64UnknownMethodAndUnsupportedExtraAreRejected() async throws {
        for flags: UInt16 in [1, 8, 64, 0x2000, 0x4000] {
            var entry = ZIPFixture.Entry.manifest(); entry.flags = flags
            try await assertRejected([entry], expected: .unsupportedArchive)
        }
        for method: UInt16 in [9, 12, 99] {
            var entry = ZIPFixture.Entry.manifest(); entry.method = method
            try await assertRejected([entry], expected: .unsupportedArchive)
        }
        for tag: UInt16 in [0x0001, 0x000d, 0x756e, 0x7075, 0xffff] {
            var entry = ZIPFixture.Entry.manifest()
            entry.localExtra = ZIPFixture.extra(tag, Data()); entry.centralExtra = entry.localExtra
            try await assertRejected([entry], expected: .unsupportedArchive)
        }
        var version = ZIPFixture.Entry.manifest(); version.version = 45
        try await assertRejected([version], expected: .unsupportedArchive)
        var sentinel = ZIPFixture.Entry.manifest(); sentinel.expanded = .max
        try await assertRejected([sentinel], expected: .unsupportedArchive)
    }

    func testMalformedDuplicateExtrasAndInvalidNameEncodingAreRejected() async throws {
        for extra in [Data([0x55, 0x54, 5, 0, 1]), ZIPFixture.extra(0x5455, Data([7, 0, 0, 0, 0, 0])),
                      ZIPFixture.extra(0x7875, Data([1, 0, 1, 0])),
                      ZIPFixture.extra(0x5455, Data([0])) + ZIPFixture.extra(0x5455, Data([0]))] {
            var entry = ZIPFixture.Entry.manifest(); entry.centralExtra = extra
            try await assertRejected([entry], expected: .invalidArchive)
        }
        var invalid = ZIPFixture.Entry.manifest(); invalid.rawName = Data([0xff])
        try await assertRejected([invalid], expected: .invalidEntry)
        var unflagged = ZIPFixture.Entry(name: "资源.js", body: Data()); unflagged.flags = 0
        try await assertRejected([.manifest(), unflagged], expected: .invalidEntry)
    }

    func testLocalHeaderDisagreementAndAliasedOffsetsAreRejected() async throws {
        var entry = ZIPFixture.Entry.manifest(); entry.localName = Data("different.json".utf8)
        try await assertRejected([entry], expected: .invalidArchive)
        entry = .manifest(); entry.localFlags = 0
        try await assertRejected([entry], expected: .invalidArchive)
        entry = .manifest(); entry.localCRC = 1
        try await assertRejected([entry], expected: .invalidArchive)
        entry = .manifest(); entry.localExpanded = 1
        try await assertRejected([entry], expected: .invalidArchive)
        var second = ZIPFixture.Entry(name: "index.js", body: Data("js".utf8)); second.localOffset = 0
        try await assertRejected([.manifest(), second], expected: .invalidArchive)
    }

    func testOverlappingOtherwiseValidLocalRecordsAreRejectedBeforeStaging() async throws {
        let name = Data("index.js".utf8), body = Data("js".utf8)
        var nested = Data()
        nested.append32(0x04034b50); nested.append16(20); nested.append16(0x0800)
        nested.append16(0); nested.append16(0); nested.append16(0)
        nested.append32(ZIPFixture.checksum(body)); nested.append32(UInt32(body.count)); nested.append32(UInt32(body.count))
        nested.append16(UInt16(name.count)); nested.append16(0); nested.append(name); nested.append(body)
        var second = ZIPFixture.Entry(name: "index.js", body: body)
        second.localOffset = UInt32(30 + Data("manifest.json".utf8).count)
        // Every local/central field agrees; index.js points inside the first
        // member's stored payload, so only the span coverage check rejects it.
        try await assertRejected([.init(name: "manifest.json", body: nested), second], expected: .invalidArchive)
    }

    func testZip64SignatureBytesInOrdinaryPayloadAreDataNotStructuralRecords() async throws {
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        let payload = Data([0x50, 0x4b, 0x06, 0x06, 0x50, 0x4b, 0x06, 0x07])
        var pythonFile = ZIPFixture.Entry(name: "asset.bin", body: payload)
        pythonFile.attributes = 0o600 << 16
        var dosFile = ZIPFixture.Entry(name: "index.js", body: Data("js".utf8))
        dosFile.creator = 20; dosFile.attributes = 0x20
        try workspace.write(try ZIPFixture.archive([.manifest(), pythonFile, dosFile]))
        try await ArchiveTestExecutor().extract(workspace)
        XCTAssertEqual(try Data(contentsOf: workspace.destination.appendingPathComponent("asset.bin")), payload)
    }

    func testPrefixGapsHiddenRecordsFooterDisksCountsAndTrailingDataAreRejected() async throws {
        let entries = [ZIPFixture.Entry.manifest(), .init(name: "index.js", body: Data("js".utf8))]
        for archive in [try ZIPFixture.archive(entries, prefix: Data([0])),
                        try ZIPFixture.archive(entries, gap: Data([0])),
                        try ZIPFixture.archive(entries, omitLastCentral: true)] {
            try await assertRejected(archive, expected: .invalidArchive)
        }
        let archive = try ZIPFixture.archive(entries)
        var spanned = archive; spanned.write16(1, at: spanned.count - 22 + 4)
        try await assertRejected(spanned, expected: .unsupportedArchive)
        var wrongCount = archive; wrongCount.write16(1, at: wrongCount.count - 22 + 8)
        try await assertRejected(wrongCount, expected: .unsupportedArchive)
        var zip64 = archive; zip64.write32(.max, at: zip64.count - 22 + 16)
        try await assertRejected(zip64, expected: .unsupportedArchive)
        var trailing = archive; trailing.append(1)
        try await assertRejected(trailing, expected: .invalidArchive)
        try await assertRejected(Data(archive.dropLast()), expected: .invalidArchive)
        try await assertRejected(Data("not an archive".utf8), expected: .invalidArchive)
    }

    func testCRCTruncatedDeflateTrailingStreamAndDeclaredSizeMismatchCleanStaging() async throws {
        var crc = ZIPFixture.Entry.manifest(); crc.crc = 0
        try await assertRejected([crc], expected: .invalidArchive)
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        let creation = ArchiveCreationCapture()
        try workspace.write(try ZIPFixture.archive([crc]))
        await assertError(.invalidArchive) {
            try await ArchiveTestExecutor().extract(workspace, creation: creation)
        }
        XCTAssertEqual(creation.count, 1)
        XCTAssertEqual(creation.url, workspace.destination)
        XCTAssertGreaterThan(creation.inode ?? 0, 0)
        XCTAssertEqual(creation.mode, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.destination.path))
        let beforeCreation = ArchiveCreationCapture()
        try workspace.write(Data("invalid metadata".utf8))
        await assertError(.invalidArchive) {
            try await ArchiveTestExecutor().extract(workspace, creation: beforeCreation)
        }
        XCTAssertEqual(beforeCreation.count, 0)
        let original = Data(repeating: 65, count: 1_000)
        var truncated = ZIPFixture.Entry(name: "index.js", body: original, method: 8)
        truncated.compressed = try Data(ZIPFixture.deflate(original).dropLast())
        try await assertRejected([.manifest(), truncated], expected: .invalidArchive)
        var trailing = ZIPFixture.Entry(name: "index.js", body: original, method: 8)
        trailing.compressed = try ZIPFixture.deflate(original) + Data([0])
        try await assertRejected([.manifest(), trailing], expected: .invalidArchive)
        var mismatch = ZIPFixture.Entry(name: "index.js", body: original, method: 8); mismatch.expanded = 999
        try await assertRejected([.manifest(), mismatch], expected: .invalidArchive)
    }

    func testDeclaredAndActualExpansionAndMaterializedInventoryLimits() async throws {
        var huge = ZIPFixture.Entry(name: "index.js", body: Data(), method: 8); huge.expanded = 8 * 1_024 * 1_024 + 1
        try await assertRejected([.manifest(), huge], expected: .quotaExceeded)
        var lie = ZIPFixture.Entry(name: "index.js", body: Data(repeating: 0, count: 1_000), method: 8); lie.expanded = 90
        try await assertRejected(try ZIPFixture.archive([.manifest(), lie]), expected: .quotaExceeded,
                                 limits: .init(maxSingleFileBytes: 100))
        var aggregate = ZIPFixture.Entry(name: "index.js", body: Data(repeating: 0, count: 60), method: 8); aggregate.expanded = 40
        try await assertRejected(try ZIPFixture.archive([.manifest(), aggregate]), expected: .quotaExceeded,
                                 limits: .init(maxSingleFileBytes: 70, maxTotalFileBytes: 50))
        let nested = try ZIPFixture.archive([.manifest(), .init(name: "a/b/index.js", body: Data())])
        try await assertRejected(nested, expected: .quotaExceeded, limits: .init(maxEntryCount: 3))
        try await assertRejected(nested, expected: .quotaExceeded, limits: .init(maxDirectoryDepth: 2))
        try await assertRejected(nested, expected: .quotaExceeded, limits: .init(maxRelativePathBytes: 8))
        try await assertRejected(nested, expected: .quotaExceeded, limits: .init(maxRegularFileCount: 1))
    }

    func testRootManifestRequiredAndWrapperOrCaseVariantCannotReplaceIt() async throws {
        try await assertRejected([], expected: .invalidArchive)
        try await assertRejected([.init(name: "index.js", body: Data())], expected: .invalidArchive)
        try await assertRejected([.init(name: "wrapper/manifest.json", body: Data("{}".utf8))], expected: .invalidArchive)
        try await assertRejected([.init(name: "Manifest.json", body: Data("{}".utf8))], expected: .invalidArchive)
        try await assertRejected([.directory("manifest.json/")], expected: .invalidArchive)
    }

    func testExistingDestinationAndSymlinkParentCannotOverwriteExternalFiles() async throws {
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        try workspace.write(try ZIPFixture.archive([.manifest()]))
        let external = workspace.parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = external.appendingPathComponent("marker")
        try Data("unchanged".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: workspace.destination, withDestinationURL: external)
        await assertError(.invalidArguments) { try await ArchiveTestExecutor().extract(workspace) }
        XCTAssertEqual(try Data(contentsOf: marker), Data("unchanged".utf8))
        try FileManager.default.removeItem(at: workspace.destination)
        try FileManager.default.createDirectory(at: workspace.destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        await assertError(.invalidArguments) { try await ArchiveTestExecutor().extract(workspace) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.destination.path))
        let parentAlias = workspace.parent.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: external)
        let destination = parentAlias.appendingPathComponent("new-package")
        await assertError(.extractionFailed) {
            try await ArchiveTestExecutor().extract(archive: workspace.archive, destination: destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("new-package").path))
    }

    func testArchiveSymlinkFIFOAndSparseInputOverFortyMiBAreRejectedBeforeRead() async throws {
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        try workspace.write(try ZIPFixture.archive([.manifest()]))
        let alias = workspace.parent.appendingPathComponent("alias.dip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace.archive)
        await assertError(.unreadableArchive) {
            try await ArchiveTestExecutor().extract(archive: alias, destination: workspace.destination)
        }
        let fifo = workspace.parent.appendingPathComponent("fifo.dip")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertError(.unreadableArchive) {
            try await ArchiveTestExecutor().extract(archive: fifo, destination: workspace.destination)
        }
        let handle = try FileHandle(forWritingTo: workspace.archive)
        try handle.truncate(atOffset: UInt64(PluginPackageArchiveExtractor.maximumArchiveBytes + 1))
        try handle.close()
        await assertError(.quotaExceeded) { try await ArchiveTestExecutor().extract(workspace) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.destination.path))
    }

    private func assertRejected(_ entries: [ZIPFixture.Entry], expected: PluginPackageArchiveError) async throws {
        try await assertRejected(ZIPFixture.archive(entries), expected: expected)
    }
    private func assertRejected(_ archive: Data, expected: PluginPackageArchiveError,
                                limits: PluginPackageLimits = .init()) async throws {
        let workspace = try ArchiveTestWorkspace()
        defer { workspace.remove() }
        try workspace.write(archive)
        await assertError(expected) { try await ArchiveTestExecutor().extract(workspace, limits: limits) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.destination.path))
        XCTAssertEqual(try Data(contentsOf: workspace.archive), archive)
    }
    private func assertError(_ expected: PluginPackageArchiveError, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected fixed archive error.", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginPackageArchiveError, expected, file: file, line: line) }
    }
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private actor ArchiveTestExecutor {
    func extract(_ workspace: ArchiveTestWorkspace, limits: PluginPackageLimits = .init(),
                 creation: ArchiveCreationCapture? = nil) throws {
        if let creation {
            try PluginPackageArchiveExtractor().extract(archiveURL: workspace.archive, destinationURL: workspace.destination,
                limits: limits, onCreate: { creation.record(url: $0, device: $1, inode: $2) })
        } else { try extract(archive: workspace.archive, destination: workspace.destination, limits: limits) }
    }
    func extract(archive: URL, destination: URL, limits: PluginPackageLimits = .init()) throws {
        XCTAssertFalse(Thread.isMainThread)
        try PluginPackageArchiveExtractor().extract(archiveURL: archive, destinationURL: destination, limits: limits)
    }
}

private nonisolated final class ArchiveCreationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedCount = 0
    private var capturedURL: URL?
    private var capturedInode: ino_t?
    private var capturedMode = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return capturedCount }
    var url: URL? { lock.lock(); defer { lock.unlock() }; return capturedURL }
    var inode: ino_t? { lock.lock(); defer { lock.unlock() }; return capturedInode }
    var mode: Int { lock.lock(); defer { lock.unlock() }; return capturedMode }
    func record(url: URL, device: dev_t, inode: ino_t) {
        var status = stat()
        _ = lstat(url.path, &status)
        lock.lock(); defer { lock.unlock() }
        capturedCount += 1; capturedURL = url; capturedInode = inode; capturedMode = Int(status.st_mode & 0o777)
        XCTAssertEqual(status.st_dev, device)
        XCTAssertEqual(status.st_ino, inode)
    }
}

private nonisolated struct ArchiveTestWorkspace: Sendable {
    let parent: URL
    var archive: URL { parent.appendingPathComponent("fixture.dip") }
    var destination: URL { parent.appendingPathComponent("package", isDirectory: true) }
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func write(_ bytes: Data) throws { try bytes.write(to: archive) }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private nonisolated enum ZIPFixture {
    struct Entry {
        let name: String
        let body: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0x0800
        var creator: UInt16 = 0x0314
        var version: UInt16 = 20
        var attributes: UInt32 = UInt32(S_IFREG | 0o644) << 16
        var rawName: Data?
        var localName: Data?
        var localExtra = Data()
        var centralExtra = Data()
        var compressed: Data?
        var expanded: UInt32?
        var crc: UInt32?
        var localFlags: UInt16?
        var localCRC: UInt32?
        var localExpanded: UInt32?
        var localOffset: UInt32?
        static func manifest() -> Self { .init(name: "manifest.json", body: Data("{}".utf8)) }
        static func directory(_ name: String) -> Self {
            var entry = Self(name: name, body: Data()); entry.attributes = UInt32(S_IFDIR | 0o755) << 16 | 0x10
            return entry
        }
    }
    static func archive(_ entries: [Entry], reverseCentral: Bool = false, comment: Data = Data(),
                        prefix: Data = Data(), gap: Data = Data(), omitLastCentral: Bool = false) throws -> Data {
        var bytes = prefix
        var centralRecords: [Data] = []
        for entry in entries {
            let offset = UInt32(bytes.count)
            let name = entry.rawName ?? Data(entry.name.utf8), localName = entry.localName ?? name
            let compressed = try entry.compressed ?? (entry.method == 8 ? deflate(entry.body) : entry.body)
            let expanded = entry.expanded ?? UInt32(entry.body.count), crc = entry.crc ?? checksum(entry.body)
            bytes.append32(0x04034b50); bytes.append16(entry.version); bytes.append16(entry.localFlags ?? entry.flags)
            bytes.append16(entry.method); bytes.append16(0); bytes.append16(0)
            bytes.append32(entry.localCRC ?? crc); bytes.append32(UInt32(compressed.count)); bytes.append32(entry.localExpanded ?? expanded)
            bytes.append16(UInt16(localName.count)); bytes.append16(UInt16(entry.localExtra.count))
            bytes.append(localName); bytes.append(entry.localExtra); bytes.append(compressed)
            var central = Data()
            central.append32(0x02014b50); central.append16(entry.creator); central.append16(entry.version)
            central.append16(entry.flags); central.append16(entry.method); central.append16(0); central.append16(0)
            central.append32(crc); central.append32(UInt32(compressed.count)); central.append32(expanded)
            central.append16(UInt16(name.count)); central.append16(UInt16(entry.centralExtra.count)); central.append16(0)
            central.append16(0); central.append16(0); central.append32(entry.attributes); central.append32(entry.localOffset ?? offset)
            central.append(name); central.append(entry.centralExtra); centralRecords.append(central)
        }
        bytes.append(gap)
        if omitLastCentral { centralRecords.removeLast() }
        if reverseCentral { centralRecords.reverse() }
        let centralOffset = UInt32(bytes.count)
        for record in centralRecords { bytes.append(record) }
        let centralSize = UInt32(bytes.count) - centralOffset
        bytes.append32(0x06054b50); bytes.append16(0); bytes.append16(0)
        bytes.append16(UInt16(centralRecords.count)); bytes.append16(UInt16(centralRecords.count))
        bytes.append32(centralSize); bytes.append32(centralOffset); bytes.append16(UInt16(comment.count)); bytes.append(comment)
        return bytes
    }
    static func extra(_ tag: UInt16, _ bytes: Data) -> Data {
        var extra = Data(); extra.append16(tag); extra.append16(UInt16(bytes.count)); extra.append(bytes); return extra
    }
    static func checksum(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { buffer in
            UInt32(truncatingIfNeeded: crc32(0, buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(buffer.count)))
        }
    }
    static func deflate(_ bytes: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PluginPackageArchiveError.invalidArchive }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: max(64, Int(compressBound(uLong(bytes.count))) + 64))
        try bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(input.count)
            try output.withUnsafeMutableBytes { buffer in
                stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self); stream.avail_out = uInt(buffer.count)
                guard zlib.deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw PluginPackageArchiveError.invalidArchive }
            }
        }
        return Data(output.prefix(Int(stream.total_out)))
    }
}

private nonisolated extension Data {
    mutating func append16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func append32(_ value: UInt32) { for offset in [0, 8, 16, 24] { append(UInt8(truncatingIfNeeded: value >> offset)) } }
    mutating func write16(_ value: UInt16, at offset: Int) { self[offset] = UInt8(truncatingIfNeeded: value); self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8) }
    mutating func write32(_ value: UInt32, at offset: Int) { for shift in [0, 8, 16, 24] { self[offset + shift / 8] = UInt8(truncatingIfNeeded: value >> shift) } }
}
