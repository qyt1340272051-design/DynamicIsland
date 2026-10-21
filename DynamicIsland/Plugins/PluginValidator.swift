import Darwin
import Foundation

/// Resource ceilings shared by expanded-package validation and the future
/// streaming `.dip` installer. File sizes are logical bytes, not allocated
/// blocks, so sparse files cannot bypass the limits.
public nonisolated struct PluginPackageLimits: Equatable, Sendable {
    public let maxEntryCount: Int
    public let maxRegularFileCount: Int
    public let maxSingleFileBytes: UInt64
    public let maxTotalFileBytes: UInt64
    public let maxDirectoryDepth: Int
    public let maxRelativePathBytes: Int

    public init(
        maxEntryCount: Int = 512,
        maxRegularFileCount: Int = 256,
        maxSingleFileBytes: UInt64 = 8 * 1_024 * 1_024,
        maxTotalFileBytes: UInt64 = 32 * 1_024 * 1_024,
        maxDirectoryDepth: Int = 16,
        maxRelativePathBytes: Int = 1_024
    ) {
        self.maxEntryCount = maxEntryCount
        self.maxRegularFileCount = maxRegularFileCount
        self.maxSingleFileBytes = maxSingleFileBytes
        self.maxTotalFileBytes = maxTotalFileBytes
        self.maxDirectoryDepth = maxDirectoryDepth
        self.maxRelativePathBytes = maxRelativePathBytes
    }
}

/// Host-owned state needed to make validation deterministic and testable.
/// `occupiedPluginIDs` is a snapshot; PluginManager must reserve the ID again
/// atomically when it commits an install or load operation.
public nonisolated struct PluginValidationContext: Sendable {
    public let hostVersion: SemanticVersion
    public let occupiedPluginIDs: Set<String>
    public let limits: PluginPackageLimits
    public let allowedContainerURL: URL

    public init(
        hostVersion: SemanticVersion,
        occupiedPluginIDs: Set<String>,
        limits: PluginPackageLimits = PluginPackageLimits(),
        allowedContainerURL: URL
    ) {
        self.hostVersion = hostVersion
        self.occupiedPluginIDs = occupiedPluginIDs
        self.limits = limits
        self.allowedContainerURL = allowedContainerURL
    }
}

/// Immutable output of one validation pass. Runtime code must execute
/// `entrySource`; reopening `entryRelativePath` would reintroduce a path-swap
/// race after validation.
public nonisolated struct ValidatedPluginPackage: Equatable, Sendable {
    public let manifest: PluginManifest
    public let canonicalRootURL: URL
    public let entryRelativePath: String
    public let entrySource: Data
    public let regularFileCount: Int
    public let totalFileBytes: UInt64
}

public nonisolated enum PluginValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidPackageURL
    case invalidAllowedContainer
    case packageOutsideAllowedContainer
    case packageNotFound
    case packageNotDirectory
    case packageRootIsSymlink
    case packageUnreadable
    case manifestMissing
    case manifestNotRegularFile
    case invalidManifest(PluginManifestError)
    case hostVersionTooOld(current: String, required: String)
    case duplicatePluginID(String)
    case symbolicLinkNotAllowed(path: String)
    case aliasFileNotAllowed(path: String)
    case hardLinkNotAllowed(path: String)
    case unsupportedFileType(path: String)
    case crossDeviceEntry(path: String)
    case entryMissing(path: String)
    case entryNotRegularFile(path: String)
    case pathEscapesPackage(path: String)
    case tooManyEntries(maximum: Int)
    case tooManyFiles(maximum: Int)
    case pathTooLong(path: String, maximumBytes: Int)
    case directoryTooDeep(path: String, maximumDepth: Int)
    case fileTooLarge(path: String, actual: UInt64, maximum: UInt64)
    case packageTooLarge(actual: UInt64, maximum: UInt64)
    case changedDuringValidation(path: String)
    case readFailed(path: String)

    public var code: String {
        switch self {
        case .invalidPackageURL: "invalidPackageURL"
        case .invalidAllowedContainer: "invalidAllowedContainer"
        case .packageOutsideAllowedContainer: "packageOutsideAllowedContainer"
        case .packageNotFound: "packageNotFound"
        case .packageNotDirectory: "packageNotDirectory"
        case .packageRootIsSymlink: "packageRootIsSymlink"
        case .packageUnreadable: "packageUnreadable"
        case .manifestMissing: "manifestMissing"
        case .manifestNotRegularFile: "manifestNotRegularFile"
        case .invalidManifest: "invalidManifest"
        case .hostVersionTooOld: "hostVersionTooOld"
        case .duplicatePluginID: "duplicatePluginID"
        case .symbolicLinkNotAllowed: "symbolicLinkNotAllowed"
        case .aliasFileNotAllowed: "aliasFileNotAllowed"
        case .hardLinkNotAllowed: "hardLinkNotAllowed"
        case .unsupportedFileType: "unsupportedFileType"
        case .crossDeviceEntry: "crossDeviceEntry"
        case .entryMissing: "entryMissing"
        case .entryNotRegularFile: "entryNotRegularFile"
        case .pathEscapesPackage: "pathEscapesPackage"
        case .tooManyEntries: "tooManyEntries"
        case .tooManyFiles: "tooManyFiles"
        case .pathTooLong: "pathTooLong"
        case .directoryTooDeep: "directoryTooDeep"
        case .fileTooLarge: "fileTooLarge"
        case .packageTooLarge: "packageTooLarge"
        case .changedDuringValidation: "changedDuringValidation"
        case .readFailed: "readFailed"
        }
    }

    public var path: String? {
        switch self {
        case .invalidManifest(let error): error.path
        case .symbolicLinkNotAllowed(let path), .aliasFileNotAllowed(let path),
             .hardLinkNotAllowed(let path), .unsupportedFileType(let path),
             .crossDeviceEntry(let path), .entryMissing(let path),
             .entryNotRegularFile(let path), .pathEscapesPackage(let path),
             .pathTooLong(let path, _), .directoryTooDeep(let path, _),
             .fileTooLarge(let path, _, _), .changedDuringValidation(let path),
             .readFailed(let path):
            path
        case .manifestMissing, .manifestNotRegularFile:
            PluginValidator.manifestFilename
        case .hostVersionTooOld, .duplicatePluginID:
            PluginValidator.manifestFilename
        case .invalidPackageURL, .invalidAllowedContainer, .packageOutsideAllowedContainer,
             .packageNotFound, .packageNotDirectory, .packageRootIsSymlink,
             .packageUnreadable, .tooManyEntries, .tooManyFiles, .packageTooLarge:
            "."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPackageURL:
            "Plugin package must be a local file URL."
        case .invalidAllowedContainer:
            "The allowed plugin container is not a readable local directory."
        case .packageOutsideAllowedContainer:
            "Plugin package must be a strict descendant of the allowed container."
        case .packageNotFound:
            "Plugin package does not exist."
        case .packageNotDirectory:
            "Plugin package root must be a directory."
        case .packageRootIsSymlink:
            "Plugin package root must not be a symbolic link."
        case .packageUnreadable:
            "Plugin package root could not be opened safely."
        case .manifestMissing:
            "Plugin package is missing the exact root-level manifest.json file."
        case .manifestNotRegularFile:
            "Plugin manifest.json must be a regular file."
        case .invalidManifest(let error):
            error.localizedDescription
        case .hostVersionTooOld(let current, let required):
            "Host version \(current) does not satisfy required version \(required)."
        case .duplicatePluginID(let id):
            "Plugin ID \(id.debugDescription) is already installed or reserved."
        case .symbolicLinkNotAllowed(let path):
            "Symbolic links are not allowed in plugin packages: \(path)."
        case .aliasFileNotAllowed(let path):
            "Finder aliases are not allowed in plugin packages: \(path)."
        case .hardLinkNotAllowed(let path):
            "Hard-linked files are not allowed in plugin packages: \(path)."
        case .unsupportedFileType(let path):
            "Only directories and regular files are allowed in plugin packages: \(path)."
        case .crossDeviceEntry(let path):
            "Plugin package entries must stay on the package root file system: \(path)."
        case .entryMissing(let path):
            "Plugin entry file is missing: \(path)."
        case .entryNotRegularFile(let path):
            "Plugin entry must be a regular file: \(path)."
        case .pathEscapesPackage(let path):
            "Plugin package path escapes its root: \(path)."
        case .tooManyEntries(let maximum):
            "Plugin package contains more than \(maximum) entries."
        case .tooManyFiles(let maximum):
            "Plugin package contains more than \(maximum) regular files."
        case .pathTooLong(let path, let maximumBytes):
            "Plugin path exceeds the \(maximumBytes)-byte limit: \(path)."
        case .directoryTooDeep(let path, let maximumDepth):
            "Plugin path exceeds the maximum depth of \(maximumDepth): \(path)."
        case .fileTooLarge(let path, let actual, let maximum):
            "Plugin file \(path) is \(actual) bytes; maximum is \(maximum)."
        case .packageTooLarge(let actual, let maximum):
            "Plugin package is \(actual) bytes; maximum is \(maximum)."
        case .changedDuringValidation(let path):
            "Plugin package changed while it was being validated: \(path)."
        case .readFailed(let path):
            "Plugin package entry could not be read safely: \(path)."
        }
    }
}

/// Validates an already-expanded package directory without evaluating its
/// JavaScript. Archive extraction and its streaming limits belong to T34.
public nonisolated struct PluginValidator: Sendable {
    public static let manifestFilename = "manifest.json"

    public init() {}

    public func validateExpandedPackage(
        at packageURL: URL,
        context: PluginValidationContext
    ) throws -> ValidatedPluginPackage {
        guard isStrictLocalFileURL(packageURL),
              isStrictLocalFileURL(context.allowedContainerURL) else {
            throw PluginValidationError.invalidPackageURL
        }

        let rawContainer = context.allowedContainerURL.standardizedFileURL
        let rawRoot = packageURL.standardizedFileURL
        let containerInfo = try validatedContainer(at: rawContainer)
        let rootInfo = try validatedPackageRoot(at: rawRoot)

        guard let rawRelativeComponents = strictRelativeComponents(from: rawContainer, to: rawRoot) else {
            throw PluginValidationError.packageOutsideAllowedContainer
        }

        let canonicalContainer = try canonicalFileURL(
            rawContainer,
            failure: .invalidAllowedContainer
        )
        let canonicalRoot = try canonicalFileURL(rawRoot, failure: .packageNotFound)
        guard let canonicalRelativeComponents = strictRelativeComponents(
            from: canonicalContainer,
            to: canonicalRoot
        ), canonicalRelativeComponents == rawRelativeComponents else {
            throw PluginValidationError.packageOutsideAllowedContainer
        }

        let canonicalContainerInfo = try fileInfo(
            at: canonicalContainer,
            missingAs: .invalidAllowedContainer,
            displayPath: "."
        )
        guard canonicalContainerInfo.kind == .directory,
              canonicalContainerInfo.device == containerInfo.device,
              canonicalContainerInfo.inode == containerInfo.inode else {
            throw PluginValidationError.invalidAllowedContainer
        }
        let canonicalRootInfo = try fileInfo(
            at: canonicalRoot,
            missingAs: .packageNotFound,
            displayPath: "."
        )
        guard canonicalRootInfo.kind == .directory,
              canonicalRootInfo.device == rootInfo.device,
              canonicalRootInfo.inode == rootInfo.inode else {
            throw PluginValidationError.changedDuringValidation(path: ".")
        }
        guard canonicalRootInfo.device == canonicalContainerInfo.device else {
            throw PluginValidationError.crossDeviceEntry(path: ".")
        }

        let rootDescriptor = canonicalRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw PluginValidationError.packageUnreadable }
        defer { Darwin.close(rootDescriptor) }

        var openedRootStat = stat()
        guard fstat(rootDescriptor, &openedRootStat) == 0 else {
            throw PluginValidationError.packageUnreadable
        }
        let openedRootInfo = FileInfo(openedRootStat)
        guard openedRootInfo.kind == .directory,
              openedRootInfo.sameObjectAndContents(as: canonicalRootInfo) else {
            throw PluginValidationError.changedDuringValidation(path: ".")
        }

        let inventory = try inventoryPackage(
            at: canonicalRoot,
            rootDevice: openedRootInfo.device,
            limits: context.limits
        )

        guard let manifestItem = inventory.items[Self.manifestFilename] else {
            throw PluginValidationError.manifestMissing
        }
        guard manifestItem.info.kind == .regularFile else {
            throw PluginValidationError.manifestNotRegularFile
        }
        if manifestItem.info.size > UInt64(PluginManifest.Limits.maxJSONBytes) {
            throw PluginValidationError.invalidManifest(
                .jsonTooLarge(maximumBytes: PluginManifest.Limits.maxJSONBytes)
            )
        }

        let manifestData = try readRegularFile(
            Self.manifestFilename,
            from: rootDescriptor,
            expected: manifestItem.info,
            maximumBytes: UInt64(PluginManifest.Limits.maxJSONBytes)
        )
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.decodeJSON(manifestData)
        } catch let error as PluginManifestError {
            throw PluginValidationError.invalidManifest(error)
        }

        guard context.hostVersion.isAtLeast(manifest.minimumHostVersion) else {
            throw PluginValidationError.hostVersionTooOld(
                current: context.hostVersion.description,
                required: manifest.minimumHostVersion.description
            )
        }
        guard !context.occupiedPluginIDs.contains(manifest.id) else {
            throw PluginValidationError.duplicatePluginID(manifest.id)
        }

        guard let entryItem = inventory.items[manifest.entry] else {
            throw PluginValidationError.entryMissing(path: manifest.entry)
        }
        guard entryItem.info.kind == .regularFile else {
            throw PluginValidationError.entryNotRegularFile(path: manifest.entry)
        }
        let entrySource = try readRegularFile(
            manifest.entry,
            from: rootDescriptor,
            expected: entryItem.info,
            maximumBytes: context.limits.maxSingleFileBytes
        )

        let endingRootInfo = try descriptorInfo(rootDescriptor, path: ".")
        guard endingRootInfo.sameObjectAndContents(as: openedRootInfo) else {
            throw PluginValidationError.changedDuringValidation(path: ".")
        }

        return ValidatedPluginPackage(
            manifest: manifest,
            canonicalRootURL: canonicalRoot,
            entryRelativePath: manifest.entry,
            entrySource: entrySource,
            regularFileCount: inventory.regularFileCount,
            totalFileBytes: inventory.totalFileBytes
        )
    }

    private func validatedContainer(at url: URL) throws -> FileInfo {
        let info = try fileInfo(at: url, missingAs: .invalidAllowedContainer, displayPath: ".")
        guard info.kind == .directory else { throw PluginValidationError.invalidAllowedContainer }
        return info
    }

    private func validatedPackageRoot(at url: URL) throws -> FileInfo {
        let info = try fileInfo(at: url, missingAs: .packageNotFound, displayPath: ".")
        switch info.kind {
        case .symbolicLink:
            throw PluginValidationError.packageRootIsSymlink
        case .directory:
            return info
        default:
            throw PluginValidationError.packageNotDirectory
        }
    }

    private func inventoryPackage(
        at root: URL,
        rootDevice: UInt64,
        limits: PluginPackageLimits
    ) throws -> PackageInventory {
        var enumerationFailure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isAliasFileKey],
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else {
            throw PluginValidationError.packageUnreadable
        }

        var items: [String: InventoryItem] = [:]
        var entryCount = 0
        var regularFileCount = 0
        var totalFileBytes: UInt64 = 0

        while let itemURL = enumerator.nextObject() as? URL {
            guard let components = strictRelativeComponents(from: root, to: itemURL) else {
                throw PluginValidationError.pathEscapesPackage(path: itemURL.lastPathComponent)
            }
            let relativePath = components.joined(separator: "/")
            guard !relativePath.isEmpty else {
                throw PluginValidationError.pathEscapesPackage(path: ".")
            }

            entryCount += 1
            guard entryCount <= limits.maxEntryCount else {
                throw PluginValidationError.tooManyEntries(maximum: limits.maxEntryCount)
            }
            guard components.count <= limits.maxDirectoryDepth else {
                throw PluginValidationError.directoryTooDeep(
                    path: relativePath,
                    maximumDepth: limits.maxDirectoryDepth
                )
            }
            guard relativePath.utf8.count <= limits.maxRelativePathBytes else {
                throw PluginValidationError.pathTooLong(
                    path: relativePath,
                    maximumBytes: limits.maxRelativePathBytes
                )
            }

            let info = try fileInfo(
                at: itemURL,
                missingAs: .changedDuringValidation(path: relativePath),
                displayPath: relativePath
            )
            guard info.device == rootDevice else {
                enumerator.skipDescendants()
                throw PluginValidationError.crossDeviceEntry(path: relativePath)
            }

            switch info.kind {
            case .symbolicLink:
                enumerator.skipDescendants()
                throw PluginValidationError.symbolicLinkNotAllowed(path: relativePath)
            case .directory:
                break
            case .regularFile:
                let resourceValues: URLResourceValues
                do {
                    resourceValues = try itemURL.resourceValues(forKeys: [.isAliasFileKey])
                } catch {
                    throw PluginValidationError.readFailed(path: relativePath)
                }
                guard let isAliasFile = resourceValues.isAliasFile else {
                    throw PluginValidationError.readFailed(path: relativePath)
                }
                if isAliasFile {
                    throw PluginValidationError.aliasFileNotAllowed(path: relativePath)
                }
                guard info.linkCount == 1 else {
                    throw PluginValidationError.hardLinkNotAllowed(path: relativePath)
                }
                guard info.size <= limits.maxSingleFileBytes else {
                    throw PluginValidationError.fileTooLarge(
                        path: relativePath,
                        actual: info.size,
                        maximum: limits.maxSingleFileBytes
                    )
                }
                regularFileCount += 1
                guard regularFileCount <= limits.maxRegularFileCount else {
                    throw PluginValidationError.tooManyFiles(maximum: limits.maxRegularFileCount)
                }
                let (newTotal, overflow) = totalFileBytes.addingReportingOverflow(info.size)
                guard !overflow, newTotal <= limits.maxTotalFileBytes else {
                    throw PluginValidationError.packageTooLarge(
                        actual: overflow ? UInt64.max : newTotal,
                        maximum: limits.maxTotalFileBytes
                    )
                }
                totalFileBytes = newTotal
            case .other:
                enumerator.skipDescendants()
                throw PluginValidationError.unsupportedFileType(path: relativePath)
            }

            guard items.updateValue(InventoryItem(info: info), forKey: relativePath) == nil else {
                throw PluginValidationError.changedDuringValidation(path: relativePath)
            }
        }

        if enumerationFailure != nil { throw PluginValidationError.packageUnreadable }
        return PackageInventory(
            items: items,
            regularFileCount: regularFileCount,
            totalFileBytes: totalFileBytes
        )
    }

    private func readRegularFile(
        _ relativePath: String,
        from rootDescriptor: Int32,
        expected: FileInfo,
        maximumBytes: UInt64
    ) throws -> Data {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PluginValidationError.pathEscapesPackage(path: relativePath)
        }

        var currentDescriptor = rootDescriptor
        var ownsCurrentDescriptor = false
        defer {
            if ownsCurrentDescriptor { Darwin.close(currentDescriptor) }
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
            guard nextDescriptor >= 0 else {
                throw PluginValidationError.changedDuringValidation(path: relativePath)
            }
            if ownsCurrentDescriptor { Darwin.close(currentDescriptor) }
            currentDescriptor = nextDescriptor
            ownsCurrentDescriptor = true
        }

        guard let finalComponent = components.last else {
            throw PluginValidationError.pathEscapesPackage(path: relativePath)
        }
        let fileDescriptor = finalComponent.withCString {
            openat(currentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            throw PluginValidationError.changedDuringValidation(path: relativePath)
        }
        defer { Darwin.close(fileDescriptor) }

        let before = try descriptorInfo(fileDescriptor, path: relativePath)
        guard before.kind == .regularFile,
              before.linkCount == 1,
              before.sameObjectAndContents(as: expected) else {
            throw PluginValidationError.changedDuringValidation(path: relativePath)
        }
        guard before.size <= maximumBytes else {
            throw PluginValidationError.fileTooLarge(
                path: relativePath,
                actual: before.size,
                maximum: maximumBytes
            )
        }

        var result = Data()
        if before.size <= UInt64(Int.max) {
            result.reserveCapacity(Int(before.size))
        }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw PluginValidationError.readFailed(path: relativePath)
            }
            let count = Int(bytesRead)
            let (newCount, overflow) = UInt64(result.count).addingReportingOverflow(UInt64(count))
            guard !overflow, newCount <= maximumBytes else {
                throw PluginValidationError.fileTooLarge(
                    path: relativePath,
                    actual: overflow ? UInt64.max : newCount,
                    maximum: maximumBytes
                )
            }
            result.append(contentsOf: buffer.prefix(count))
        }

        let after = try descriptorInfo(fileDescriptor, path: relativePath)
        guard after.sameObjectAndContents(as: before), UInt64(result.count) == after.size else {
            throw PluginValidationError.changedDuringValidation(path: relativePath)
        }
        return result
    }

    private func descriptorInfo(_ descriptor: Int32, path: String) throws -> FileInfo {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw PluginValidationError.readFailed(path: path)
        }
        return FileInfo(value)
    }

    private func fileInfo(
        at url: URL,
        missingAs missingError: PluginValidationError,
        displayPath: String
    ) throws -> FileInfo {
        var value = stat()
        let result = url.path.withCString { lstat($0, &value) }
        if result != 0 {
            if errno == ENOENT || errno == ENOTDIR { throw missingError }
            throw PluginValidationError.readFailed(path: displayPath)
        }
        return FileInfo(value)
    }

    private func strictRelativeComponents(from base: URL, to child: URL) -> [String]? {
        // The caller passes either two standardized lexical URLs or two POSIX
        // realpaths. Re-standardizing an enumerated broken symlink can switch
        // `/private/var` back to `/var` on macOS and create a false escape.
        let baseComponents = base.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count > baseComponents.count,
              Array(childComponents.prefix(baseComponents.count)) == baseComponents else {
            return nil
        }
        let relative = Array(childComponents.dropFirst(baseComponents.count))
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return relative
    }

    private func isStrictLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              url.port == nil else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    private func canonicalFileURL(
        _ url: URL,
        failure: PluginValidationError
    ) throws -> URL {
        let resolved = url.path.withCString { realpath($0, nil) }
        guard let resolved else { throw failure }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

}

private extension PluginValidator {
    nonisolated struct PackageInventory: Sendable {
        let items: [String: InventoryItem]
        let regularFileCount: Int
        let totalFileBytes: UInt64
    }

    nonisolated struct InventoryItem: Sendable {
        let info: FileInfo
    }

    nonisolated enum FileKind: Sendable {
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    nonisolated struct FileInfo: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let kind: FileKind
        let linkCount: UInt64
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            switch value.st_mode & S_IFMT {
            case S_IFREG: kind = .regularFile
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }
            linkCount = UInt64(value.st_nlink)
            size = value.st_size < 0 ? UInt64.max : UInt64(value.st_size)
            modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            statusChangeSeconds = Int64(value.st_ctimespec.tv_sec)
            statusChangeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        func sameObjectAndContents(as other: FileInfo) -> Bool {
            device == other.device
                && inode == other.inode
                && kind == other.kind
                && linkCount == other.linkCount
                && size == other.size
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
                && statusChangeSeconds == other.statusChangeSeconds
                && statusChangeNanoseconds == other.statusChangeNanoseconds
        }
    }
}
