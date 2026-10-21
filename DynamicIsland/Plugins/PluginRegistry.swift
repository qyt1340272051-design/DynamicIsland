import Foundation

public nonisolated enum PluginRegistryError: String, Error, Equatable, Sendable {
    case invalidCatalog, unsupportedSchema, duplicatePlugin, invalidURL
    case tooLarge, transportFailed, httpStatus, redirectRejected, cancelled, busy
}

/// Discovery metadata is never permission approval or a publisher signature.
public nonisolated struct PluginRegistryEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: SemanticVersion
    public let download: URL
    public let source: URL
    public let minHostVersion: SemanticVersion
    /// Lowercase SHA-256 of the exact downloaded .dip bytes.
    public let hash: String

    fileprivate init(fields: [String: PluginBridgeJSON]) throws {
        guard Set(fields.keys) == ["id", "name", "version", "download", "source", "minHostVersion", "hash"] else {
            throw PluginRegistryError.invalidCatalog
        }
        func string(_ key: String) throws -> String {
            guard case .string(let value)? = fields[key] else { throw PluginRegistryError.invalidCatalog }
            return value
        }
        id = try string("id")
        name = try string("name")
        do {
            version = try SemanticVersion(string("version"))
            minHostVersion = try SemanticVersion(string("minHostVersion"))
            // Reuse the Host identity/name rules, including invisible scalars.
            _ = try PluginManifest(id: id, name: name, version: version, engine: .javaScriptCore,
                entry: "index.js", minimumHostVersion: minHostVersion, permissions: [], capabilities: [])
        } catch { throw PluginRegistryError.invalidCatalog }
        hash = try string("hash")
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PluginRegistryError.invalidCatalog
        }
        source = try PluginRegistryURLPolicy.source(string("source"))
        download = try PluginRegistryURLPolicy.download(string("download"), source: source)
    }
}

public nonisolated struct PluginRegistryCatalog: Equatable, Sendable {
    public static let maximumBytes = 262_144
    public static let maximumEntries = 100
    public let entries: [PluginRegistryEntry]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PluginRegistryError.tooLarge }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), !data.contains(0),
              let source = String(data: data, encoding: .utf8) else { throw PluginRegistryError.invalidCatalog }
        let parsed: PluginBridgeJSON
        do { parsed = try PluginBridgeJSON.parse(source, maximumBytes: maximumBytes, maximumDepth: 5, maximumNodes: 1_024) }
        catch { throw PluginRegistryError.invalidCatalog }
        guard case .object(let fields) = parsed, Set(fields.keys) == ["schemaVersion", "plugins"],
              case .number(let schema)? = fields["schemaVersion"] else { throw PluginRegistryError.invalidCatalog }
        guard schema == 1 else { throw PluginRegistryError.unsupportedSchema }
        guard case .array(let values)? = fields["plugins"] else { throw PluginRegistryError.invalidCatalog }
        guard values.count <= maximumEntries else { throw PluginRegistryError.tooLarge }
        var seen = Set<String>()
        let entries = try values.map { value in
            guard case .object(let fields) = value else { throw PluginRegistryError.invalidCatalog }
            let entry = try PluginRegistryEntry(fields: fields)
            guard seen.insert(entry.id).inserted else { throw PluginRegistryError.duplicatePlugin }
            return entry
        }
        return Self(entries: entries)
    }
}

/// V1 deliberately uses GitHub repository releases. Registry ownership still
/// determines what is listed; these URL checks do not certify a publisher.
nonisolated enum PluginRegistryURLPolicy {
    static func source(_ value: String) throws -> URL {
        let url = try canonical(value, host: "github.com")
        let parts = components(url)
        guard parts.count == 2, parts.allSatisfy(repositoryPart) else { throw PluginRegistryError.invalidURL }
        return url
    }

    static func download(_ value: String, source: URL) throws -> URL {
        let url = try canonical(value, host: "github.com")
        let parts = components(url), repository = components(source)
        guard parts.count == 6, Array(parts.prefix(2)) == repository,
              parts[2] == "releases", parts[3] == "download",
              portablePart(parts[4]), portablePart(parts[5]), parts[5].hasSuffix(".dip") else {
            throw PluginRegistryError.invalidURL
        }
        return url
    }

    static func catalog(_ url: URL) throws {
        _ = try canonical(url.absoluteString, host: "raw.githubusercontent.com")
        let parts = components(url)
        guard parts.count == 5, parts.prefix(2).allSatisfy(repositoryPart), portablePart(parts[2]),
              parts[3] == "Registry", parts[4] == "registry.json" else { throw PluginRegistryError.invalidURL }
    }

    static func redirect(_ url: URL) throws {
        // GitHub's release-asset CDN uses signed query parameters. No other
        // target, credentials, fragment or encoded path is admitted.
        _ = try canonical(url.absoluteString, host: "release-assets.githubusercontent.com", allowsQuery: true)
        guard !components(url).isEmpty, components(url).allSatisfy(portablePart) else {
            throw PluginRegistryError.invalidURL
        }
    }

    private static func canonical(_ value: String, host: String, allowsQuery: Bool = false) throws -> URL {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E && $0 != "\\" }),
              let components = URLComponents(string: value), let url = components.url,
              url.absoluteString == value, components.scheme == "https", components.host == host,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, allowsQuery || components.query == nil,
              !components.percentEncodedPath.contains("%"), !components.path.hasSuffix("/"),
              !components.path.contains("//") else { throw PluginRegistryError.invalidURL }
        return url
    }

    private static func components(_ url: URL) -> [String] { url.path.split(separator: "/").map(String.init) }
    private static func portablePart(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [45, 46, 95].contains($0) }
    }
    private static func repositoryPart(_ value: String) -> Bool { portablePart(value) && !value.hasPrefix(".") }
}
