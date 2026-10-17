import Foundation

public nonisolated enum PluginEngine: String, Codable, CaseIterable, Sendable {
    case javaScriptCore = "javascriptcore"
    /// Explicit SuperIsland protocol V1 profile. Execution still uses the
    /// isolated JavaScriptCore Runtime; scripts never select a profile by
    /// exposing globals, and unsupported APIs do not fall back to native V1.
    case superIsland = "superisland"
}

/// Permissions are a closed V1 set. Unknown values fail the whole manifest.
public nonisolated enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case network
    case localStorage = "storage.local"
    case openLinks = "links.open"
    case publishNotifications = "notifications.publish"
    case readClipboard = "clipboard.read"
    case writeClipboard = "clipboard.write"
    case readCalendar = "calendar.read"
    case userSelectedFiles = "files.userSelected"
}

/// Host APIs a plugin expects to use. These declarations support compatibility
/// checks; permissions remain a separate enforcement boundary.
public nonisolated enum PluginCapability: String, Codable, CaseIterable, Sendable {
    case publishActivity = "activity.publish"
    case updateActivity = "activity.update"
    case endActivity = "activity.end"
    case islandNodeUI = "ui.islandNode"
    case handleActions = "actions.handle"
    case localStorage = "storage.local"
    case scheduler
    case countdown
    case openLinks = "links.open"
}

public nonisolated enum PluginManifestError: Error, Equatable, LocalizedError, Sendable {
    case jsonTooLarge(maximumBytes: Int)
    case malformedJSON
    case missingField(String)
    case unknownField(String)
    case duplicateField(String)
    case invalidType(field: String, expected: String)
    case unsupportedSchemaVersion(Int)
    case invalidPluginID(String)
    case invalidName
    case invalidDeveloper
    case invalidSemanticVersion(field: String, value: String)
    case unsupportedEngine(String)
    case invalidEntry(String)
    case unknownPermission(value: String, index: Int)
    case duplicatePermission(value: String, index: Int)
    case unknownCapability(value: String, index: Int)
    case duplicateCapability(value: String, index: Int)

    public var code: String {
        switch self {
        case .jsonTooLarge: "jsonTooLarge"
        case .malformedJSON: "malformedJSON"
        case .missingField: "missingField"
        case .unknownField: "unknownField"
        case .duplicateField: "duplicateField"
        case .invalidType: "invalidType"
        case .unsupportedSchemaVersion: "unsupportedSchemaVersion"
        case .invalidPluginID: "invalidPluginID"
        case .invalidName: "invalidName"
        case .invalidDeveloper: "invalidDeveloper"
        case .invalidSemanticVersion: "invalidSemanticVersion"
        case .unsupportedEngine: "unsupportedEngine"
        case .invalidEntry: "invalidEntry"
        case .unknownPermission: "unknownPermission"
        case .duplicatePermission: "duplicatePermission"
        case .unknownCapability: "unknownCapability"
        case .duplicateCapability: "duplicateCapability"
        }
    }

    public var path: String {
        switch self {
        case .jsonTooLarge, .malformedJSON: "$"
        case .missingField(let field), .unknownField(let field), .duplicateField(let field): "$.\(field)"
        case .invalidType(let field, _): "$.\(field)"
        case .unsupportedSchemaVersion: "$.schemaVersion"
        case .invalidPluginID: "$.id"
        case .invalidName: "$.name"
        case .invalidDeveloper: "$.developer"
        case .invalidSemanticVersion(let field, _): "$.\(field)"
        case .unsupportedEngine: "$.engine"
        case .invalidEntry: "$.entry"
        case .unknownPermission(_, let index), .duplicatePermission(_, let index):
            "$.permissions[\(index)]"
        case .unknownCapability(_, let index), .duplicateCapability(_, let index):
            "$.capabilities[\(index)]"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .jsonTooLarge(let maximumBytes):
            "Plugin manifest exceeds the \(maximumBytes)-byte limit."
        case .malformedJSON:
            "Plugin manifest must be a valid JSON object."
        case .missingField(let field):
            "Required manifest field \(field.debugDescription) is missing."
        case .unknownField(let field):
            "Manifest field \(field.debugDescription) is not defined by schema version 1."
        case .duplicateField(let field):
            "Manifest field \(field.debugDescription) appears more than once."
        case .invalidType(let field, let expected):
            "Manifest field \(field.debugDescription) must be \(expected)."
        case .unsupportedSchemaVersion(let version):
            "Manifest schema version \(version) is unsupported; expected version 1."
        case .invalidPluginID(let value):
            "Plugin ID \(value.debugDescription) must be a lowercase reverse-DNS identifier."
        case .invalidName:
            "Plugin name must be 1 to 80 printable characters without surrounding whitespace."
        case .invalidDeveloper:
            "Plugin developer must be 1 to 80 printable characters without surrounding whitespace."
        case .invalidSemanticVersion(let field, let value):
            "Manifest field \(field.debugDescription) has invalid semantic version \(value.debugDescription)."
        case .unsupportedEngine(let value):
            "Plugin engine \(value.debugDescription) is unsupported."
        case .invalidEntry(let value):
            "Plugin entry \(value.debugDescription) must be a normalized relative .js path."
        case .unknownPermission(let value, _):
            "Plugin permission \(value.debugDescription) is unknown."
        case .duplicatePermission(let value, _):
            "Plugin permission \(value.debugDescription) is declared more than once."
        case .unknownCapability(let value, _):
            "Plugin capability \(value.debugDescription) is unknown."
        case .duplicateCapability(let value, _):
            "Plugin capability \(value.debugDescription) is declared more than once."
        }
    }
}

/// Stable V1 identity and compatibility contract for an installed plugin.
/// Package contents are validated separately by `PluginValidator` in T19.
public nonisolated struct PluginManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public nonisolated enum Limits {
        public static let maxJSONBytes = 65_536
        public static let maxPluginIDBytes = 255
        public static let maxPluginIDSegmentBytes = 63
        public static let maxNameCharacters = 80
        public static let maxEntryBytes = 240
    }

    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: SemanticVersion
    public let engine: PluginEngine
    public let entry: String
    public let minimumHostVersion: SemanticVersion
    public let permissions: [PluginPermission]
    public let capabilities: [PluginCapability]
    /// Self-reported display metadata; this is not publisher verification.
    public let developer: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String,
        name: String,
        version: SemanticVersion,
        engine: PluginEngine,
        entry: String,
        minimumHostVersion: SemanticVersion,
        permissions: [PluginPermission],
        capabilities: [PluginCapability],
        developer: String? = nil
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.engine = engine
        self.entry = entry
        self.minimumHostVersion = minimumHostVersion
        self.permissions = permissions
        self.capabilities = capabilities
        self.developer = developer
        try validate()
    }

    /// Required entry point for untrusted manifest bytes. Byte-size and
    /// duplicate-key checks cannot be recovered from a generic Decoder after
    /// it has already consumed the input.
    public static func decodeJSON(_ data: Data) throws -> PluginManifest {
        guard data.count <= Limits.maxJSONBytes else {
            throw PluginManifestError.jsonTooLarge(maximumBytes: Limits.maxJSONBytes)
        }
        guard isUnmarkedUTF8(data) else { throw PluginManifestError.malformedJSON }
        switch scanTopLevelFields(in: data) {
        case .unique: break
        case .duplicate(let field): throw PluginManifestError.duplicateField(field)
        case .invalid: throw PluginManifestError.malformedJSON
        }
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as PluginManifestError {
            throw error
        } catch {
            throw PluginManifestError.malformedJSON
        }
    }

    public func encodeJSON(prettyPrinted: Bool = false) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Limits.maxJSONBytes else {
            throw PluginManifestError.jsonTooLarge(maximumBytes: Limits.maxJSONBytes)
        }
        return data
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PluginManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard Self.isValidPluginID(id) else { throw PluginManifestError.invalidPluginID(id) }
        guard Self.isValidName(name) else { throw PluginManifestError.invalidName }
        if let developer, !Self.isValidName(developer) { throw PluginManifestError.invalidDeveloper }
        guard Self.isValidEntry(entry) else { throw PluginManifestError.invalidEntry(entry) }
        try Self.rejectDuplicatePermissions(permissions)
        try Self.rejectDuplicateCapabilities(capabilities)
    }

    public static func isValidPluginID(_ value: String) -> Bool {
        guard value.utf8.count >= 5, value.utf8.count <= Limits.maxPluginIDBytes else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { segment in
            guard !segment.isEmpty,
                  segment.utf8.count <= Limits.maxPluginIDSegmentBytes,
                  let first = segment.utf8.first,
                  let last = segment.utf8.last,
                  Self.isLowercaseASCIILetter(first),
                  Self.isLowercaseASCIIAlphanumeric(last) else { return false }
            return segment.utf8.allSatisfy {
                Self.isLowercaseASCIIAlphanumeric($0) || $0 == 45
            }
        }
    }

    public static func isValidEntry(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= Limits.maxEntryBytes,
              value.hasSuffix(".js"),
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0") else { return false }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard let filename = segments.last, filename.utf8.count > 3 else { return false }
        return segments.allSatisfy { segment in
            guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
            return segment.utf8.allSatisfy { byte in
                Self.isASCIIAlphanumeric(byte) || byte == 45 || byte == 46 || byte == 95
            }
        }
    }

    private static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.unicodeScalars.count <= Limits.maxNameCharacters,
              let first = value.unicodeScalars.first,
              let last = value.unicodeScalars.last,
              !isNameBoundaryWhitespace(first),
              !isNameBoundaryWhitespace(last) else { return false }
        return !value.unicodeScalars.contains(where: isForbiddenNameScalar)
    }

    private static func isNameBoundaryWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == 0x0020 || value == 0x00A0 || value == 0x1680
            || (0x2000...0x200A).contains(value) || value == 0x202F
            || value == 0x205F || value == 0x3000
    }

    private static func isForbiddenNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0000...0x001F).contains(value) || (0x007F...0x009F).contains(value)
            || value == 0x00AD || value == 0x061C || value == 0x180E
            || (0x200B...0x200F).contains(value) || (0x2028...0x202E).contains(value)
            || (0x2060...0x206F).contains(value) || value == 0xFEFF
            || (0xFFF9...0xFFFB).contains(value)
    }

    private static func rejectDuplicatePermissions(_ values: [PluginPermission]) throws {
        var seen = Set<String>()
        for (index, value) in values.enumerated() where !seen.insert(value.rawValue).inserted {
            throw PluginManifestError.duplicatePermission(value: value.rawValue, index: index)
        }
    }

    private static func rejectDuplicateCapabilities(_ values: [PluginCapability]) throws {
        var seen = Set<String>()
        for (index, value) in values.enumerated() where !seen.insert(value.rawValue).inserted {
            throw PluginManifestError.duplicateCapability(value: value.rawValue, index: index)
        }
    }

    private static func isLowercaseASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private static func isLowercaseASCIILetter(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isLowercaseASCIIAlphanumeric(byte) || (65...90).contains(byte)
    }

    private static func isUnmarkedUTF8(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        guard bytes != [0xEF, 0xBB, 0xBF], !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    private static func scanTopLevelFields(in data: Data) -> TopLevelJSONKeyScanner.Result {
        var scanner = TopLevelJSONKeyScanner(bytes: Array(data))
        return scanner.scan()
    }

    /// Scans only the top-level object member names before JSONDecoder loses
    /// duplicate-key information. JSONDecoder remains responsible for full
    /// JSON grammar and value validation.
    private struct TopLevelJSONKeyScanner {
        enum Result {
            case unique
            case duplicate(String)
            case invalid
        }

        let bytes: [UInt8]
        var index = 0

        mutating func scan() -> Result {
            skipWhitespace()
            guard consume(123) else { return .invalid } // {
            var seen = Set<String>()
            var firstDuplicate: String?

            while index < bytes.count {
                skipWhitespace()
                if consume(125) { return finish(duplicate: firstDuplicate) } // }
                guard let keyRange = scanString(),
                      let key = try? JSONDecoder().decode(
                          String.self,
                          from: Data(bytes[keyRange])
                      ) else { return .invalid }
                let isDuplicate = !seen.insert(key).inserted

                skipWhitespace()
                guard consume(58) else { return .invalid } // :
                guard scanValue() else { return .invalid }
                if isDuplicate, firstDuplicate == nil { firstDuplicate = key }

                skipWhitespace()
                if consume(44) { continue } // ,
                if consume(125) { return finish(duplicate: firstDuplicate) } // }
                return .invalid
            }
            return .invalid
        }

        private mutating func finish(duplicate: String?) -> Result {
            skipWhitespace()
            guard index == bytes.count else { return .invalid }
            if let duplicate { return .duplicate(duplicate) }
            return .unique
        }

        private mutating func scanValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            if bytes[index] == 34 { return scanString() != nil } // "
            if bytes[index] == 123 || bytes[index] == 91 { // { or [
                var closers: [UInt8] = [bytes[index] == 123 ? 125 : 93]
                index += 1
                while index < bytes.count {
                    if bytes[index] == 34 {
                        guard scanString() != nil else { return false }
                        continue
                    }
                    switch bytes[index] {
                    case 123: closers.append(125)
                    case 91: closers.append(93)
                    case 125, 93:
                        guard closers.last == bytes[index] else { return false }
                        closers.removeLast()
                        index += 1
                        if closers.isEmpty { return true }
                        continue
                    default: break
                    }
                    index += 1
                }
                return false
            }

            let start = index
            while index < bytes.count,
                  bytes[index] != 44, bytes[index] != 125,
                  !Self.isWhitespace(bytes[index]) {
                index += 1
            }
            return index > start
        }

        private mutating func scanString() -> Range<Int>? {
            guard consume(34) else { return nil } // "
            let start = index - 1
            while index < bytes.count {
                if bytes[index] == 92 { // backslash and escaped byte
                    index += 2
                    continue
                }
                if bytes[index] == 34 {
                    index += 1
                    return start..<index
                }
                index += 1
            }
            return nil
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    private enum CodingKeys: String, CaseIterable {
        case schemaVersion, id, name, version, engine, entry, minimumHostVersion
        case permissions, capabilities, developer
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<DynamicCodingKey>
        do {
            container = try decoder.container(keyedBy: DynamicCodingKey.self)
        } catch {
            throw PluginManifestError.malformedJSON
        }

        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        let received = Set(container.allKeys.map(\.stringValue))
        guard received.contains(CodingKeys.schemaVersion.rawValue) else {
            throw PluginManifestError.missingField(CodingKeys.schemaVersion.rawValue)
        }

        func key(_ field: CodingKeys) -> DynamicCodingKey {
            DynamicCodingKey(stringValue: field.rawValue)!
        }
        func decode<T: Decodable>(_ type: T.Type, _ field: CodingKeys, expected: String) throws -> T {
            do { return try container.decode(type, forKey: key(field)) }
            catch { throw PluginManifestError.invalidType(field: field.rawValue, expected: expected) }
        }

        let schemaVersion = try decode(Int.self, .schemaVersion, expected: "an integer")
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PluginManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        if let unknown = received.subtracting(expected).sorted().first {
            throw PluginManifestError.unknownField(unknown)
        }
        if let missing = expected.subtracting([CodingKeys.developer.rawValue]).subtracting(received).sorted().first {
            throw PluginManifestError.missingField(missing)
        }

        let id = try decode(String.self, .id, expected: "a string")
        guard Self.isValidPluginID(id) else { throw PluginManifestError.invalidPluginID(id) }
        let name = try decode(String.self, .name, expected: "a string")
        guard Self.isValidName(name) else { throw PluginManifestError.invalidName }
        let developer = received.contains(CodingKeys.developer.rawValue)
            ? try decode(String.self, .developer, expected: "a string") : nil
        if let developer, !Self.isValidName(developer) { throw PluginManifestError.invalidDeveloper }

        let versionRaw = try decode(String.self, .version, expected: "a semantic version string")
        let version: SemanticVersion
        do { version = try SemanticVersion(versionRaw) }
        catch { throw PluginManifestError.invalidSemanticVersion(field: CodingKeys.version.rawValue, value: versionRaw) }

        let engineRaw = try decode(String.self, .engine, expected: "a string")
        guard let engine = PluginEngine(rawValue: engineRaw) else {
            throw PluginManifestError.unsupportedEngine(engineRaw)
        }

        let entry = try decode(String.self, .entry, expected: "a string")
        guard Self.isValidEntry(entry) else { throw PluginManifestError.invalidEntry(entry) }

        let minimumHostVersionRaw = try decode(
            String.self, .minimumHostVersion, expected: "a semantic version string"
        )
        let minimumHostVersion: SemanticVersion
        do { minimumHostVersion = try SemanticVersion(minimumHostVersionRaw) }
        catch {
            throw PluginManifestError.invalidSemanticVersion(
                field: CodingKeys.minimumHostVersion.rawValue,
                value: minimumHostVersionRaw
            )
        }

        let permissionValues = try decode([String].self, .permissions, expected: "an array of strings")
        var permissions: [PluginPermission] = []
        var permissionSet = Set<String>()
        for (index, rawValue) in permissionValues.enumerated() {
            guard let permission = PluginPermission(rawValue: rawValue) else {
                throw PluginManifestError.unknownPermission(value: rawValue, index: index)
            }
            guard permissionSet.insert(rawValue).inserted else {
                throw PluginManifestError.duplicatePermission(value: rawValue, index: index)
            }
            permissions.append(permission)
        }

        let capabilityValues = try decode([String].self, .capabilities, expected: "an array of strings")
        var capabilities: [PluginCapability] = []
        var capabilitySet = Set<String>()
        for (index, rawValue) in capabilityValues.enumerated() {
            guard let capability = PluginCapability(rawValue: rawValue) else {
                throw PluginManifestError.unknownCapability(value: rawValue, index: index)
            }
            guard capabilitySet.insert(rawValue).inserted else {
                throw PluginManifestError.duplicateCapability(value: rawValue, index: index)
            }
            capabilities.append(capability)
        }

        try self.init(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            version: version,
            engine: engine,
            entry: entry,
            minimumHostVersion: minimumHostVersion,
            permissions: permissions,
            capabilities: capabilities,
            developer: developer
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ field: CodingKeys) -> DynamicCodingKey {
            DynamicCodingKey(stringValue: field.rawValue)!
        }
        try container.encode(schemaVersion, forKey: key(.schemaVersion))
        try container.encode(id, forKey: key(.id))
        try container.encode(name, forKey: key(.name))
        try container.encode(version.description, forKey: key(.version))
        try container.encode(engine.rawValue, forKey: key(.engine))
        try container.encode(entry, forKey: key(.entry))
        try container.encode(minimumHostVersion.description, forKey: key(.minimumHostVersion))
        try container.encode(permissions.map(\.rawValue), forKey: key(.permissions))
        try container.encode(capabilities.map(\.rawValue), forKey: key(.capabilities))
        try container.encodeIfPresent(developer, forKey: key(.developer))
    }
}
