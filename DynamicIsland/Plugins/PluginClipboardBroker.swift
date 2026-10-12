import AppKit
import Foundation

public nonisolated enum PluginClipboardError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments, quotaExceeded, unsupportedContent, readFailed, writeFailed

    public var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .quotaExceeded: "quotaExceeded"
        case .unsupportedContent: "clipboardUnsupportedContent"
        case .readFailed: "clipboardReadFailed"
        case .writeFailed: "clipboardWriteFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid clipboard arguments."
        case .quotaExceeded: "The clipboard text exceeded the Host size limit."
        case .unsupportedContent: "The clipboard does not contain supported plain text."
        case .readFailed: "The clipboard text could not be read."
        case .writeFailed: "The clipboard text could not be written."
        }
    }
}

/// Explicit, permission-gated plain-text operations. The Host never polls the
/// pasteboard or provides its native objects to a plugin. Tests supply a private
/// named pasteboard so fixtures cannot read or overwrite the system clipboard.
@MainActor
public final class PluginClipboardBroker {
    static let maximumTextBytes = 4_096
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func readText(pluginID: String, authorization: PluginPermissionLease) throws -> String? {
        try authorization.perform(pluginID: pluginID, permission: .readClipboard) {
            let revision = pasteboard.changeCount
            let types = pasteboard.types ?? []
            guard !types.contains(where: { Self.fileRepresentations.contains($0.rawValue) }),
                  (pasteboard.pasteboardItems?.count ?? 0) <= 1 else {
                throw PluginClipboardError.unsupportedContent
            }
            // HTML/RTF representations may coexist with plain text. Read only
            // exact UTF-8 data, without requesting AppKit conversion from URLs,
            // files, rich text, images or other native pasteboard representations.
            guard types.contains(.string) else {
                guard pasteboard.changeCount == revision else { throw PluginClipboardError.readFailed }
                if types.isEmpty { return nil }
                throw PluginClipboardError.unsupportedContent
            }
            guard let data = pasteboard.data(forType: .string) else { throw PluginClipboardError.readFailed }
            guard data.count <= Self.maximumTextBytes else { throw PluginClipboardError.quotaExceeded }
            guard let text = String(data: data, encoding: .utf8) else { throw PluginClipboardError.readFailed }
            guard pasteboard.changeCount == revision else { throw PluginClipboardError.readFailed }
            return text.isEmpty ? nil : text
        }
    }

    public func writeText(_ text: String, pluginID: String, authorization: PluginPermissionLease) throws {
        // Complete validation and construct the exact representation before any
        // clipboard clearing. Invalid text or a stale/wrong grant has no effect.
        guard text.utf8.count <= Self.maximumTextBytes else { throw PluginClipboardError.quotaExceeded }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { throw PluginClipboardError.writeFailed }
        try authorization.perform(pluginID: pluginID, permission: .writeClipboard) {
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw PluginClipboardError.writeFailed }
        }
    }

    private static let fileRepresentations: Set<String> = [
        NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType", "NSFilesPromisePboardType",
        "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.filepromise"
    ]
}
