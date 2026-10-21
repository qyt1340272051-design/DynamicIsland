import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

final class PluginValidatorTests: XCTestCase {
    func testValidPackageReturnsCanonicalMetadataAndImmutableEntryBytesWithoutExecutingIt() throws {
        let fixture = try makePackage(
            entry: "src/index.js",
            entrySource: "throw new Error('validation must not execute plugin code')"
        )
        defer { fixture.remove() }

        let result = try validate(fixture)

        XCTAssertEqual(result.manifest.id, "com.example.test-plugin")
        XCTAssertEqual(result.entryRelativePath, "src/index.js")
        XCTAssertEqual(
            result.canonicalRootURL,
            try canonicalURL(for: fixture.package)
        )
        XCTAssertEqual(result.entrySource, fixture.entrySource)
        XCTAssertEqual(result.regularFileCount, 2)
        XCTAssertEqual(
            result.totalFileBytes,
            UInt64(fixture.manifestData.count + fixture.entrySource.count)
        )

        try Data("changed after validation".utf8).write(to: fixture.entryURL)
        XCTAssertEqual(result.entrySource, fixture.entrySource, "The runtime must receive the validated byte snapshot")
        try FileManager.default.removeItem(at: fixture.entryURL)
        try FileManager.default.createSymbolicLink(at: fixture.entryURL, withDestinationURL: fixture.manifestURL)
        XCTAssertEqual(result.entrySource, fixture.entrySource, "A later path swap must not change the snapshot")
    }

    func testPackageRootMustBeARealStrictDescendantOfAllowedContainer() throws {
        let fixture = try makePackage()
        defer { fixture.remove() }

        let fileRoot = fixture.container.appendingPathComponent("file-root")
        try Data().write(to: fileRoot)
        assertValidationError(
            try validate(package: fileRoot, container: fixture.container),
            code: "packageNotDirectory",
            path: "."
        )

        let missingRoot = fixture.container.appendingPathComponent("missing-root")
        assertValidationError(
            try validate(package: missingRoot, container: fixture.container),
            code: "packageNotFound",
            path: "."
        )

        let symlinkRoot = fixture.container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.package)
        assertValidationError(
            try validate(package: symlinkRoot, container: fixture.container),
            code: "packageRootIsSymlink",
            path: "."
        )

        let siblingContainer = fixture.container.deletingLastPathComponent()
            .appendingPathComponent(fixture.container.lastPathComponent + "-sibling", isDirectory: true)
        let sibling = try makePackage(container: siblingContainer)
        defer { sibling.remove() }
        assertValidationError(
            try validate(package: sibling.package, container: fixture.container),
            code: "packageOutsideAllowedContainer",
            path: "."
        )

        assertValidationError(
            try validate(package: fixture.container, container: fixture.container),
            code: "packageOutsideAllowedContainer",
            path: "."
        )

        assertValidationError(
            try validate(
                package: try XCTUnwrap(URL(string: "https://example.com/plugin")),
                container: fixture.container
            ),
            code: "invalidPackageURL",
            path: "."
        )

        let remotePackage = try XCTUnwrap(
            URL(string: "file://evil.example\(fixture.package.path)")
        )
        assertValidationError(
            try validate(package: remotePackage, container: fixture.container),
            code: "invalidPackageURL",
            path: "."
        )

        let remoteContainer = try XCTUnwrap(
            URL(string: "file://evil.example\(fixture.container.path)")
        )
        assertValidationError(
            try validate(package: fixture.package, container: remoteContainer),
            code: "invalidPackageURL",
            path: "."
        )

        let missingContainer = fixture.container.appendingPathComponent("missing-container")
        assertValidationError(
            try validate(package: fixture.package, container: missingContainer),
            code: "invalidAllowedContainer",
            path: "."
        )

        let realParent = fixture.container.appendingPathComponent("real-parent", isDirectory: true)
        let nestedFixture = try makePackage(container: realParent)
        defer { nestedFixture.remove() }
        let linkedParent = fixture.container.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        assertValidationError(
            try validate(
                package: linkedParent.appendingPathComponent("TestPlugin", isDirectory: true),
                container: fixture.container
            ),
            code: "packageOutsideAllowedContainer",
            path: "."
        )
    }

    func testManifestMustExistWithExactNameAndBeARegularFile() throws {
        let missing = try makePackage()
        defer { missing.remove() }
        try FileManager.default.removeItem(at: missing.manifestURL)
        assertValidationError(
            try validate(missing),
            code: "manifestMissing",
            path: "manifest.json"
        )

        let wrongCase = try makePackage()
        defer { wrongCase.remove() }
        let wrongCaseURL = wrongCase.package.appendingPathComponent("Manifest.json")
        try FileManager.default.moveItem(at: wrongCase.manifestURL, to: wrongCaseURL)
        assertValidationError(
            try validate(wrongCase),
            code: "manifestMissing",
            path: "manifest.json"
        )

        let directory = try makePackage()
        defer { directory.remove() }
        try FileManager.default.removeItem(at: directory.manifestURL)
        try FileManager.default.createDirectory(at: directory.manifestURL, withIntermediateDirectories: false)
        assertValidationError(
            try validate(directory),
            code: "manifestNotRegularFile",
            path: "manifest.json"
        )
    }

    func testMalformedStrictAndOversizedManifestsAreRejectedBeforeEntryUse() throws {
        let malformed = try makePackage()
        defer { malformed.remove() }
        try Data("{".utf8).write(to: malformed.manifestURL)
        assertValidationError(
            try validate(malformed),
            code: "invalidManifest",
            path: "$"
        )

        let missingField = try makePackage()
        defer { missingField.remove() }
        try manifestData { $0.removeValue(forKey: "capabilities") }.write(to: missingField.manifestURL)
        assertValidationError(
            try validate(missingField),
            code: "invalidManifest",
            path: "$.capabilities"
        )

        let duplicateField = try makePackage()
        defer { duplicateField.remove() }
        var duplicateJSON = try XCTUnwrap(String(data: duplicateField.manifestData, encoding: .utf8))
        duplicateJSON = duplicateJSON.replacingOccurrences(
            of: #""id":"com.example.test-plugin""#,
            with: #""id":"com.example.test-plugin","id":"com.example.test-plugin""#
        )
        try Data(duplicateJSON.utf8).write(to: duplicateField.manifestURL)
        assertValidationError(
            try validate(duplicateField),
            code: "invalidManifest",
            path: "$.id"
        )

        let oversized = try makePackage()
        defer { oversized.remove() }
        try Data(repeating: 32, count: PluginManifest.Limits.maxJSONBytes + 1)
            .write(to: oversized.manifestURL)
        assertValidationError(
            try validate(oversized),
            code: "invalidManifest",
            path: "$"
        )
    }

    func testManifestRejectsTraversalBeforeFilesystemEntryLookup() throws {
        let fixture = try makePackage()
        defer { fixture.remove() }
        try manifestData { $0["entry"] = "../outside.js" }.write(to: fixture.manifestURL)

        assertValidationError(
            try validate(fixture),
            code: "invalidManifest",
            path: "$.entry"
        )
    }

    func testEntryMustExistWithExactCaseAndBeARegularFile() throws {
        let missing = try makePackage()
        defer { missing.remove() }
        try FileManager.default.removeItem(at: missing.entryURL)
        assertValidationError(
            try validate(missing),
            code: "entryMissing",
            path: "index.js"
        )

        let wrongCase = try makePackage()
        defer { wrongCase.remove() }
        try FileManager.default.moveItem(
            at: wrongCase.entryURL,
            to: wrongCase.package.appendingPathComponent("Index.js")
        )
        assertValidationError(
            try validate(wrongCase),
            code: "entryMissing",
            path: "index.js"
        )

        let directory = try makePackage()
        defer { directory.remove() }
        try FileManager.default.removeItem(at: directory.entryURL)
        try FileManager.default.createDirectory(at: directory.entryURL, withIntermediateDirectories: false)
        assertValidationError(
            try validate(directory),
            code: "entryNotRegularFile",
            path: "index.js"
        )
    }

    func testRejectsRootManifestEntryIntermediateAndUnrelatedSymbolicLinks() throws {
        let manifestLink = try makePackage()
        defer { manifestLink.remove() }
        let manifestTarget = manifestLink.container.appendingPathComponent("external-manifest.json")
        try manifestLink.manifestData.write(to: manifestTarget)
        try FileManager.default.removeItem(at: manifestLink.manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestLink.manifestURL, withDestinationURL: manifestTarget)
        assertValidationError(
            try validate(manifestLink),
            code: "symbolicLinkNotAllowed",
            path: "manifest.json"
        )

        let entryLink = try makePackage()
        defer { entryLink.remove() }
        let entryTarget = entryLink.container.appendingPathComponent("external-entry.js")
        try Data("external".utf8).write(to: entryTarget)
        try FileManager.default.removeItem(at: entryLink.entryURL)
        try FileManager.default.createSymbolicLink(at: entryLink.entryURL, withDestinationURL: entryTarget)
        assertValidationError(
            try validate(entryLink),
            code: "symbolicLinkNotAllowed",
            path: "index.js"
        )

        let intermediateLink = try makePackage(entry: "alias/index.js")
        defer { intermediateLink.remove() }
        let realDirectory = intermediateLink.package.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        try Data("real".utf8).write(to: realDirectory.appendingPathComponent("index.js"))
        try FileManager.default.removeItem(at: intermediateLink.entryURL.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            at: intermediateLink.entryURL.deletingLastPathComponent(),
            withDestinationURL: realDirectory
        )
        assertValidationError(
            try validate(intermediateLink),
            code: "symbolicLinkNotAllowed",
            path: "alias"
        )

        let unrelatedBrokenLink = try makePackage()
        defer { unrelatedBrokenLink.remove() }
        let broken = unrelatedBrokenLink.package.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(
            atPath: broken.path,
            withDestinationPath: unrelatedBrokenLink.package.appendingPathComponent("absent").path
        )
        assertValidationError(
            try validate(unrelatedBrokenLink),
            code: "symbolicLinkNotAllowed",
            path: "broken"
        )
    }

    func testRejectsHardLinksAndSpecialFilesAnywhereInPackage() throws {
        let hardLink = try makePackage()
        defer { hardLink.remove() }
        let externalSource = hardLink.container.appendingPathComponent("external-source.js")
        try Data("external".utf8).write(to: externalSource)
        let linkedEntry = hardLink.package.appendingPathComponent("linked-entry.js")
        XCTAssertEqual(Darwin.link(externalSource.path, linkedEntry.path), 0)
        assertValidationError(
            try validate(hardLink),
            code: "hardLinkNotAllowed",
            path: "linked-entry.js"
        )

        let fifo = try makePackage()
        defer { fifo.remove() }
        let fifoURL = fifo.package.appendingPathComponent("messages.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)
        assertValidationError(
            try validate(fifo),
            code: "unsupportedFileType",
            path: "messages.pipe"
        )
    }

    func testEntryAndRegularFileCountLimitsAcceptBoundaryAndRejectOneMore() throws {
        let exactEntries = try makePackage(entry: "src/index.js")
        defer { exactEntries.remove() }
        XCTAssertNoThrow(try validate(exactEntries, limits: limits(maxEntryCount: 3)))

        let tooManyEntries = try makePackage(entry: "src/index.js")
        defer { tooManyEntries.remove() }
        try Data().write(to: tooManyEntries.package.appendingPathComponent("extra"))
        assertValidationError(
            try validate(tooManyEntries, limits: limits(maxEntryCount: 3)),
            code: "tooManyEntries",
            path: "."
        )

        let exactFiles = try makePackage()
        defer { exactFiles.remove() }
        XCTAssertNoThrow(try validate(exactFiles, limits: limits(maxRegularFileCount: 2)))

        let tooManyFiles = try makePackage()
        defer { tooManyFiles.remove() }
        try Data().write(to: tooManyFiles.package.appendingPathComponent("extra"))
        assertValidationError(
            try validate(tooManyFiles, limits: limits(maxRegularFileCount: 2)),
            code: "tooManyFiles",
            path: "."
        )
    }

    func testDepthAndUTF8RelativePathLimitsUseExactBoundaries() throws {
        let rootEntry = try makePackage()
        defer { rootEntry.remove() }
        XCTAssertNoThrow(try validate(rootEntry, limits: limits(maxDirectoryDepth: 1)))

        let nestedEntry = try makePackage(entry: "src/index.js")
        defer { nestedEntry.remove() }
        assertValidationError(
            try validate(nestedEntry, limits: limits(maxDirectoryDepth: 1)),
            code: "directoryTooDeep",
            path: "src/index.js"
        )

        let exactUTF8 = try makePackage()
        defer { exactUTF8.remove() }
        let thirteenBytes = "界界界界a"
        XCTAssertEqual(thirteenBytes.utf8.count, 13)
        try Data().write(to: exactUTF8.package.appendingPathComponent(thirteenBytes))
        XCTAssertNoThrow(try validate(exactUTF8, limits: limits(maxRelativePathBytes: 13)))

        let longUTF8 = try makePackage()
        defer { longUTF8.remove() }
        let fourteenBytes = "界界界界ab"
        XCTAssertEqual(fourteenBytes.utf8.count, 14)
        try Data().write(to: longUTF8.package.appendingPathComponent(fourteenBytes))
        assertValidationError(
            try validate(longUTF8, limits: limits(maxRelativePathBytes: 13)),
            code: "pathTooLong",
            path: fourteenBytes
        )
    }

    func testSingleFileAndTotalExpandedByteLimitsUseLogicalSizeAtExactBoundaries() throws {
        let exactFile = try makePackage()
        defer { exactFile.remove() }
        let exactFileURL = exactFile.package.appendingPathComponent("blob.dat")
        try Data(repeating: 0x41, count: 1_024).write(to: exactFileURL)
        XCTAssertNoThrow(try validate(exactFile, limits: limits(maxSingleFileBytes: 1_024)))

        let largeFile = try makePackage()
        defer { largeFile.remove() }
        let largeFileURL = largeFile.package.appendingPathComponent("blob.dat")
        try Data(repeating: 0x41, count: 1_025).write(to: largeFileURL)
        assertValidationError(
            try validate(largeFile, limits: limits(maxSingleFileBytes: 1_024)),
            code: "fileTooLarge",
            path: "blob.dat"
        )

        let exactTotal = try makePackage()
        defer { exactTotal.remove() }
        let total = UInt64(exactTotal.manifestData.count + exactTotal.entrySource.count)
        XCTAssertNoThrow(try validate(exactTotal, limits: limits(maxTotalFileBytes: total)))

        assertValidationError(
            try validate(exactTotal, limits: limits(maxTotalFileBytes: total - 1)),
            code: "packageTooLarge",
            path: "."
        )

        let sparse = try makePackage()
        defer { sparse.remove() }
        let sparseURL = sparse.package.appendingPathComponent("sparse.dat")
        try Data().write(to: sparseURL)
        XCTAssertEqual(Darwin.truncate(sparseURL.path, 2_048), 0)
        assertValidationError(
            try validate(sparse, limits: limits(maxSingleFileBytes: 1_024)),
            code: "fileTooLarge",
            path: "sparse.dat"
        )
    }

    func testHiddenAndBundleContentsAreIncludedInWholeTreeLimits() throws {
        let fixture = try makePackage()
        defer { fixture.remove() }
        try Data().write(to: fixture.package.appendingPathComponent(".hidden"))
        let resources = fixture.package
            .appendingPathComponent("Example.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent("asset"))

        // manifest, entry, .hidden, Example.app, Contents, Resources, asset
        XCTAssertNoThrow(try validate(fixture, limits: limits(maxEntryCount: 7)))
        assertValidationError(
            try validate(fixture, limits: limits(maxEntryCount: 6)),
            code: "tooManyEntries",
            path: "."
        )
    }

    func testDuplicateIdentifiersAreRejectedFromInjectedSnapshot() throws {
        let fixture = try makePackage(id: "com.example.duplicate")
        defer { fixture.remove() }

        assertValidationError(
            try validate(fixture, occupiedPluginIDs: ["com.example.duplicate"]),
            code: "duplicatePluginID",
            path: "manifest.json"
        )
        XCTAssertNoThrow(try validate(fixture, occupiedPluginIDs: ["com.example.other"]))
    }

    func testHostCompatibilityUsesSemVerPrecedenceAndIgnoresBuildMetadata() throws {
        for (minimum, host) in [
            ("0.6.0", "0.6.0"),
            ("0.6.0", "0.7.0"),
            ("1.0.0-rc.1", "1.0.0"),
            ("1.2.3+plugin.9", "1.2.3+host.1")
        ] {
            let fixture = try makePackage(minimumHostVersion: minimum)
            defer { fixture.remove() }
            XCTAssertNoThrow(try validate(fixture, hostVersion: host), "minimum=\(minimum), host=\(host)")
        }

        for (minimum, host) in [
            ("0.6.0", "0.5.9"),
            ("1.0.0", "1.0.0-rc.1")
        ] {
            let fixture = try makePackage(minimumHostVersion: minimum)
            defer { fixture.remove() }
            assertValidationError(
                try validate(fixture, hostVersion: host),
                code: "hostVersionTooOld",
                path: "manifest.json"
            )
        }
    }

    // MARK: - Fixtures

    private struct PackageFixture {
        let container: URL
        let package: URL
        let manifestURL: URL
        let manifestData: Data
        let entryURL: URL
        let entrySource: Data

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    private func makePackage(
        container suppliedContainer: URL? = nil,
        id: String = "com.example.test-plugin",
        entry: String = "index.js",
        minimumHostVersion: String = "0.6.0",
        entrySource: String = "export default { activate() {} }"
    ) throws -> PackageFixture {
        let container = suppliedContainer ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginValidatorTests-\(UUID().uuidString)", isDirectory: true)
        let package = container.appendingPathComponent("TestPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let manifest = try manifestData {
            $0["id"] = id
            $0["entry"] = entry
            $0["minimumHostVersion"] = minimumHostVersion
        }
        let manifestURL = package.appendingPathComponent("manifest.json")
        try manifest.write(to: manifestURL)

        let entryURL = package.appendingPathComponent(entry)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = Data(entrySource.utf8)
        try source.write(to: entryURL)

        return PackageFixture(
            container: container,
            package: package,
            manifestURL: manifestURL,
            manifestData: manifest,
            entryURL: entryURL,
            entrySource: source
        )
    }

    private func manifestData(_ update: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": "com.example.test-plugin",
            "name": "Test Plugin",
            "version": "1.2.3",
            "engine": "javascriptcore",
            "entry": "index.js",
            "minimumHostVersion": "0.6.0",
            "permissions": [],
            "capabilities": []
        ]
        update?(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func limits(
        maxEntryCount: Int = 512,
        maxRegularFileCount: Int = 256,
        maxSingleFileBytes: UInt64 = 8 * 1_024 * 1_024,
        maxTotalFileBytes: UInt64 = 32 * 1_024 * 1_024,
        maxDirectoryDepth: Int = 16,
        maxRelativePathBytes: Int = 1_024
    ) -> PluginPackageLimits {
        PluginPackageLimits(
            maxEntryCount: maxEntryCount,
            maxRegularFileCount: maxRegularFileCount,
            maxSingleFileBytes: maxSingleFileBytes,
            maxTotalFileBytes: maxTotalFileBytes,
            maxDirectoryDepth: maxDirectoryDepth,
            maxRelativePathBytes: maxRelativePathBytes
        )
    }

    private func canonicalURL(for url: URL) throws -> URL {
        guard let canonicalPath = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.free(canonicalPath) }
        return URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
    }

    private func validate(
        _ fixture: PackageFixture,
        hostVersion: String = "0.6.0",
        occupiedPluginIDs: Set<String> = [],
        limits: PluginPackageLimits = PluginPackageLimits()
    ) throws -> ValidatedPluginPackage {
        try validate(
            package: fixture.package,
            container: fixture.container,
            hostVersion: hostVersion,
            occupiedPluginIDs: occupiedPluginIDs,
            limits: limits
        )
    }

    private func validate(
        package: URL,
        container: URL,
        hostVersion: String = "0.6.0",
        occupiedPluginIDs: Set<String> = [],
        limits: PluginPackageLimits = PluginPackageLimits()
    ) throws -> ValidatedPluginPackage {
        let context = PluginValidationContext(
            hostVersion: try SemanticVersion(hostVersion),
            occupiedPluginIDs: occupiedPluginIDs,
            limits: limits,
            allowedContainerURL: container
        )
        return try PluginValidator().validateExpandedPackage(at: package, context: context)
    }

    @discardableResult
    private func assertValidationError<T>(
        _ expression: @autoclosure () throws -> T,
        code: String,
        path: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PluginValidationError? {
        do {
            _ = try expression()
            XCTFail("Expected PluginValidationError", file: file, line: line)
            return nil
        } catch let error as PluginValidationError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertEqual(error.path, path, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
            return error
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }
}
