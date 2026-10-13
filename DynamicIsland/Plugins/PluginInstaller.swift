import CryptoKit
import Darwin
import Foundation

public nonisolated enum PluginInstallerError: String, Error, Equatable, Sendable {
    case invalidArguments, busy, staleReview, stagingFailed, archiveRejected
    case invalidPackage, incompatibleHost, quotaExceeded, installFailed
    case rollbackFailed, cleanupFailed, cancelled
    public var code: String { rawValue }
}

/// Immutable preview of exactly one Host-owned staging package. An opaque
/// identity binds confirmation to this installer and this package's bytes.
public nonisolated struct PluginInstallReview: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: SemanticVersion
    public let developer: String?
    public let permissions: [PluginPermission]
    public let capabilities: [PluginCapability]
    public let previousVersion: SemanticVersion?
    public var isUpgrade: Bool { previousVersion != nil }
    public var isDowngrade: Bool { previousVersion.map { version.precedence(comparedTo: $0) == .orderedAscending } ?? false }
    fileprivate let token: UUID
    fileprivate let package: ValidatedPluginPackage
    fileprivate let expectedCurrent: PluginInstalledSnapshot?
    fileprivate let fingerprint: String
    fileprivate let stagingIdentity: PluginInstallationIdentity

    fileprivate init(token: UUID, package: ValidatedPluginPackage,
                     expectedCurrent: PluginInstalledSnapshot?, fingerprint: String,
                     stagingIdentity: PluginInstallationIdentity) {
        id = package.manifest.id
        name = package.manifest.name
        version = package.manifest.version
        developer = package.manifest.developer
        permissions = package.manifest.permissions.sorted { $0.rawValue < $1.rawValue }
        capabilities = package.manifest.capabilities.sorted { $0.rawValue < $1.rawValue }
        previousVersion = expectedCurrent?.package.manifest.version
        self.token = token
        self.package = package
        self.expectedCurrent = expectedCurrent
        self.fingerprint = fingerprint
        self.stagingIdentity = stagingIdentity
    }
}

/// Owns one preview at a time. Extraction and hashing run on this actor rather
/// than MainActor. Preparation never registers permissions or executes code.
public actor PluginInstaller {
    private let manager: PluginManager
    private let configuration: PluginManagerConfiguration
    private let extractor: PluginPackageArchiveExtractor
    private let validator = PluginValidator()
    private var pending: PluginInstallReview?
    private var cleanupOnly = false
    private var cleanupReservation: (url: URL, identity: PluginInstallationIdentity)?
    private var operationInProgress = false

    public init(manager: PluginManager, configuration: PluginManagerConfiguration,
                extractor: PluginPackageArchiveExtractor = .init()) {
        self.manager = manager
        self.configuration = configuration
        self.extractor = extractor
    }

    public func prepare(archiveURL: URL) async throws -> PluginInstallReview {
        guard !operationInProgress, pending == nil, cleanupReservation == nil else { throw PluginInstallerError.busy }
        operationInProgress = true
        defer { operationInProgress = false }
        var stagedURL: URL?
        var stagedIdentity: PluginInstallationIdentity?
        let createdIdentity = PluginInstallationIdentityCapture()
        do {
            guard configuration == manager.configuration else { throw PluginInstallerError.invalidArguments }
            try Task.checkCancellation()
            let staging = try await manager.prepareInstallationStaging()
            let token = UUID()
            let destination = staging.appendingPathComponent(token.uuidString, isDirectory: true)
            stagedURL = destination
            let limits = try PluginInstallationLimits.bounded(configuration.limits)
            try extractor.extract(archiveURL: archiveURL, destinationURL: destination, limits: limits,
                onCreate: { _, device, inode in createdIdentity.set(.init(device: device, inode: inode)) })
            stagedIdentity = try PluginInstallationIdentity.read(destination)
            try Task.checkCancellation()
            let package = try validator.validateExpandedPackage(at: destination, context: .init(
                hostVersion: configuration.hostVersion, occupiedPluginIDs: [], limits: limits,
                allowedContainerURL: staging))
            let fingerprint = try PluginInstallationFingerprint.read(package.canonicalRootURL, limits: limits)
            let current = await manager.installationSnapshot(id: package.manifest.id)
            try Task.checkCancellation()
            let review = PluginInstallReview(token: token, package: package, expectedCurrent: current,
                fingerprint: fingerprint, stagingIdentity: try requiredIdentity(stagedIdentity))
            pending = review
            return review
        } catch {
            if let stagedURL, let identity = stagedIdentity ?? createdIdentity.get() {
                do { try identity.removeOwnedDirectory(stagedURL) }
                catch {
                    cleanupReservation = (stagedURL, identity)
                    throw PluginInstallerError.cleanupFailed
                }
            }
            throw Self.normalized(error)
        }
    }

    public func cancel(_ review: PluginInstallReview) async throws {
        guard !operationInProgress, pending == review else { throw PluginInstallerError.staleReview }
        do {
            try review.stagingIdentity.removeOwnedDirectory(review.package.canonicalRootURL)
            pending = nil
            cleanupOnly = false
        } catch {
            cleanupOnly = true
            throw PluginInstallerError.cleanupFailed
        }
    }

    public func commit(_ review: PluginInstallReview) async throws -> PluginRecord {
        guard !operationInProgress, !cleanupOnly, pending == review else { throw PluginInstallerError.staleReview }
        pending = nil
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            try Task.checkCancellation()
            return try await manager.installIfCurrent(package: review.package, expectedCurrent: review.expectedCurrent,
                                                     expectedFingerprint: review.fingerprint)
        } catch {
            // A failed transaction may have moved staging to Recovery. Never
            // remove another directory installed at this old path afterward.
            do { try review.stagingIdentity.removeOwnedDirectory(review.package.canonicalRootURL) }
            catch {
                cleanupReservation = (review.package.canonicalRootURL, review.stagingIdentity)
                throw PluginInstallerError.cleanupFailed
            }
            throw Self.normalized(error)
        }
    }

    /// Reports only owned staging cleanup that this installer can retry. A
    /// committed Manager marker warning is shown separately by the UI.
    public func hasPendingCleanup() -> Bool { cleanupReservation != nil || cleanupOnly }

    public func retryCleanup() async throws {
        guard !operationInProgress else { throw PluginInstallerError.busy }
        if cleanupOnly, let pending { try await cancel(pending) }
        if let cleanupReservation {
            do {
                try cleanupReservation.identity.removeOwnedDirectory(cleanupReservation.url)
                self.cleanupReservation = nil
            } catch { throw PluginInstallerError.cleanupFailed }
        }
    }

    private func requiredIdentity(_ identity: PluginInstallationIdentity?) throws -> PluginInstallationIdentity {
        guard let identity else { throw PluginInstallerError.stagingFailed }
        return identity
    }

    private nonisolated static func normalized(_ error: Error) -> PluginInstallerError {
        if let error = error as? PluginInstallerError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? PluginPackageArchiveError {
            switch error {
            case .quotaExceeded: return .quotaExceeded
            case .invalidArguments: return .invalidArguments
            default: return .archiveRejected
            }
        }
        if let error = error as? PluginValidationError {
            switch error {
            case .hostVersionTooOld: return .incompatibleHost
            case .tooManyEntries, .tooManyFiles, .pathTooLong, .directoryTooDeep, .fileTooLarge, .packageTooLarge:
                return .quotaExceeded
            default: return .invalidPackage
            }
        }
        if let error = error as? PluginManagerError {
            switch error {
            case .installStaleReview: return .staleReview
            case .installRollbackFailed: return .rollbackFailed
            case .installCleanupFailed: return .cleanupFailed
            case .validation(let validation): return normalized(validation)
            case .invalidManagedDirectory, .insecureManagedDirectory, .stateReadFailed, .installRecoveryRequired: return .stagingFailed
            default: return .installFailed
            }
        }
        return .installFailed
    }
}

/// Identity checks make best-effort cleanup incapable of deleting replacement
/// directories after a path swap. The parent remains Host-owned and private.
nonisolated struct PluginInstallationIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    static func read(_ url: URL) throws -> Self {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw PluginInstallerError.stagingFailed
        }
        return .init(device: status.st_dev, inode: status.st_ino)
    }
    func removeOwnedDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return }
            throw PluginInstallerError.cleanupFailed
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_dev == device, status.st_ino == inode else { throw PluginInstallerError.cleanupFailed }
        try FileManager.default.removeItem(at: url)
    }
}

private nonisolated final class PluginInstallationIdentityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PluginInstallationIdentity?
    func set(_ value: PluginInstallationIdentity) { lock.withLock { self.value = value } }
    func get() -> PluginInstallationIdentity? { lock.withLock { value } }
}

/// Caps leftovers across installer instances and process restarts. It never
/// follows links, hashes resources, or deletes unrecognized recovery data.
nonisolated enum PluginInstallationSpace {
    static func check(_ directory: URL, maximumRoots: Int, limits: PluginPackageLimits,
                      additionalBytes: UInt64 = 0) throws {
        let limits = try PluginInstallationLimits.bounded(limits)
        let budget = limits.maxTotalFileBytes.multipliedReportingOverflow(by: 4)
        guard !budget.overflow, additionalBytes <= budget.partialValue else {
            throw PluginManagerError.installRecoveryRequired
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count < maximumRoots else { throw PluginManagerError.installRecoveryRequired }
        var count = 0
        var bytes = additionalBytes
        for name in names {
            guard UUID(uuidString: name) != nil else { throw PluginManagerError.installRecoveryRequired }
            try visit(directory.appendingPathComponent(name, isDirectory: true), depth: 0,
                      maximumEntries: limits.maxEntryCount * maximumRoots,
                      maximumBytes: budget.partialValue, count: &count, bytes: &bytes)
        }
    }
    private static func visit(_ url: URL, depth: Int, maximumEntries: Int, maximumBytes: UInt64,
                              count: inout Int, bytes: inout UInt64) throws {
        count += 1
        guard depth <= PluginPackageLimits().maxDirectoryDepth + 1, count <= maximumEntries else {
            throw PluginManagerError.installRecoveryRequired
        }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_uid == geteuid() else { throw PluginManagerError.installRecoveryRequired }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                try visit(url.appendingPathComponent(name), depth: depth + 1, maximumEntries: maximumEntries,
                          maximumBytes: maximumBytes, count: &count, bytes: &bytes)
            }
        case S_IFREG:
            guard status.st_nlink == 1, status.st_size >= 0, UInt64(status.st_size) <= maximumBytes - min(bytes, maximumBytes) else {
                throw PluginManagerError.installRecoveryRequired
            }
            bytes += UInt64(status.st_size)
        default: throw PluginManagerError.installRecoveryRequired
        }
    }
}

/// Hashes every regular file, including same-sized resources omitted from the
/// Runtime's immutable source snapshot. All reads use no-follow descriptors,
/// logical byte quotas and start/end identity+timestamp checks.
nonisolated enum PluginInstallationFingerprint {
    static func read(_ root: URL, limits: PluginPackageLimits) throws -> String {
        let limits = try PluginInstallationLimits.bounded(limits)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginInstallerError.invalidPackage }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw PluginInstallerError.invalidPackage }
        var digest = SHA256()
        digest.update(data: Data("DynamicIsland.PluginInstallation.v1\0".utf8))
        var entries = 0, files = 0
        var bytes: UInt64 = 0
        try visit(descriptor: descriptor, url: root, path: "", rootDevice: status.st_dev,
                  limits: limits, entries: &entries, files: &files, bytes: &bytes, digest: &digest)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func visit(descriptor: Int32, url: URL, path: String, rootDevice: dev_t,
                              limits: PluginPackageLimits, entries: inout Int, files: inout Int,
                              bytes: inout UInt64, digest: inout SHA256) throws {
        var starting = stat()
        guard fstat(descriptor, &starting) == 0, starting.st_dev == rootDevice,
              starting.st_mode & S_IFMT == S_IFDIR else { throw PluginInstallerError.invalidPackage }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        for name in names {
            entries += 1
            let relative = path.isEmpty ? name : path + "/" + name
            guard entries <= limits.maxEntryCount, relative.utf8.count <= limits.maxRelativePathBytes,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw PluginInstallerError.quotaExceeded
            }
            var initial = stat()
            guard fstatat(descriptor, name, &initial, AT_SYMLINK_NOFOLLOW) == 0,
                  initial.st_dev == rootDevice else { throw PluginInstallerError.invalidPackage }
            let kind = initial.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && initial.st_nlink == 1) else {
                throw PluginInstallerError.invalidPackage
            }
            guard relative.split(separator: "/").count <= limits.maxDirectoryDepth else {
                throw PluginInstallerError.quotaExceeded
            }
            digest.update(data: Data("\(relative.utf8.count):\(relative)\0\(kind)\0".utf8))
            let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                               | (kind == S_IFDIR ? O_DIRECTORY : 0))
            guard child >= 0 else { throw PluginInstallerError.invalidPackage }
            defer { Darwin.close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, unchanged(initial, opened) else { throw PluginInstallerError.invalidPackage }
            if kind == S_IFDIR {
                try visit(descriptor: child, url: url.appendingPathComponent(name, isDirectory: true), path: relative,
                          rootDevice: rootDevice, limits: limits, entries: &entries, files: &files,
                          bytes: &bytes, digest: &digest)
            } else {
                files += 1
                guard files <= limits.maxRegularFileCount, opened.st_size >= 0,
                      UInt64(opened.st_size) <= limits.maxSingleFileBytes,
                      UInt64(opened.st_size) <= limits.maxTotalFileBytes - min(bytes, limits.maxTotalFileBytes) else {
                    throw PluginInstallerError.quotaExceeded
                }
                bytes += UInt64(opened.st_size)
                var content = SHA256()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                var count = 0
                while true {
                    let read = Darwin.read(child, &buffer, buffer.count)
                    if read < 0, errno == EINTR { continue }
                    guard read >= 0 else { throw PluginInstallerError.invalidPackage }
                    if read == 0 { break }
                    count += read
                    guard count <= opened.st_size else { throw PluginInstallerError.invalidPackage }
                    content.update(data: Data(buffer.prefix(read)))
                }
                guard count == opened.st_size else { throw PluginInstallerError.invalidPackage }
                digest.update(data: Data(content.finalize()))
            }
            var ending = stat()
            guard fstat(child, &ending) == 0, unchanged(opened, ending) else { throw PluginInstallerError.invalidPackage }
        }
        var ending = stat(), named = stat()
        guard fstat(descriptor, &ending) == 0, lstat(url.path, &named) == 0,
              unchanged(starting, ending), unchanged(ending, named) else { throw PluginInstallerError.invalidPackage }
    }

    private static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

nonisolated enum PluginInstallationLimits {
    static func bounded(_ limits: PluginPackageLimits) throws -> PluginPackageLimits {
        guard limits.maxEntryCount > 0, limits.maxRegularFileCount > 0,
              limits.maxSingleFileBytes > 0, limits.maxTotalFileBytes > 0,
              limits.maxDirectoryDepth >= 0, limits.maxRelativePathBytes > 0 else {
            throw PluginInstallerError.invalidArguments
        }
        let defaults = PluginPackageLimits()
        return .init(maxEntryCount: min(limits.maxEntryCount, defaults.maxEntryCount),
            maxRegularFileCount: min(limits.maxRegularFileCount, defaults.maxRegularFileCount),
            maxSingleFileBytes: min(limits.maxSingleFileBytes, defaults.maxSingleFileBytes),
            maxTotalFileBytes: min(limits.maxTotalFileBytes, defaults.maxTotalFileBytes),
            maxDirectoryDepth: min(limits.maxDirectoryDepth, defaults.maxDirectoryDepth),
            maxRelativePathBytes: min(limits.maxRelativePathBytes, defaults.maxRelativePathBytes))
    }
}

/// Fresh installation names must never replace an unregistered path. Exclusive
/// descriptor-relative renames also ensure rollback preserves Recovery bytes
/// when another directory unexpectedly occupies the old name.
nonisolated protocol PluginManagerInstallationMoving: Sendable {
    func move(source: URL, destination: URL) throws
}

nonisolated struct PluginManagerExclusiveInstallationMover: PluginManagerInstallationMoving {
    func move(source: URL, destination: URL) throws {
        let sourceDirectory = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDirectory >= 0 else { throw PluginManagerError.installFailed }
        defer { Darwin.close(sourceDirectory) }
        let destinationDirectory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destinationDirectory >= 0 else { throw PluginManagerError.installFailed }
        defer { Darwin.close(destinationDirectory) }
        guard renameatx_np(sourceDirectory, source.lastPathComponent,
                           destinationDirectory, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw PluginManagerError.installFailed
        }
    }
}

/// A small, fail-closed crash marker exists before the first package rename.
/// It contains no paths. Discovery commits disabled state before clearing a
/// valid marker; corrupt markers remain untouched and disable every candidate.
nonisolated struct PluginInstallationMarker: Equatable, Sendable {
    let token: UUID
    let pluginID: String
    var filename: String { "plugin-install-pending-\(token.uuidString).json" }
}

nonisolated struct PluginInstallationMarkerStore: Sendable {
    let directoryURL: URL
    static let maximumMarkers = 128
    static let maximumBytes = 1_024

    func create(pluginID: String) throws -> PluginInstallationMarker {
        guard PluginManifest.isValidPluginID(pluginID) else { throw PluginManagerError.installFailed }
        guard try readAll().count < Self.maximumMarkers else { throw PluginManagerError.installFailed }
        let marker = PluginInstallationMarker(token: UUID(), pluginID: pluginID)
        let data = try PluginBridgeJSON.object(["schemaVersion": .number(1),
            "token": .string(marker.token.uuidString), "pluginID": .string(pluginID)]).encodedData()
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        let file = openat(directory, marker.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw PluginManagerError.installFailed }
        defer { Darwin.close(file) }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw PluginManagerError.installFailed }
                    offset += written
                }
            }
            guard fsync(file) == 0, fsync(directory) == 0 else { throw PluginManagerError.installFailed }
        } catch {
            // No package move has begun. An incomplete marker is ours to clear.
            _ = unlinkat(directory, marker.filename, 0)
            throw PluginManagerError.installFailed
        }
        return marker
    }

    func readAll() throws -> [PluginInstallationMarker] {
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasPrefix("plugin-install-pending-") }.sorted()
        guard names.count <= Self.maximumMarkers else { throw PluginManagerError.stateReadFailed }
        return try names.map { try read(name: $0, directory: directory) }
    }

    func remove(_ marker: PluginInstallationMarker) throws {
        let directory = try openDirectory()
        defer { Darwin.close(directory) }
        guard try read(name: marker.filename, directory: directory) == marker,
              unlinkat(directory, marker.filename, 0) == 0, fsync(directory) == 0 else {
            throw PluginManagerError.installCleanupFailed
        }
    }

    private func openDirectory() throws -> Int32 {
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginManagerError.stateReadFailed }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(), status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            Darwin.close(descriptor)
            throw PluginManagerError.stateReadFailed
        }
        return descriptor
    }

    private func read(name: String, directory: Int32) throws -> PluginInstallationMarker {
        guard name.hasSuffix(".json"), !name.contains("/"),
              let token = UUID(uuidString: String(name.dropFirst("plugin-install-pending-".count).dropLast(5))),
              name == "plugin-install-pending-\(token.uuidString).json" else { throw PluginManagerError.stateReadFailed }
        var initial = stat()
        guard fstatat(directory, name, &initial, AT_SYMLINK_NOFOLLOW) == 0,
              privateFile(initial), initial.st_size >= 0, initial.st_size <= Self.maximumBytes else {
            throw PluginManagerError.stateReadFailed
        }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw PluginManagerError.stateReadFailed }
        defer { Darwin.close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0, privateFile(opened), same(initial, opened) else {
            throw PluginManagerError.stateReadFailed
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.maximumBytes)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PluginManagerError.stateReadFailed }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw PluginManagerError.stateReadFailed }
            data.append(contentsOf: buffer.prefix(count))
        }
        var ending = stat()
        guard fstat(file, &ending) == 0, privateFile(ending), same(opened, ending),
              data.count == ending.st_size, let text = String(data: data, encoding: .utf8),
              case .object(let object) = try PluginBridgeJSON.parse(text, maximumBytes: Self.maximumBytes,
                  maximumDepth: 2, maximumNodes: 8),
              Set(object.keys) == ["schemaVersion", "token", "pluginID"], object["schemaVersion"] == .number(1),
              object["token"] == .string(token.uuidString), case .string(let id) = object["pluginID"],
              PluginManifest.isValidPluginID(id) else { throw PluginManagerError.stateReadFailed }
        return .init(token: token, pluginID: id)
    }

    private func privateFile(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1
            && value.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
    private func same(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
}
