import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DynamicIsland

final class FileTrayServiceTests: XCTestCase {
    func testImportCopiesFileIntoTrayDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let service = SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true))
        let items = try service.importFiles(from: [source])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].displayName, "source.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].url.path))
        XCTAssertNotEqual(items[0].url, source)
    }

    func testClearRemovesImportedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let service = SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true))
        _ = try service.importFiles(from: [source])
        try service.clear()

        let contents = try FileManager.default.contentsOfDirectory(at: service.trayDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(contents.isEmpty)
    }

    func testTrayFileItemCreatesFileURLDragProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let service = SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true))
        let item = try XCTUnwrap(service.importFiles(from: [source]).first)

        let provider = TrayFileDragProvider.itemProvider(for: item)

        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
        XCTAssertEqual(provider.suggestedName, item.displayName)
    }

    func testTrayFileItemProviderMarksLocalTrayDrag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        let service = SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true))
        let item = try XCTUnwrap(service.importFiles(from: [source]).first)

        let provider = TrayFileDragProvider.itemProvider(for: item)
        let externalProvider = NSItemProvider(object: source as NSURL)

        XCTAssertTrue(TrayFileDragProvider.isLocalTrayDrag(provider))
        XCTAssertFalse(TrayFileDragProvider.isLocalTrayDrag(externalProvider))
    }

    func testImageFilesUseThumbnailIconKind() throws {
        let imageURL = URL(fileURLWithPath: "/tmp/photo.png")
        let item = TrayFileItem(url: imageURL, originalURL: imageURL, byteCount: 10)

        XCTAssertEqual(TrayFileIconKind.kind(for: item), .imageThumbnail)
    }
}
