import Darwin
import Foundation
import zlib

/// Fixed errors never include archive paths, entry names or filesystem errors.
public nonisolated enum PluginPackageArchiveError: Error, Equatable, Sendable {
    case invalidArguments, unreadableArchive, unsupportedArchive, invalidArchive
    case invalidEntry, quotaExceeded, extractionFailed
}

/// A controlled ZIP32 profile for `.dip` files. The caller owns the staging
/// parent and invokes this synchronous I/O from its Installer actor. A fresh
/// destination is created only after the complete metadata passes validation.
/// No executable, shell, archive permissions, ACLs or xattrs are used.
public nonisolated struct PluginPackageArchiveExtractor: Sendable {
    public static let maximumArchiveBytes = 40 * 1_024 * 1_024
    public init() {}

    public func extract(archiveURL: URL, destinationURL: URL,
                        limits: PluginPackageLimits = .init()) throws {
        try extract(archiveURL: archiveURL, destinationURL: destinationURL, limits: limits,
                    onCreate: { _, _, _ in })
    }

    /// Installer retains this identity before any output is written, allowing
    /// cleanup to be retried if a later filesystem failure prevents deletion.
    func extract(archiveURL: URL, destinationURL: URL, limits: PluginPackageLimits = .init(),
                 onCreate: @Sendable (URL, dev_t, ino_t) -> Void) throws {
        let bounds = try ArchiveBounds(limits)
        let bytes = try Self.readArchive(archiveURL)
        let entries = try ArchiveReader(bytes: bytes, bounds: bounds).entries()
        let destination = try ArchiveDestination(url: destinationURL)
        onCreate(destinationURL, destination.device, destination.inode)
        do {
            var actualTotal: UInt64 = 0
            for entry in entries {
                if entry.isDirectory { try destination.createDirectory(entry.components); continue }
                let file = try destination.createFile(entry.components)
                defer { Darwin.close(file) }
                var actualFile: UInt64 = 0
                var checksum = crc32(0, nil, 0)
                func consume(_ chunk: UnsafeRawBufferPointer) throws {
                    let (fileBytes, fileOverflow) = actualFile.addingReportingOverflow(UInt64(chunk.count))
                    let (totalBytes, totalOverflow) = actualTotal.addingReportingOverflow(UInt64(chunk.count))
                    guard !fileOverflow, !totalOverflow, fileBytes <= bounds.singleFile,
                          totalBytes <= bounds.totalFile else { throw PluginPackageArchiveError.quotaExceeded }
                    guard fileBytes <= UInt64(entry.expandedBytes) else { throw PluginPackageArchiveError.invalidArchive }
                    actualFile = fileBytes; actualTotal = totalBytes
                    if let base = chunk.baseAddress {
                        checksum = crc32(checksum, base.assumingMemoryBound(to: UInt8.self), uInt(chunk.count))
                        try Self.write(chunk, descriptor: file)
                    }
                }
                if entry.method == 0 {
                    try bytes.withUnsafeBytes { all in
                        var offset = entry.payload.lowerBound
                        while offset < entry.payload.upperBound {
                            let end = min(offset + 65_536, entry.payload.upperBound)
                            try consume(UnsafeRawBufferPointer(rebasing: all[offset..<end]))
                            offset = end
                        }
                    }
                } else {
                    try Self.inflate(bytes, range: entry.payload, consume: consume)
                }
                guard actualFile == UInt64(entry.expandedBytes), UInt32(truncatingIfNeeded: checksum) == entry.crc else {
                    throw PluginPackageArchiveError.invalidArchive
                }
                var status = stat()
                guard fsync(file) == 0, fstat(file, &status) == 0, Self.isPrivateFile(status),
                      status.st_size == actualFile else { throw PluginPackageArchiveError.extractionFailed }
            }
            try destination.validateIdentity()
        } catch {
            destination.removeCreatedTree()
            throw error
        }
    }

    private static func readArchive(_ url: URL) throws -> Data {
        guard url.isFileURL, url.host(percentEncoded: false).map({ $0.isEmpty }) ?? true else {
            throw PluginPackageArchiveError.invalidArguments
        }
        var initial = stat()
        guard lstat(url.path, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_size >= 0 else { throw PluginPackageArchiveError.unreadableArchive }
        guard initial.st_size <= maximumArchiveBytes else { throw PluginPackageArchiveError.quotaExceeded }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PluginPackageArchiveError.unreadableArchive }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameFile(initial, opened), opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size == initial.st_size else { throw PluginPackageArchiveError.unreadableArchive }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PluginPackageArchiveError.unreadableArchive }
            if count == 0 { break }
            guard data.count + count <= maximumArchiveBytes else { throw PluginPackageArchiveError.quotaExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        var ending = stat()
        guard fstat(descriptor, &ending) == 0, sameFile(opened, ending), ending.st_size == opened.st_size,
              ending.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              ending.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              ending.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
              ending.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec, data.count == opened.st_size else {
            throw PluginPackageArchiveError.unreadableArchive
        }
        return data
    }

    private static func inflate(_ data: Data, range: Range<Int>,
                                consume: (UnsafeRawBufferPointer) throws -> Void) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PluginPackageArchiveError.extractionFailed
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw PluginPackageArchiveError.invalidArchive }
            var inputOffset = range.lowerBound
            while true {
                if stream.avail_in == 0, inputOffset < range.upperBound {
                    let count = min(65_536, range.upperBound - inputOffset)
                    stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self).advanced(by: inputOffset))
                    stream.avail_in = uInt(count)
                    inputOffset += count
                }
                let beforeInput = stream.total_in
                let beforeOutput = stream.total_out
                let status = try output.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    stream.avail_out = 65_536
                    let result = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = 65_536 - Int(stream.avail_out)
                    if produced > 0 { try consume(UnsafeRawBufferPointer(rebasing: buffer[0..<produced])) }
                    return result
                }
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, inputOffset == range.upperBound,
                          stream.total_in == range.count else { throw PluginPackageArchiveError.invalidArchive }
                    return
                }
                guard status == Z_OK, stream.total_in != beforeInput || stream.total_out != beforeOutput else {
                    throw PluginPackageArchiveError.invalidArchive
                }
                if stream.avail_in == 0, inputOffset == range.upperBound,
                   stream.total_out == beforeOutput { throw PluginPackageArchiveError.invalidArchive }
            }
        }
    }

    private static func write(_ bytes: UnsafeRawBufferPointer, descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PluginPackageArchiveError.extractionFailed }
            offset += count
        }
    }

    fileprivate static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
    fileprivate static func isPrivateFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid()
            && status.st_nlink == 1 && status.st_mode & 0o777 == 0o600
    }
}

private nonisolated struct ArchiveBounds {
    let entries: Int, files: Int, depth: Int, path: Int
    let singleFile: UInt64, totalFile: UInt64
    init(_ limits: PluginPackageLimits) throws {
        guard limits.maxEntryCount >= 0, limits.maxRegularFileCount >= 0,
              limits.maxDirectoryDepth >= 0, limits.maxRelativePathBytes >= 0 else {
            throw PluginPackageArchiveError.invalidArguments
        }
        // Injected Host policies may reduce the V1 ceilings, never increase them.
        let defaults = PluginPackageLimits()
        entries = min(limits.maxEntryCount, defaults.maxEntryCount)
        files = min(limits.maxRegularFileCount, defaults.maxRegularFileCount)
        depth = min(limits.maxDirectoryDepth, defaults.maxDirectoryDepth)
        path = min(limits.maxRelativePathBytes, defaults.maxRelativePathBytes)
        singleFile = min(limits.maxSingleFileBytes, defaults.maxSingleFileBytes)
        totalFile = min(limits.maxTotalFileBytes, defaults.maxTotalFileBytes)
    }
}

private nonisolated struct ArchiveEntry {
    let components: [String]
    let isDirectory: Bool
    let method: UInt16
    let expandedBytes: UInt32
    let crc: UInt32
    let payload: Range<Int>
    let recordRange: Range<Int>
}

private nonisolated struct ArchiveReader {
    let bytes: Data
    let bounds: ArchiveBounds

    func entries() throws -> [ArchiveEntry] {
        guard bytes.count >= 22 else { throw PluginPackageArchiveError.invalidArchive }
        var footer: Int?
        let lower = max(0, bytes.count - 22 - 65_535)
        for offset in stride(from: bytes.count - 22, through: lower, by: -1) {
            if try u32(offset) == 0x06054b50,
               offset + 22 + Int(try u16(offset + 20)) == bytes.count { footer = offset; break }
        }
        guard let footer else { throw PluginPackageArchiveError.invalidArchive }
        let disk = try u16(footer + 4), centralDisk = try u16(footer + 6)
        let diskCount = try u16(footer + 8), count = try u16(footer + 10)
        let centralSize = try u32(footer + 12), centralOffset = try u32(footer + 16)
        guard disk == 0, centralDisk == 0, diskCount == count,
              count != UInt16.max, centralSize != UInt32.max, centralOffset != UInt32.max else {
            throw PluginPackageArchiveError.unsupportedArchive
        }
        guard count > 0 else { throw PluginPackageArchiveError.invalidArchive }
        guard Int(count) <= bounds.entries else { throw PluginPackageArchiveError.quotaExceeded }
        let centralStart = Int(centralOffset)
        guard try end(centralStart, Int(centralSize), upper: footer) == footer else {
            throw PluginPackageArchiveError.invalidArchive
        }
        var cursor = centralStart
        var entries: [ArchiveEntry] = []
        var paths: [String: ArchivePath] = [:]
        var fileCount = 0
        var expandedTotal: UInt64 = 0
        for _ in 0..<count {
            _ = try end(cursor, 46, upper: footer)
            guard try u32(cursor) == 0x02014b50 else { throw PluginPackageArchiveError.invalidArchive }
            let creator = try u16(cursor + 4), version = try u16(cursor + 6)
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let time = try u16(cursor + 12), date = try u16(cursor + 14)
            let crc = try u32(cursor + 16), compressed = try u32(cursor + 20), expanded = try u32(cursor + 24)
            let nameCount = Int(try u16(cursor + 28)), extraCount = Int(try u16(cursor + 30))
            let commentCount = Int(try u16(cursor + 32)), startDisk = try u16(cursor + 34)
            let internalAttributes = try u16(cursor + 36), externalAttributes = try u32(cursor + 38)
            let localOffset = try u32(cursor + 42)
            guard version >= 10, version <= 20, method == 0 || method == 8,
                  method != 8 || version == 20,
                  flags & ~UInt16(method == 8 ? 0x0806 : 0x0800) == 0,
                  startDisk == 0, internalAttributes & ~UInt16(1) == 0,
                  compressed != UInt32.max, expanded != UInt32.max, localOffset != UInt32.max else {
                throw PluginPackageArchiveError.unsupportedArchive
            }
            let nameEnd = try end(cursor + 46, nameCount, upper: footer)
            let extraEnd = try end(nameEnd, extraCount, upper: footer)
            let recordEnd = try end(extraEnd, commentCount, upper: footer)
            let nameBytes = bytes.subdata(in: (cursor + 46)..<nameEnd)
            guard let name = String(data: nameBytes, encoding: .utf8),
                  flags & 0x0800 != 0 || nameBytes.allSatisfy({ $0 < 128 }) else {
                throw PluginPackageArchiveError.invalidEntry
            }
            let directory = name.hasSuffix("/")
            let components = try components(name, directory: directory)
            try validateAttributes(creator: creator, external: externalAttributes, directory: directory)
            try validateExtra(nameEnd..<extraEnd, central: true)
            try register(components, directory: directory, paths: &paths)
            guard paths.count <= bounds.entries else { throw PluginPackageArchiveError.quotaExceeded }
            if directory {
                guard method == 0, compressed == 0, expanded == 0, crc == 0 else {
                    throw PluginPackageArchiveError.invalidArchive
                }
            } else {
                fileCount += 1
                expandedTotal += UInt64(expanded)
                guard fileCount <= bounds.files, UInt64(expanded) <= bounds.singleFile,
                      expandedTotal <= bounds.totalFile else { throw PluginPackageArchiveError.quotaExceeded }
                if method == 0, compressed != expanded { throw PluginPackageArchiveError.invalidArchive }
            }
            let local = Int(localOffset)
            _ = try end(local, 30, upper: centralStart)
            guard try u32(local) == 0x04034b50, try u16(local + 4) == version,
                  try u16(local + 6) == flags, try u16(local + 8) == method,
                  try u16(local + 10) == time, try u16(local + 12) == date,
                  try u32(local + 14) == crc, try u32(local + 18) == compressed,
                  try u32(local + 22) == expanded, Int(try u16(local + 26)) == nameCount else {
                throw PluginPackageArchiveError.invalidArchive
            }
            let localNameEnd = try end(local + 30, nameCount, upper: centralStart)
            let payloadStart = try end(localNameEnd, Int(try u16(local + 28)), upper: centralStart)
            guard bytes.subdata(in: (local + 30)..<localNameEnd) == nameBytes else {
                throw PluginPackageArchiveError.invalidArchive
            }
            try validateExtra(localNameEnd..<payloadStart, central: false)
            let payloadEnd = try end(payloadStart, Int(compressed), upper: centralStart)
            entries.append(.init(components: components, isDirectory: directory, method: method,
                                 expandedBytes: expanded, crc: crc, payload: payloadStart..<payloadEnd,
                                 recordRange: local..<payloadEnd))
            cursor = recordEnd
        }
        guard cursor == footer, paths[canonical("manifest.json")]?.isDirectory == false,
              paths[canonical("manifest.json")]?.original == Data("manifest.json".utf8) else {
            throw PluginPackageArchiveError.invalidArchive
        }
        var covered = 0
        for entry in entries.sorted(by: { $0.recordRange.lowerBound < $1.recordRange.lowerBound }) {
            guard entry.recordRange.lowerBound == covered else { throw PluginPackageArchiveError.invalidArchive }
            covered = entry.recordRange.upperBound
        }
        guard covered == centralStart else { throw PluginPackageArchiveError.invalidArchive }
        return entries
    }

    private func components(_ name: String, directory: Bool) throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginPackageArchiveError.invalidEntry
        }
        let trimmed = directory ? String(name.dropLast()) : name
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PluginPackageArchiveError.invalidEntry
        }
        guard components.count <= bounds.depth, trimmed.utf8.count <= bounds.path else {
            throw PluginPackageArchiveError.quotaExceeded
        }
        return components
    }

    private func validateAttributes(creator: UInt16, external: UInt32, directory: Bool) throws {
        let system = creator >> 8
        guard system == 0 || system == 3 || system == 19 else { throw PluginPackageArchiveError.unsupportedArchive }
        let dos = external & 0xffff, unix = external >> 16
        guard dos & ~UInt32(0x00b7) == 0 else { throw PluginPackageArchiveError.invalidEntry }
        if dos & 0x10 != 0, !directory { throw PluginPackageArchiveError.invalidEntry }
        if system == 0 {
            guard unix == 0 else { throw PluginPackageArchiveError.invalidEntry }
        } else {
            let kind = unix & UInt32(S_IFMT)
            guard kind == 0 || kind == UInt32(S_IFREG) || kind == UInt32(S_IFDIR),
                  unix & 0o7000 == 0 else { throw PluginPackageArchiveError.invalidEntry }
            guard kind != UInt32(S_IFDIR) || directory, kind != UInt32(S_IFREG) || !directory else {
                throw PluginPackageArchiveError.invalidEntry
            }
        }
    }

    private func validateExtra(_ range: Range<Int>, central: Bool) throws {
        var cursor = range.lowerBound
        var ids = Set<UInt16>()
        while cursor < range.upperBound {
            _ = try end(cursor, 4, upper: range.upperBound)
            let id = try u16(cursor), length = Int(try u16(cursor + 2))
            let stop = try end(cursor + 4, length, upper: range.upperBound)
            guard ids.insert(id).inserted else { throw PluginPackageArchiveError.invalidArchive }
            switch id {
            case 0x5455:
                guard length >= 1 else { throw PluginPackageArchiveError.invalidArchive }
                let flags = bytes[cursor + 4]
                guard flags & ~UInt8(7) == 0 else { throw PluginPackageArchiveError.invalidArchive }
                let timestamps = central ? (flags & 1 == 0 ? 0 : 1) : flags.nonzeroBitCount
                guard length == 1 + 4 * timestamps else { throw PluginPackageArchiveError.invalidArchive }
            case 0x7875:
                guard length >= 3, bytes[cursor + 4] == 1 else { throw PluginPackageArchiveError.invalidArchive }
                let uidWidth = Int(bytes[cursor + 5])
                guard (1...8).contains(uidWidth), 2 + uidWidth < length else { throw PluginPackageArchiveError.invalidArchive }
                let gidWidth = Int(bytes[cursor + 6 + uidWidth])
                guard (1...8).contains(gidWidth), length == 3 + uidWidth + gidWidth else {
                    throw PluginPackageArchiveError.invalidArchive
                }
            default: throw PluginPackageArchiveError.unsupportedArchive
            }
            cursor = stop
        }
    }

    private func register(_ components: [String], directory: Bool, paths: inout [String: ArchivePath]) throws {
        for length in 1...components.count {
            let name = components.prefix(length).joined(separator: "/")
            let key = canonical(name), final = length == components.count
            let isDirectory = !final || directory
            let raw = Data(name.utf8)
            if let previous = paths[key] {
                guard previous.original == raw, previous.isDirectory, isDirectory,
                      !final || !previous.isExplicit else { throw PluginPackageArchiveError.invalidEntry }
                if final { paths[key] = .init(original: raw, isDirectory: true, isExplicit: true) }
            } else {
                paths[key] = .init(original: raw, isDirectory: isDirectory, isExplicit: final)
            }
        }
    }

    private func canonical(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private func end(_ offset: Int, _ length: Int, upper: Int) throws -> Int {
        guard offset >= 0, length >= 0, upper >= offset, length <= upper - offset, upper <= bytes.count else {
            throw PluginPackageArchiveError.invalidArchive
        }
        return offset + length
    }
    private func u16(_ offset: Int) throws -> UInt16 {
        _ = try end(offset, 2, upper: bytes.count)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private func u32(_ offset: Int) throws -> UInt32 {
        _ = try end(offset, 4, upper: bytes.count)
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

private nonisolated struct ArchivePath {
    let original: Data
    let isDirectory: Bool
    let isExplicit: Bool
}

private nonisolated final class ArchiveDestination {
    private let parent: Int32
    private let root: Int32
    private let name: String
    private let identity: stat
    var device: dev_t { identity.st_dev }
    var inode: ino_t { identity.st_ino }

    init(url: URL) throws {
        guard url.isFileURL, url.host(percentEncoded: false).map({ $0.isEmpty }) ?? true,
              !["", ".", "..", "/"].contains(url.lastPathComponent) else { throw PluginPackageArchiveError.invalidArguments }
        let parentURL = url.deletingLastPathComponent()
        var initialParent = stat()
        guard lstat(parentURL.path, &initialParent) == 0, Self.isManagedDirectory(initialParent) else {
            throw PluginPackageArchiveError.extractionFailed
        }
        let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PluginPackageArchiveError.extractionFailed }
        var openedParent = stat()
        guard fstat(parent, &openedParent) == 0, Self.isManagedDirectory(openedParent),
              PluginPackageArchiveExtractor.sameFile(initialParent, openedParent) else {
            Darwin.close(parent); throw PluginPackageArchiveError.extractionFailed
        }
        let name = url.lastPathComponent
        guard mkdirat(parent, name, S_IRWXU) == 0 else {
            let failure = errno
            Darwin.close(parent)
            throw failure == EEXIST ? PluginPackageArchiveError.invalidArguments : PluginPackageArchiveError.extractionFailed
        }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            unlinkat(parent, name, AT_REMOVEDIR); Darwin.close(parent)
            throw PluginPackageArchiveError.extractionFailed
        }
        var identity = stat()
        guard fstat(root, &identity) == 0, Self.isPrivateDirectory(identity) else {
            Darwin.close(root); unlinkat(parent, name, AT_REMOVEDIR); Darwin.close(parent)
            throw PluginPackageArchiveError.extractionFailed
        }
        self.parent = parent; self.root = root; self.name = name; self.identity = identity
    }

    deinit { Darwin.close(root); Darwin.close(parent) }

    func createDirectory(_ components: [String]) throws {
        let directory = try directory(components)
        Darwin.close(directory)
    }

    func createFile(_ components: [String]) throws -> Int32 {
        let directory = try directory(Array(components.dropLast()))
        defer { Darwin.close(directory) }
        let file = openat(directory, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard file >= 0 else { throw PluginPackageArchiveError.extractionFailed }
        var status = stat()
        guard fchmod(file, S_IRUSR | S_IWUSR) == 0, fstat(file, &status) == 0,
              PluginPackageArchiveExtractor.isPrivateFile(status), status.st_dev == identity.st_dev else {
            Darwin.close(file); throw PluginPackageArchiveError.extractionFailed
        }
        return file
    }

    func validateIdentity() throws {
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, Self.isPrivateDirectory(current),
              PluginPackageArchiveExtractor.sameFile(identity, current) else { throw PluginPackageArchiveError.extractionFailed }
    }

    func removeCreatedTree() {
        guard (try? validateIdentity()) != nil else { return }
        Self.removeContents(root)
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    private func directory(_ components: [String]) throws -> Int32 {
        var current = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw PluginPackageArchiveError.extractionFailed }
        do {
            for component in components {
                var initial = stat()
                if fstatat(current, component, &initial, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT, mkdirat(current, component, S_IRWXU) == 0,
                          fstatat(current, component, &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw PluginPackageArchiveError.extractionFailed
                    }
                }
                guard Self.isPrivateDirectory(initial), initial.st_dev == identity.st_dev else {
                    throw PluginPackageArchiveError.extractionFailed
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw PluginPackageArchiveError.extractionFailed }
                var opened = stat()
                guard fstat(next, &opened) == 0, Self.isPrivateDirectory(opened),
                      PluginPackageArchiveExtractor.sameFile(initial, opened) else {
                    Darwin.close(next); throw PluginPackageArchiveError.extractionFailed
                }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    private static func isManagedDirectory(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o022 == 0
    }
    private static func isPrivateDirectory(_ value: stat) -> Bool {
        isManagedDirectory(value) && value.st_mode & 0o777 == 0o700
    }
    private static func removeContents(_ descriptor: Int32) {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if status.st_mode & S_IFMT == S_IFDIR {
                let nested = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if nested >= 0 { removeContents(nested); Darwin.close(nested); unlinkat(descriptor, name, AT_REMOVEDIR) }
            } else { unlinkat(descriptor, name, 0) }
        }
    }
}
