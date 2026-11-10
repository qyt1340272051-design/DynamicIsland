import Combine
import Darwin
import Foundation

/// Placement belongs to the Host and the user's Settings, never the package.
public nonisolated enum PluginToolArea: String, Codable, CaseIterable, Sendable {
    case timer
    case tools

    public var title: String {
        switch self {
        case .timer: "计时区"
        case .tools: "工具区"
        }
    }
}

public nonisolated struct PluginToolPlacementStoreConfiguration: Equatable, Sendable {
    public let rootDirectoryURL: URL

    public init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
    }

    public var directoryURL: URL { rootDirectoryURL.appendingPathComponent("State", isDirectory: true) }
    public var fileURL: URL { directoryURL.appendingPathComponent("plugin-tool-placements-v1.json") }

    public static func applicationSupport() throws -> Self {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return Self(rootDirectoryURL: support.appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true))
    }
}

/// Fixed errors expose no paths or contents from the persistent file.
public nonisolated enum PluginToolPlacementStoreError: Error, Equatable, Sendable {
    case invalidArguments, quotaExceeded, readFailed, writeFailed
}

/// Share one instance between the Runtime and Settings. A failed read remains
/// visible and cannot be replaced by an empty file during a later edit.
@MainActor
public final class PluginToolPlacementStore: ObservableObject {
    nonisolated static let maximumPlacements = 128
    nonisolated static let maximumFileBytes = 65_536

    @Published public private(set) var placements: [String: PluginToolArea] = [:]
    @Published public private(set) var lastError: PluginToolPlacementStoreError?

    private let fileStore: PluginToolPlacementFileStore?
    private let unavailable: Bool

    /// Explicit ephemeral mode is intended for isolated Hosts and tests.
    public init() {
        fileStore = nil
        unavailable = false
    }

    public init(configuration: PluginToolPlacementStoreConfiguration) {
        fileStore = PluginToolPlacementFileStore(configuration: configuration)
        unavailable = false
        restoreInitialState()
    }

    init(configuration: PluginToolPlacementStoreConfiguration,
         replacer: any PluginToolPlacementFileReplacing) {
        fileStore = PluginToolPlacementFileStore(configuration: configuration, replacer: replacer)
        unavailable = false
        restoreInitialState()
    }

    private init(unavailable: Bool) {
        fileStore = nil
        self.unavailable = unavailable
        lastError = .readFailed
    }

    public static func applicationSupport() -> PluginToolPlacementStore {
        do { return try PluginToolPlacementStore(configuration: .applicationSupport()) }
        catch { return PluginToolPlacementStore(unavailable: true) }
    }

    public func area(forPluginID pluginID: String) -> PluginToolArea {
        placements[pluginID] ?? .tools
    }

    /// A user choice survives package updates, disable/enable and app restarts.
    /// Publish only committed state, so a failed write cannot move a live tool.
    public func setArea(_ area: PluginToolArea, forPluginID pluginID: String) throws {
        guard PluginManifest.isValidPluginID(pluginID) else {
            lastError = .invalidArguments
            throw PluginToolPlacementStoreError.invalidArguments
        }
        do {
            var updated = try currentPlacements()
            updated[pluginID] = area
            try Self.validate(updated)
            if let fileStore { try fileStore.save(updated) }
            placements = updated
            lastError = nil
        } catch {
            let fixed = error as? PluginToolPlacementStoreError ?? .writeFailed
            lastError = fixed
            throw fixed
        }
    }

    /// A failed reload retains the last known choices and reports the failure.
    public func reload() throws {
        do {
            let restored = try currentPlacements()
            placements = restored
            lastError = nil
        } catch {
            lastError = .readFailed
            throw PluginToolPlacementStoreError.readFailed
        }
    }

    private func restoreInitialState() {
        do { try reload() }
        catch { /* The published error must remain visible to Settings. */ }
    }

    private func currentPlacements() throws -> [String: PluginToolArea] {
        guard !unavailable else { throw PluginToolPlacementStoreError.readFailed }
        if let fileStore { return try fileStore.load() }
        return placements
    }

    fileprivate nonisolated static func validate(_ placements: [String: PluginToolArea]) throws {
        guard placements.count <= maximumPlacements else { throw PluginToolPlacementStoreError.quotaExceeded }
        guard placements.keys.allSatisfy(PluginManifest.isValidPluginID) else {
            throw PluginToolPlacementStoreError.invalidArguments
        }
        guard try encode(placements).count <= maximumFileBytes else {
            throw PluginToolPlacementStoreError.quotaExceeded
        }
    }

    fileprivate nonisolated static func encode(_ placements: [String: PluginToolArea]) throws -> Data {
        try PluginBridgeJSON.object([
            "schemaVersion": .number(1),
            "placements": .object(placements.mapValues { .string($0.rawValue) })
        ]).encodedData()
    }

    fileprivate nonisolated static func decode(_ data: Data) throws -> [String: PluginToolArea] {
        guard let source = String(data: data, encoding: .utf8) else { throw PluginToolPlacementStoreError.readFailed }
        let value = try PluginBridgeJSON.parse(source, maximumBytes: maximumFileBytes,
                                               maximumDepth: 3, maximumNodes: 256)
        guard case .object(let fields) = value, Set(fields.keys) == ["schemaVersion", "placements"],
              fields["schemaVersion"] == .number(1), case .object(let objects) = fields["placements"] else {
            throw PluginToolPlacementStoreError.readFailed
        }
        var placements: [String: PluginToolArea] = [:]
        for (id, value) in objects {
            guard case .string(let rawArea) = value, let area = PluginToolArea(rawValue: rawArea) else {
                throw PluginToolPlacementStoreError.readFailed
            }
            placements[id] = area
        }
        try validate(placements)
        return placements
    }
}

/// A replacement throws before commit or returns after commit. No fallible
/// operation follows a successful rename; the descriptor binds the directory.
nonisolated protocol PluginToolPlacementFileReplacing: Sendable {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws
}

private nonisolated struct PluginToolPlacementAtomicReplacer: PluginToolPlacementFileReplacing {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        guard renameat(directoryDescriptor, preparedFile.lastPathComponent,
                       directoryDescriptor, destination.lastPathComponent) == 0 else {
            throw PluginToolPlacementStoreError.writeFailed
        }
    }
}

private nonisolated struct PluginToolPlacementFileStore: Sendable {
    let configuration: PluginToolPlacementStoreConfiguration
    let replacer: any PluginToolPlacementFileReplacing

    init(configuration: PluginToolPlacementStoreConfiguration,
         replacer: any PluginToolPlacementFileReplacing = PluginToolPlacementAtomicReplacer()) {
        self.configuration = configuration
        self.replacer = replacer
    }

    func load() throws -> [String: PluginToolArea] {
        do {
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            guard let initial = try inspectFile(directory: directory) else { return [:] }
            let descriptor = openat(directory, configuration.fileURL.lastPathComponent,
                                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw PluginToolPlacementStoreError.readFailed }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, Self.isPrivateFile(opened),
                  Self.sameFile(initial, opened), initial.st_size == opened.st_size else {
                throw PluginToolPlacementStoreError.readFailed
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw PluginToolPlacementStoreError.readFailed }
                if count == 0 { break }
                guard data.count + count <= PluginToolPlacementStore.maximumFileBytes else {
                    throw PluginToolPlacementStoreError.readFailed
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            var ending = stat()
            guard fstat(descriptor, &ending) == 0, Self.isPrivateFile(ending), Self.sameFile(opened, ending),
                  ending.st_size == opened.st_size, data.count == opened.st_size else {
                throw PluginToolPlacementStoreError.readFailed
            }
            return try PluginToolPlacementStore.decode(data)
        } catch { throw PluginToolPlacementStoreError.readFailed }
    }

    func save(_ placements: [String: PluginToolArea]) throws {
        do {
            let data = try PluginToolPlacementStore.encode(placements)
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            let existing = try inspectFile(directory: directory)
            let name = ".plugin-tool-placements-\(UUID().uuidString).tmp"
            let temporary = configuration.directoryURL.appendingPathComponent(name)
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                    S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PluginToolPlacementStoreError.writeFailed }
            defer {
                Darwin.close(descriptor)
                unlinkat(directory, name, 0)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw PluginToolPlacementStoreError.writeFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw PluginToolPlacementStoreError.writeFailed }
                    offset += count
                }
            }
            var prepared = stat()
            guard fsync(descriptor) == 0, fstat(descriptor, &prepared) == 0, Self.isPrivateFile(prepared),
                  prepared.st_size == data.count else { throw PluginToolPlacementStoreError.writeFailed }
            let current = try inspectFile(directory: directory)
            guard (existing == nil && current == nil)
                || (existing != nil && current != nil && Self.sameFile(existing!, current!)) else {
                throw PluginToolPlacementStoreError.writeFailed
            }
            try replacer.replace(preparedFile: temporary, destination: configuration.fileURL, directoryDescriptor: directory)
        } catch { throw PluginToolPlacementStoreError.writeFailed }
    }

    private func openDirectory() throws -> Int32 {
        let root = configuration.rootDirectoryURL
        guard root.isFileURL, root.host(percentEncoded: false).map({ $0.isEmpty }) ?? true,
              !root.path.isEmpty else { throw PluginToolPlacementStoreError.readFailed }
        var initialRoot = stat()
        if lstat(root.path, &initialRoot) != 0 {
            guard errno == ENOENT else { throw PluginToolPlacementStoreError.readFailed }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            guard lstat(root.path, &initialRoot) == 0 else { throw PluginToolPlacementStoreError.readFailed }
        }
        guard Self.isManagedDirectory(initialRoot) else { throw PluginToolPlacementStoreError.readFailed }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw PluginToolPlacementStoreError.readFailed }
        defer { Darwin.close(rootDescriptor) }
        var openedRoot = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0, Self.isManagedDirectory(openedRoot),
              Self.sameFile(initialRoot, openedRoot) else { throw PluginToolPlacementStoreError.readFailed }
        var initial = stat()
        if fstatat(rootDescriptor, "State", &initial, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw PluginToolPlacementStoreError.readFailed }
            if mkdirat(rootDescriptor, "State", S_IRWXU) != 0, errno != EEXIST {
                throw PluginToolPlacementStoreError.readFailed
            }
            guard fstatat(rootDescriptor, "State", &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw PluginToolPlacementStoreError.readFailed
            }
        }
        guard Self.isManagedDirectory(initial), initial.st_mode & 0o777 == 0o700 else {
            throw PluginToolPlacementStoreError.readFailed
        }
        let state = openat(rootDescriptor, "State", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard state >= 0 else { throw PluginToolPlacementStoreError.readFailed }
        var opened = stat()
        guard fstat(state, &opened) == 0, Self.isManagedDirectory(opened), opened.st_mode & 0o777 == 0o700,
              Self.sameFile(initial, opened) else {
            Darwin.close(state)
            throw PluginToolPlacementStoreError.readFailed
        }
        return state
    }

    private func inspectFile(directory: Int32) throws -> stat? {
        var status = stat()
        if fstatat(directory, configuration.fileURL.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw PluginToolPlacementStoreError.readFailed
        }
        guard Self.isPrivateFile(status) else { throw PluginToolPlacementStoreError.readFailed }
        return status
    }

    private static func isManagedDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR && status.st_uid == geteuid()
            && status.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isPrivateFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid() && status.st_nlink == 1
            && status.st_mode & 0o777 == 0o600 && status.st_size >= 0
            && status.st_size <= PluginToolPlacementStore.maximumFileBytes
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
