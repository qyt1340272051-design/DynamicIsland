import Darwin
import Foundation

/// Host-owned private storage, outside the directory used to discover packages.
/// Uninstalling a package retains its namespace until the Host explicitly clears it.
public nonisolated struct PluginStorageConfiguration: Equatable, Sendable {
    public let rootDirectoryURL: URL

    public init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
    }

    public var directoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Storage", isDirectory: true)
    }

    public func namespaceFileURL(pluginID: String) throws -> URL {
        guard PluginManifest.isValidPluginID(pluginID) else { throw PluginStorageError.invalidArguments }
        // Only the Host's validated reverse-DNS identity selects a file. KV keys
        // are JSON fields and never participate in filesystem path construction.
        return directoryURL.appendingPathComponent("\(pluginID).json", isDirectory: false)
    }

    public static func applicationSupport() throws -> Self {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        return Self(rootDirectoryURL: support
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true))
    }
}

public nonisolated enum PluginStorageError: Error, Equatable, Sendable {
    case invalidArguments, quotaExceeded, inactiveExecution, readFailed, writeFailed
}

/// One Runtime admission. Preparation may run without holding this lock; the
/// final commit shares a linearization point with synchronous lifecycle revoke.
public nonisolated final class PluginStorageAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    public init() {}

    public func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }

    fileprivate func perform<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard active else { throw PluginStorageError.inactiveExecution }
        return try body()
    }
}

/// Serial KV ownership and file I/O run on this actor, independently of
/// MainActor. Disk namespaces are reread on each operation so damaged bytes
/// never become an empty namespace or disappear behind an in-memory cache.
public actor PluginStorage {
    nonisolated static let maximumKeys = 128
    nonisolated static let maximumNamespaceBytes = 65_536
    nonisolated static let maximumKeyBytes = 128
    nonisolated static let maximumValueBytes = 8_192
    nonisolated static let maximumValueDepth = 8
    nonisolated static let maximumValueNodes = 256
    nonisolated static let maximumStringBytes = 4_096

    private let fileStore: PluginStorageFileStore?
    private let ioObserver: @Sendable () -> Void
    private let unavailable: Bool
    private var memory: [String: [String: PluginBridgeJSON]] = [:]

    /// Explicit in-memory mode supports isolated Host tests and ephemeral Hosts.
    public init() {
        fileStore = nil
        ioObserver = {}
        unavailable = false
    }

    public init(configuration: PluginStorageConfiguration) {
        fileStore = PluginStorageFileStore(configuration: configuration)
        ioObserver = {}
        unavailable = false
    }

    init(configuration: PluginStorageConfiguration,
         replacer: any PluginStorageFileReplacing = PluginStorageAtomicFileReplacer(),
         ioObserver: @escaping @Sendable () -> Void = {}) {
        fileStore = PluginStorageFileStore(configuration: configuration, replacer: replacer)
        self.ioObserver = ioObserver
        unavailable = false
    }

    private init(unavailable: Bool) {
        fileStore = nil
        ioObserver = {}
        self.unavailable = unavailable
    }

    /// Production Hosts fail closed if their durable location is unavailable.
    /// A configuration failure must never silently switch to ephemeral data.
    public nonisolated static func applicationSupport() -> PluginStorage {
        do {
            return try PluginStorage(configuration: .applicationSupport())
        } catch {
            return PluginStorage(unavailable: true)
        }
    }

    func get(pluginID: String, key: String, admission: PluginStorageAdmission? = nil) throws -> PluginBridgeJSON {
        try Self.validatePluginID(pluginID)
        try Self.validateKey(key)
        try check(admission)
        ioObserver()
        let values = try load(pluginID: pluginID)
        return try admitted(admission) { values[key] ?? .null }
    }

    func set(pluginID: String, key: String, value: PluginBridgeJSON,
             admission: PluginStorageAdmission? = nil) throws {
        try Self.validatePluginID(pluginID)
        try Self.validateKey(key)
        try Self.validateValue(value)
        try check(admission)
        ioObserver()
        var values = try load(pluginID: pluginID)
        values[key] = value
        try Self.validateValues(values)
        try save(values, pluginID: pluginID, admission: admission)
    }

    func remove(pluginID: String, key: String, admission: PluginStorageAdmission? = nil) throws {
        try Self.validatePluginID(pluginID)
        try Self.validateKey(key)
        try check(admission)
        ioObserver()
        var values = try load(pluginID: pluginID)
        values.removeValue(forKey: key)
        try save(values, pluginID: pluginID, admission: admission)
    }

    func clear(pluginID: String, admission: PluginStorageAdmission? = nil) throws {
        try Self.validatePluginID(pluginID)
        try check(admission)
        ioObserver()
        // Even clear fails closed on an unreadable namespace; this API is not
        // an implicit repair mechanism for damaged or insecure Host files.
        _ = try load(pluginID: pluginID)
        try save([:], pluginID: pluginID, admission: admission)
    }

    private func load(pluginID: String) throws -> [String: PluginBridgeJSON] {
        if let fileStore { return try fileStore.load(pluginID: pluginID) }
        return memory[pluginID] ?? [:]
    }

    private func save(_ values: [String: PluginBridgeJSON], pluginID: String,
                      admission: PluginStorageAdmission?) throws {
        if let fileStore {
            try fileStore.save(values, pluginID: pluginID) { commit in
                try self.admitted(admission, commit)
            }
        } else {
            try admitted(admission) { memory[pluginID] = values.isEmpty ? nil : values }
        }
    }

    private func check(_ admission: PluginStorageAdmission?) throws {
        guard !unavailable else { throw PluginStorageError.readFailed }
        try admitted(admission) {}
    }

    private func admitted<T>(_ admission: PluginStorageAdmission?, _ body: () throws -> T) throws -> T {
        if let admission { return try admission.perform(body) }
        return try body()
    }

    fileprivate nonisolated static func validatePluginID(_ pluginID: String) throws {
        guard PluginManifest.isValidPluginID(pluginID) else { throw PluginStorageError.invalidArguments }
    }

    fileprivate nonisolated static func validateKey(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginStorageError.invalidArguments
        }
        guard key.utf8.count <= maximumKeyBytes else { throw PluginStorageError.quotaExceeded }
    }

    fileprivate nonisolated static func validateValue(_ value: PluginBridgeJSON) throws {
        do {
            try value.validate(maximumDepth: maximumValueDepth,
                               maximumNodes: maximumValueNodes, maximumStringBytes: maximumStringBytes)
            guard try value.encodedData().count <= maximumValueBytes else {
                throw PluginStorageError.quotaExceeded
            }
        } catch let error as PluginBridgeJSON.ParseError {
            throw error == .limitExceeded ? PluginStorageError.quotaExceeded : .invalidArguments
        } catch let error as PluginStorageError {
            throw error
        } catch {
            throw PluginStorageError.invalidArguments
        }
    }

    fileprivate nonisolated static func validateValues(_ values: [String: PluginBridgeJSON]) throws {
        guard values.count <= maximumKeys else { throw PluginStorageError.quotaExceeded }
        var bytes = 0
        for (key, value) in values {
            try validateKey(key)
            try validateValue(value)
            bytes += key.utf8.count + (try value.encodedData().count)
            guard bytes <= maximumNamespaceBytes else { throw PluginStorageError.quotaExceeded }
        }
    }
}

/// A replacement either throws before commit or returns after commit. No
/// fallible work may follow a successful rename. The descriptor is bound to
/// the inspected Storage directory, preventing directory path substitution.
nonisolated protocol PluginStorageFileReplacing: Sendable {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws
}

private nonisolated struct PluginStorageAtomicFileReplacer: PluginStorageFileReplacing {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        guard renameat(directoryDescriptor, preparedFile.lastPathComponent,
                       directoryDescriptor, destination.lastPathComponent) == 0 else {
            throw PluginStorageError.writeFailed
        }
    }
}

private nonisolated struct PluginStorageFileStore: Sendable {
    static let maximumFileBytes = 131_072
    let configuration: PluginStorageConfiguration
    let replacer: any PluginStorageFileReplacing

    init(configuration: PluginStorageConfiguration,
         replacer: any PluginStorageFileReplacing = PluginStorageAtomicFileReplacer()) {
        self.configuration = configuration
        self.replacer = replacer
    }

    func load(pluginID: String) throws -> [String: PluginBridgeJSON] {
        do {
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            let name = try configuration.namespaceFileURL(pluginID: pluginID).lastPathComponent
            guard let initial = try inspectFile(name, directory: directory) else { return [:] }
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw PluginStorageError.readFailed }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, Self.isPrivateFile(opened),
                  Self.sameFile(initial, opened), opened.st_size == initial.st_size else {
                throw PluginStorageError.readFailed
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw PluginStorageError.readFailed }
                if count == 0 { break }
                guard data.count + count <= Self.maximumFileBytes else { throw PluginStorageError.readFailed }
                data.append(contentsOf: buffer.prefix(count))
            }
            var ending = stat()
            guard fstat(descriptor, &ending) == 0, Self.isPrivateFile(ending),
                  Self.sameFile(opened, ending), ending.st_size == opened.st_size,
                  data.count == opened.st_size else { throw PluginStorageError.readFailed }
            // Reject malformed UTF-8 before parsing; replacement decoding must
            // never turn damaged file bytes into a successful JSON value.
            guard let source = String(data: data, encoding: .utf8) else { throw PluginStorageError.readFailed }
            let json = try PluginBridgeJSON.parse(source, maximumBytes: Self.maximumFileBytes,
                                                 maximumDepth: 12, maximumNodes: 32_772)
            guard case .object(let fields) = json, Set(fields.keys) == ["schemaVersion", "pluginID", "values"],
                  fields["schemaVersion"] == .number(1), fields["pluginID"] == .string(pluginID),
                  case .object(let values) = fields["values"] else { throw PluginStorageError.readFailed }
            try PluginStorage.validateValues(values)
            return values
        } catch {
            throw PluginStorageError.readFailed
        }
    }

    func save(_ values: [String: PluginBridgeJSON], pluginID: String,
              commit: (_ operation: () throws -> Void) throws -> Void) throws {
        do {
            try PluginStorage.validateValues(values)
            let data = try PluginBridgeJSON.object([
                "schemaVersion": .number(1), "pluginID": .string(pluginID), "values": .object(values)
            ]).encodedData()
            guard data.count <= Self.maximumFileBytes else { throw PluginStorageError.writeFailed }
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            let destination = try configuration.namespaceFileURL(pluginID: pluginID)
            let existing = try inspectFile(destination.lastPathComponent, directory: directory)
            let temporaryName = ".plugin-storage-\(UUID().uuidString).tmp"
            let temporaryURL = configuration.directoryURL.appendingPathComponent(temporaryName)
            let descriptor = openat(directory, temporaryName,
                                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PluginStorageError.writeFailed }
            defer {
                Darwin.close(descriptor)
                // Cleanup remains best effort after a successful commit.
                unlinkat(directory, temporaryName, 0)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw PluginStorageError.writeFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw PluginStorageError.writeFailed }
                    offset += count
                }
            }
            var prepared = stat()
            guard fsync(descriptor) == 0, fstat(descriptor, &prepared) == 0,
                  Self.isPrivateFile(prepared), prepared.st_size == data.count else {
                throw PluginStorageError.writeFailed
            }
            let current = try inspectFile(destination.lastPathComponent, directory: directory)
            guard (existing == nil && current == nil)
                    || (existing != nil && current != nil && Self.sameFile(existing!, current!)) else {
                throw PluginStorageError.writeFailed
            }
            try commit {
                try replacer.replace(preparedFile: temporaryURL, destination: destination,
                                     directoryDescriptor: directory)
            }
        } catch let error as PluginStorageError where error == .inactiveExecution {
            throw error
        } catch {
            throw PluginStorageError.writeFailed
        }
    }

    private func openDirectory() throws -> Int32 {
        let root = configuration.rootDirectoryURL
        guard root.isFileURL, root.host(percentEncoded: false).map({ $0.isEmpty }) ?? true,
              !root.path.isEmpty else { throw PluginStorageError.readFailed }
        try Self.ensureRoot(root)
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginStorageError.readFailed }
        defer { Darwin.close(descriptor) }
        var openedRoot = stat()
        var initialRoot = stat()
        guard fstat(descriptor, &openedRoot) == 0, lstat(root.path, &initialRoot) == 0,
              Self.isManagedDirectory(openedRoot), Self.sameFile(initialRoot, openedRoot) else {
            throw PluginStorageError.readFailed
        }
        var initial = stat()
        if fstatat(descriptor, "Storage", &initial, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw PluginStorageError.readFailed }
            if mkdirat(descriptor, "Storage", S_IRWXU) != 0, errno != EEXIST {
                throw PluginStorageError.readFailed
            }
            guard fstatat(descriptor, "Storage", &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw PluginStorageError.readFailed
            }
        }
        guard Self.isManagedDirectory(initial), initial.st_mode & 0o777 == 0o700 else {
            throw PluginStorageError.readFailed
        }
        let storage = openat(descriptor, "Storage", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard storage >= 0 else { throw PluginStorageError.readFailed }
        var opened = stat()
        guard fstat(storage, &opened) == 0, Self.isManagedDirectory(opened),
              opened.st_mode & 0o777 == 0o700, Self.sameFile(initial, opened) else {
            Darwin.close(storage)
            throw PluginStorageError.readFailed
        }
        return storage
    }

    private static func ensureRoot(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw PluginStorageError.readFailed }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            guard lstat(url.path, &status) == 0 else { throw PluginStorageError.readFailed }
        }
        guard isManagedDirectory(status) else { throw PluginStorageError.readFailed }
    }

    private func inspectFile(_ name: String, directory: Int32) throws -> stat? {
        var status = stat()
        if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw PluginStorageError.readFailed
        }
        guard Self.isPrivateFile(status) else { throw PluginStorageError.readFailed }
        return status
    }

    private static func isManagedDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR && status.st_uid == geteuid()
            && status.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isPrivateFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid()
            && status.st_nlink == 1 && status.st_mode & 0o777 == 0o600
            && status.st_size >= 0 && status.st_size <= maximumFileBytes
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
