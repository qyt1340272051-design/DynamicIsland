import Foundation
import UniformTypeIdentifiers

public struct TrayFileItem: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let originalURL: URL
    public let byteCount: Int64

    public nonisolated var displayName: String { originalURL.lastPathComponent }

    public nonisolated var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    public init(id: UUID = UUID(), url: URL, originalURL: URL, byteCount: Int64) {
        self.id = id
        self.url = url
        self.originalURL = originalURL
        self.byteCount = byteCount
    }
}

public protocol FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem]
    func clear() throws
}

public enum TrayFileIconKind: Equatable {
    case imageThumbnail
    case systemIcon(String)

    public nonisolated static func kind(for item: TrayFileItem) -> TrayFileIconKind {
        switch item.originalURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp":
            return .imageThumbnail
        case "mp3", "m4a", "wav", "aac", "flac":
            return .systemIcon("waveform")
        case "mp4", "mov", "m4v":
            return .systemIcon("film")
        case "pdf":
            return .systemIcon("doc.richtext")
        case "zip", "rar", "7z":
            return .systemIcon("archivebox")
        default:
            return .systemIcon("doc")
        }
    }
}

public enum TrayFileDragProvider {
    public nonisolated static let localDragType = UTType(exportedAs: "com.rong5.dynamic-island.tray-file")

    public nonisolated static func itemProvider(for item: TrayFileItem) -> NSItemProvider {
        let provider = NSItemProvider(object: item.url as NSURL)
        provider.suggestedName = item.displayName
        provider.registerDataRepresentation(
            forTypeIdentifier: localDragType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(item.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    public nonisolated static func isLocalTrayDrag(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(localDragType.identifier)
    }

    public nonisolated static func containsLocalTrayDrag(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: isLocalTrayDrag)
    }
}

public struct SandboxFileTrayService: FileTrayService {
    public let trayDirectory: URL
    private let fileManager: FileManager

    public init(
        trayDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicIslandTray", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.trayDirectory = trayDirectory
        self.fileManager = fileManager
    }

    public func importFiles(from urls: [URL]) throws -> [TrayFileItem] {
        try fileManager.createDirectory(at: trayDirectory, withIntermediateDirectories: true)

        return try urls.filter(\.isFileURL).map { source in
            let destination = uniqueDestinationURL(for: source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)

            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            return TrayFileItem(
                url: destination,
                originalURL: source,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
    }

    public func clear() throws {
        try fileManager.createDirectory(at: trayDirectory, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: trayDirectory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    private func uniqueDestinationURL(for filename: String) -> URL {
        let sourceName = filename as NSString
        let stem = sourceName.deletingPathExtension.isEmpty ? "file" : sourceName.deletingPathExtension
        let ext = sourceName.pathExtension
        let suffix = UUID().uuidString.prefix(8)
        let copiedName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"

        return trayDirectory.appendingPathComponent(copiedName, isDirectory: false)
    }
}
