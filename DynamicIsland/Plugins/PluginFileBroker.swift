import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

public nonisolated enum PluginResourceError: Error, Equatable, Sendable {
    case inactiveExecution
}

/// Shared execution admission for Host-owned user resource operations. Lifecycle
/// invalidation is synchronous; cancellation callbacks run outside this lock.
public nonisolated final class PluginResourceAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public func registerCancellation(_ handler: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw PluginResourceError.inactiveExecution }
        let id = UUID()
        cancellations[id] = handler
        return id
    }

    public func unregister(_ id: UUID) {
        lock.lock(); cancellations.removeValue(forKey: id); lock.unlock()
    }

    public func revoke() {
        lock.lock(); active = false
        let handlers = Array(cancellations.values)
        cancellations.removeAll(); lock.unlock()
        handlers.forEach { $0() }
    }

    public func perform<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw PluginResourceError.inactiveExecution }
        return try operation()
    }
}

nonisolated enum PluginFileError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments, quotaExceeded, policyDenied, tooLarge, invalidText
    case readFailed, inactiveExecution, permissionRevoked

    var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .quotaExceeded: "quotaExceeded"
        case .policyDenied: "filePolicyDenied"
        case .tooLarge: "fileTooLarge"
        case .invalidText: "fileInvalidText"
        case .readFailed: "fileReadFailed"
        case .inactiveExecution: "inactiveExecution"
        case .permissionRevoked: "permissionRevoked"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid file selection arguments."
        case .quotaExceeded: "The Host file selection limit was reached."
        case .policyDenied: "The selected file does not meet the Host file policy."
        case .tooLarge: "The selected file exceeds the Host size limit."
        case .invalidText: "The selected file is not supported UTF-8 text."
        case .readFailed: "The selected file could not be read."
        case .inactiveExecution: "This plugin execution is inactive."
        case .permissionRevoked: "The file authorization is no longer valid."
        }
    }

    static func map(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is PluginResourceError { return .inactiveExecution }
        if error is PluginPermissionError { return .permissionRevoked }
        return .readFailed
    }
}

/// V1 does not accept a plugin-provided path, URL, type filter or panel options.
nonisolated struct PluginFileRequest: Sendable {
    static func parse(_ json: PluginBridgeJSON) throws -> Self {
        guard case .object(let fields) = json, fields.isEmpty else {
            throw PluginFileError.invalidArguments
        }
        return Self()
    }
}

/// Only data leaves the Host. URL, filesystem path and security scope stay here.
nonisolated struct PluginFileResponse: Sendable, Equatable {
    let name: String
    let type: String
    let text: String
    let size: Int
}

@MainActor
public protocol PluginFileSelectionCancelling: AnyObject {
    func cancel()
}

/// One shared production broker permits one chooser/read globally. Tests may
/// inject selection without opening an AppKit panel or weakening file checks.
@MainActor
public final class PluginFileBroker {
    public typealias Selection = @MainActor (
        _ displayName: String, _ complete: @escaping @MainActor @Sendable (URL?) -> Void
    ) -> any PluginFileSelectionCancelling

    nonisolated static let maximumFileBytes = 65_536
    private let selection: Selection
    private var operation: PluginFileOperation?

    public init(selection: Selection? = nil) {
        self.selection = selection ?? Self.selectWithOpenPanel
    }

    /// This schedules the chooser and returns. Completion is delivered once;
    /// canceling a chooser resolves nil while revocation rejects the operation.
    /// Completion executes inside short lifecycle/permission delivery gates. It
    /// must enqueue a reply, without reentering these gates or changing grants.
    func start(request: PluginFileRequest, pluginID: String, displayName: String,
               authorization: PluginPermissionLease, admission: PluginResourceAdmission,
               completion: @escaping @Sendable (Result<PluginFileResponse?, PluginFileError>) -> Void) throws {
        _ = request
        try admission.perform {
            try authorization.perform(pluginID: pluginID, permission: .userSelectedFiles) {
                guard operation == nil else { throw PluginFileError.quotaExceeded }
            }
        }
        let name = String(displayName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(256))
        let current = PluginFileOperation(pluginID: pluginID, authorization: authorization,
            admission: admission, completion: completion, release: { [weak self] in self?.operation = nil })
        operation = current
        do {
            try current.arm()
        } catch {
            operation = nil
            throw PluginFileError.map(error)
        }
        // Queue selection so synchronous start never enters an AppKit modal
        // callback or delivers a bridge response before the caller returns.
        Task { @MainActor [selection] in
            current.present(displayName: name.isEmpty ? pluginID : name, selection: selection)
        }
    }

    private static func selectWithOpenPanel(displayName: String,
                                           complete: @escaping @MainActor @Sendable (URL?) -> Void)
        -> any PluginFileSelectionCancelling {
        let panel = NSOpenPanel()
        panel.title = "Select Text for \(displayName)"
        panel.message = "The plugin ‘\(displayName)’ will receive this file’s text."
        panel.prompt = "Share Text"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType.plainText, .json, .commaSeparatedText]
            + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        let cancellation = PluginOpenPanelCancellation(panel: panel)
        panel.begin { response in
            MainActor.assumeIsolated {
                let selected = response == .OK ? panel.url : nil
                complete(selected)
            }
        }
        return cancellation
    }
}

@MainActor
private final class PluginOpenPanelCancellation: PluginFileSelectionCancelling {
    private let panel: NSOpenPanel
    init(panel: NSOpenPanel) { self.panel = panel }
    func cancel() { panel.cancel(nil); panel.orderOut(nil) }
}

@MainActor
private final class PluginFileOperation {
    private let pluginID: String
    private let authorization: PluginPermissionLease
    private let admission: PluginResourceAdmission
    private let completion: @Sendable (Result<PluginFileResponse?, PluginFileError>) -> Void
    private let release: @MainActor () -> Void
    private var handle: (any PluginFileSelectionCancelling)?
    private var observation: PluginPermissionObservation?
    private var cancellationID: UUID?
    private var finished = false
    private var reading = false
    private var released = false
    private var acceptedSelection = false

    init(pluginID: String, authorization: PluginPermissionLease, admission: PluginResourceAdmission,
         completion: @escaping @Sendable (Result<PluginFileResponse?, PluginFileError>) -> Void,
         release: @escaping @MainActor () -> Void) {
        self.pluginID = pluginID; self.authorization = authorization; self.admission = admission
        self.completion = completion; self.release = release
    }

    func arm() throws {
        cancellationID = try admission.registerCancellation { [weak self] in
            Task { @MainActor [weak self] in self?.finish(.failure(.inactiveExecution)) }
        }
        observation = authorization.observeRevocation { [weak self] in
            Task { @MainActor [weak self] in self?.finish(.failure(.permissionRevoked)) }
        }
    }

    func present(displayName: String, selection: PluginFileBroker.Selection) {
        guard !finished else { return }
        do { try check() } catch { finish(.failure(PluginFileError.map(error))); return }
        let selectedHandle = selection(displayName) { [weak self] url in self?.selected(url) }
        // An injected selector may complete synchronously or revoke permission.
        if finished || acceptedSelection { selectedHandle.cancel() }
        else { handle = selectedHandle }
    }

    private func selected(_ url: URL?) {
        guard !finished, !acceptedSelection else { return }
        acceptedSelection = true
        handle = nil
        do { try check() } catch { finish(.failure(PluginFileError.map(error))); return }
        guard let url else { finish(.success(nil)); return }
        reading = true
        let authorization = authorization, admission = admission, pluginID = pluginID
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<PluginFileResponse?, PluginFileError>
            do {
                try admission.perform {
                    try authorization.perform(pluginID: pluginID, permission: .userSelectedFiles) {}
                }
                result = .success(try PluginSelectedFileReader.read(url))
            } catch { result = .failure(PluginFileError.map(error)) }
            Task { @MainActor in
                reading = false
                if finished { releaseOnce() }
                else { finish(result) }
            }
        }
    }

    private func check() throws {
        try admission.perform {
            try authorization.perform(pluginID: pluginID, permission: .userSelectedFiles) {}
        }
    }

    private func finish(_ result: Result<PluginFileResponse?, PluginFileError>) {
        guard !finished else { return }
        finished = true
        let panelHandle = handle
        handle = nil
        if let cancellationID { admission.unregister(cancellationID) }
        cancellationID = nil
        observation?.cancel(); observation = nil
        panelHandle?.cancel()
        if !reading { releaseOnce() }
        do {
            try admission.perform {
                try authorization.perform(pluginID: pluginID, permission: .userSelectedFiles) {
                    completion(result)
                }
            }
        } catch { completion(.failure(PluginFileError.map(error))) }
    }

    private func releaseOnce() {
        guard !released else { return }
        released = true
        release()
    }
}

nonisolated private enum PluginSelectedFileReader {
    static func read(_ url: URL) throws -> PluginFileResponse {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.utf8.contains(0), !url.hasDirectoryPath else { throw PluginFileError.policyDenied }
        let name = url.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw PluginFileError.policyDenied }
        let type: String
        switch url.pathExtension.lowercased() {
        case "txt", "text": type = "text/plain"
        case "md", "markdown": type = "text/markdown"
        case "json": type = "application/json"
        case "csv": type = "text/csv"
        default: throw PluginFileError.policyDenied
        }
        // NSOpenPanel may have already activated the user-selected sandbox
        // grant. A false return alone is not failure; descriptor access decides.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var before = stat()
        guard lstat(url.path, &before) == 0 else { throw PluginFileError.readFailed }
        guard before.st_mode & S_IFMT == S_IFREG else { throw PluginFileError.policyDenied }
        guard before.st_size >= 0, before.st_size <= PluginFileBroker.maximumFileBytes
        else { throw PluginFileError.tooLarge }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginFileError.readFailed }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw PluginFileError.readFailed }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino else { throw PluginFileError.policyDenied }
        guard opened.st_size >= 0, opened.st_size <= PluginFileBroker.maximumFileBytes
        else { throw PluginFileError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, min(bytes.count,
                    PluginFileBroker.maximumFileBytes + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw PluginFileError.readFailed
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= PluginFileBroker.maximumFileBytes else { throw PluginFileError.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec,
              data.count == Int(opened.st_size) else { throw PluginFileError.readFailed }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0)
        else { throw PluginFileError.invalidText }
        return PluginFileResponse(name: name, type: type, text: text, size: data.count)
    }
}
