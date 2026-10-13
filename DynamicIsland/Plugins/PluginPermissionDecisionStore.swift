import Darwin
import Foundation

/// Host-owned decisions for the exact package bytes reviewed by the user.
/// JavaScript never receives this record or a persistence entry point.
public nonisolated struct PluginPermissionDecisionRecord: Equatable, Sendable {
    public let pluginID: String
    public let fingerprint: String
    public let states: [PluginPermission: PluginPermissionState]

    public init(pluginID: String, fingerprint: String,
                states: [PluginPermission: PluginPermissionState]) {
        self.pluginID = pluginID
        self.fingerprint = fingerprint
        self.states = states
    }
}

public nonisolated struct PluginPermissionDecisionStoreConfiguration: Equatable, Sendable {
    public let rootDirectoryURL: URL

    public init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
    }

    public var directoryURL: URL { rootDirectoryURL.appendingPathComponent("State", isDirectory: true) }
    public var fileURL: URL { directoryURL.appendingPathComponent("plugin-permissions-v1.json") }

    public static func applicationSupport() throws -> Self {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return Self(rootDirectoryURL: support.appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true))
    }
}

/// Fixed errors contain neither file paths nor package or decision contents.
public nonisolated enum PluginPermissionDecisionStoreError: Error, Equatable, Sendable {
    case invalidArguments, quotaExceeded, stalePackage, readFailed, writeFailed
}

/// One Host shares this actor. Mutations never suspend between reading current
/// durable state and committing its replacement. Every operation rereads disk;
/// damaged external bytes cannot be hidden by a previously successful load.
public actor PluginPermissionDecisionStore {
    nonisolated static let maximumRecords = 128
    nonisolated static let maximumFileBytes = 131_072
    private let fileStore: PluginPermissionDecisionFileStore?
    private let unavailable: Bool
    private var memory: [String: PluginPermissionDecisionRecord] = [:]

    /// Explicit ephemeral mode is intended for isolated Hosts and tests.
    public init() {
        fileStore = nil
        unavailable = false
    }

    public init(configuration: PluginPermissionDecisionStoreConfiguration) {
        fileStore = PluginPermissionDecisionFileStore(configuration: configuration)
        unavailable = false
    }

    init(configuration: PluginPermissionDecisionStoreConfiguration,
         replacer: any PluginPermissionDecisionFileReplacing) {
        fileStore = PluginPermissionDecisionFileStore(configuration: configuration, replacer: replacer)
        unavailable = false
    }

    private init(unavailable: Bool) {
        fileStore = nil
        self.unavailable = unavailable
    }

    public nonisolated static func applicationSupport() -> PluginPermissionDecisionStore {
        do { return try PluginPermissionDecisionStore(configuration: .applicationSupport()) }
        catch { return PluginPermissionDecisionStore(unavailable: true) }
    }

    public func load() throws -> [String: PluginPermissionDecisionRecord] {
        guard !unavailable else { throw PluginPermissionDecisionStoreError.readFailed }
        if let fileStore { return try fileStore.load() }
        return memory
    }

    /// Registration of new code cannot import grants from a caller's record.
    /// The Host must use setDecision after registering requested declarations.
    public func replace(record: PluginPermissionDecisionRecord) throws {
        try Self.validate(record)
        var records = try load()
        if records[record.pluginID]?.fingerprint != record.fingerprint {
            guard record.states.values.allSatisfy({ $0 == .requested }) else {
                throw PluginPermissionDecisionStoreError.invalidArguments
            }
        }
        records[record.pluginID] = record
        try save(records)
    }

    /// An old UI review cannot write a decision over a newer package record,
    /// or recreate an approval after the Host has removed the registration.
    public func setDecision(pluginID: String, fingerprint: String,
                            permission: PluginPermission, state: PluginPermissionState) throws {
        try Self.validateIdentity(pluginID, fingerprint)
        var records = try load()
        guard let current = records[pluginID], current.fingerprint == fingerprint else {
            throw PluginPermissionDecisionStoreError.stalePackage
        }
        guard current.states[permission] != nil else { throw PluginPermissionDecisionStoreError.invalidArguments }
        var states = current.states
        states[permission] = state
        records[pluginID] = .init(pluginID: pluginID, fingerprint: fingerprint, states: states)
        try save(records)
    }

    public func remove(pluginID: String) throws {
        guard PluginManifest.isValidPluginID(pluginID) else { throw PluginPermissionDecisionStoreError.invalidArguments }
        var records = try load()
        records.removeValue(forKey: pluginID)
        try save(records)
    }

    private func save(_ records: [String: PluginPermissionDecisionRecord]) throws {
        try Self.validate(records)
        if let fileStore { try fileStore.save(records) }
        else { memory = records }
    }

    fileprivate nonisolated static func validateIdentity(_ pluginID: String, _ fingerprint: String) throws {
        guard PluginManifest.isValidPluginID(pluginID), fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PluginPermissionDecisionStoreError.invalidArguments
        }
    }

    fileprivate nonisolated static func validate(_ record: PluginPermissionDecisionRecord) throws {
        try validateIdentity(record.pluginID, record.fingerprint)
        guard record.states.count <= PluginPermission.allCases.count else {
            throw PluginPermissionDecisionStoreError.invalidArguments
        }
    }

    fileprivate nonisolated static func validate(_ records: [String: PluginPermissionDecisionRecord]) throws {
        guard records.count <= maximumRecords else { throw PluginPermissionDecisionStoreError.quotaExceeded }
        for (id, record) in records {
            guard id == record.pluginID else { throw PluginPermissionDecisionStoreError.invalidArguments }
            try validate(record)
        }
        guard try encode(records).count <= maximumFileBytes else { throw PluginPermissionDecisionStoreError.quotaExceeded }
    }

    fileprivate nonisolated static func encode(_ records: [String: PluginPermissionDecisionRecord]) throws -> Data {
        let objects = records.mapValues { record in
            PluginBridgeJSON.object([
                "pluginID": .string(record.pluginID), "fingerprint": .string(record.fingerprint),
                "states": .object(Dictionary(uniqueKeysWithValues: record.states.map {
                    ($0.key.rawValue, .string($0.value.rawValue))
                }))
            ])
        }
        return try PluginBridgeJSON.object(["schemaVersion": .number(1), "records": .object(objects)]).encodedData()
    }

    fileprivate nonisolated static func decode(_ data: Data) throws -> [String: PluginPermissionDecisionRecord] {
        guard let source = String(data: data, encoding: .utf8) else { throw PluginPermissionDecisionStoreError.readFailed }
        let value = try PluginBridgeJSON.parse(source, maximumBytes: maximumFileBytes,
                                               maximumDepth: 5, maximumNodes: 2_048)
        guard case .object(let fields) = value, Set(fields.keys) == ["schemaVersion", "records"],
              fields["schemaVersion"] == .number(1), case .object(let objects) = fields["records"] else {
            throw PluginPermissionDecisionStoreError.readFailed
        }
        var records: [String: PluginPermissionDecisionRecord] = [:]
        for (id, value) in objects {
            guard case .object(let record) = value,
                  Set(record.keys) == ["pluginID", "fingerprint", "states"], record["pluginID"] == .string(id),
                  case .string(let fingerprint) = record["fingerprint"], case .object(let rawStates) = record["states"] else {
                throw PluginPermissionDecisionStoreError.readFailed
            }
            var states: [PluginPermission: PluginPermissionState] = [:]
            for (rawPermission, value) in rawStates {
                guard let permission = PluginPermission(rawValue: rawPermission),
                      case .string(let rawState) = value, let state = PluginPermissionState(rawValue: rawState) else {
                    throw PluginPermissionDecisionStoreError.readFailed
                }
                states[permission] = state
            }
            records[id] = .init(pluginID: id, fingerprint: fingerprint, states: states)
        }
        try validate(records)
        return records
    }
}

/// A replacement throws before commit or returns after commit. No fallible
/// operation follows a successful rename; the descriptor binds the directory.
nonisolated protocol PluginPermissionDecisionFileReplacing: Sendable {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws
}

private nonisolated struct PluginPermissionDecisionAtomicReplacer: PluginPermissionDecisionFileReplacing {
    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        guard renameat(directoryDescriptor, preparedFile.lastPathComponent,
                       directoryDescriptor, destination.lastPathComponent) == 0 else {
            throw PluginPermissionDecisionStoreError.writeFailed
        }
    }
}

private nonisolated struct PluginPermissionDecisionFileStore: Sendable {
    let configuration: PluginPermissionDecisionStoreConfiguration
    let replacer: any PluginPermissionDecisionFileReplacing

    init(configuration: PluginPermissionDecisionStoreConfiguration,
         replacer: any PluginPermissionDecisionFileReplacing = PluginPermissionDecisionAtomicReplacer()) {
        self.configuration = configuration
        self.replacer = replacer
    }

    func load() throws -> [String: PluginPermissionDecisionRecord] {
        do {
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            guard let initial = try inspectFile(directory: directory) else { return [:] }
            let descriptor = openat(directory, configuration.fileURL.lastPathComponent,
                                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw PluginPermissionDecisionStoreError.readFailed }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, Self.isPrivateFile(opened),
                  Self.sameFile(initial, opened), initial.st_size == opened.st_size else {
                throw PluginPermissionDecisionStoreError.readFailed
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw PluginPermissionDecisionStoreError.readFailed }
                if count == 0 { break }
                guard data.count + count <= PluginPermissionDecisionStore.maximumFileBytes else {
                    throw PluginPermissionDecisionStoreError.readFailed
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            var ending = stat()
            guard fstat(descriptor, &ending) == 0, Self.isPrivateFile(ending), Self.sameFile(opened, ending),
                  ending.st_size == opened.st_size, data.count == opened.st_size else {
                throw PluginPermissionDecisionStoreError.readFailed
            }
            return try PluginPermissionDecisionStore.decode(data)
        } catch { throw PluginPermissionDecisionStoreError.readFailed }
    }

    func save(_ records: [String: PluginPermissionDecisionRecord]) throws {
        do {
            let data = try PluginPermissionDecisionStore.encode(records)
            let directory = try openDirectory()
            defer { Darwin.close(directory) }
            let existing = try inspectFile(directory: directory)
            let name = ".plugin-permissions-\(UUID().uuidString).tmp"
            let temporary = configuration.directoryURL.appendingPathComponent(name)
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                    S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PluginPermissionDecisionStoreError.writeFailed }
            defer {
                Darwin.close(descriptor)
                unlinkat(directory, name, 0)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw PluginPermissionDecisionStoreError.writeFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw PluginPermissionDecisionStoreError.writeFailed }
                    offset += count
                }
            }
            var prepared = stat()
            guard fsync(descriptor) == 0, fstat(descriptor, &prepared) == 0, Self.isPrivateFile(prepared),
                  prepared.st_size == data.count else { throw PluginPermissionDecisionStoreError.writeFailed }
            let current = try inspectFile(directory: directory)
            guard (existing == nil && current == nil)
                || (existing != nil && current != nil && Self.sameFile(existing!, current!)) else {
                throw PluginPermissionDecisionStoreError.writeFailed
            }
            try replacer.replace(preparedFile: temporary, destination: configuration.fileURL, directoryDescriptor: directory)
        } catch { throw PluginPermissionDecisionStoreError.writeFailed }
    }

    private func openDirectory() throws -> Int32 {
        let root = configuration.rootDirectoryURL
        guard root.isFileURL, root.host(percentEncoded: false).map({ $0.isEmpty }) ?? true,
              !root.path.isEmpty else { throw PluginPermissionDecisionStoreError.readFailed }
        var initialRoot = stat()
        if lstat(root.path, &initialRoot) != 0 {
            guard errno == ENOENT else { throw PluginPermissionDecisionStoreError.readFailed }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            guard lstat(root.path, &initialRoot) == 0 else { throw PluginPermissionDecisionStoreError.readFailed }
        }
        guard Self.isManagedDirectory(initialRoot) else { throw PluginPermissionDecisionStoreError.readFailed }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw PluginPermissionDecisionStoreError.readFailed }
        defer { Darwin.close(rootDescriptor) }
        var openedRoot = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0, Self.isManagedDirectory(openedRoot),
              Self.sameFile(initialRoot, openedRoot) else { throw PluginPermissionDecisionStoreError.readFailed }
        var initial = stat()
        if fstatat(rootDescriptor, "State", &initial, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw PluginPermissionDecisionStoreError.readFailed }
            if mkdirat(rootDescriptor, "State", S_IRWXU) != 0, errno != EEXIST {
                throw PluginPermissionDecisionStoreError.readFailed
            }
            guard fstatat(rootDescriptor, "State", &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw PluginPermissionDecisionStoreError.readFailed
            }
        }
        guard Self.isManagedDirectory(initial), initial.st_mode & 0o777 == 0o700 else {
            throw PluginPermissionDecisionStoreError.readFailed
        }
        let state = openat(rootDescriptor, "State", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard state >= 0 else { throw PluginPermissionDecisionStoreError.readFailed }
        var opened = stat()
        guard fstat(state, &opened) == 0, Self.isManagedDirectory(opened), opened.st_mode & 0o777 == 0o700,
              Self.sameFile(initial, opened) else {
            Darwin.close(state)
            throw PluginPermissionDecisionStoreError.readFailed
        }
        return state
    }

    private func inspectFile(directory: Int32) throws -> stat? {
        var status = stat()
        if fstatat(directory, configuration.fileURL.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw PluginPermissionDecisionStoreError.readFailed
        }
        guard Self.isPrivateFile(status) else { throw PluginPermissionDecisionStoreError.readFailed }
        return status
    }

    private static func isManagedDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR && status.st_uid == geteuid()
            && status.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isPrivateFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid() && status.st_nlink == 1
            && status.st_mode & 0o777 == 0o600 && status.st_size >= 0
            && status.st_size <= PluginPermissionDecisionStore.maximumFileBytes
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
