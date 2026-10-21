import Foundation

/// A SemVer 2.0.0 value. Build metadata is preserved as value identity but is
/// ignored by `precedence(comparedTo:)`, as required by the specification.
public nonisolated struct SemanticVersion: Codable, Equatable, CustomStringConvertible, Sendable {
    public nonisolated enum ParseError: Error, Equatable, LocalizedError, Sendable {
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let value):
                return "\(value.debugDescription) is not a valid Semantic Version 2.0.0 value."
            }
        }
    }

    /// Canonical decimal components are stored as strings so SemVer's
    /// unbounded numeric identifiers do not inherit an integer overflow limit.
    public let major: String
    public let minor: String
    public let patch: String
    public let prerelease: [String]
    public let buildMetadata: [String]

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { value += "-" + prerelease.joined(separator: ".") }
        if !buildMetadata.isEmpty { value += "+" + buildMetadata.joined(separator: ".") }
        return value
    }

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({ $0 < 128 }) else {
            throw ParseError.invalid(value)
        }

        let buildSplit = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildSplit.count <= 2, buildSplit[0].isEmpty == false else {
            throw ParseError.invalid(value)
        }
        let build = buildSplit.count == 2
            ? buildSplit[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard buildSplit.count == 1 || Self.identifiersAreValid(build, numericLeadingZerosAllowed: true) else {
            throw ParseError.invalid(value)
        }

        let precedenceSplit = buildSplit[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false
        )
        guard precedenceSplit[0].isEmpty == false else { throw ParseError.invalid(value) }
        let prerelease = precedenceSplit.count == 2
            ? precedenceSplit[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard precedenceSplit.count == 1 || Self.identifiersAreValid(prerelease, numericLeadingZerosAllowed: false) else {
            throw ParseError.invalid(value)
        }

        let core = precedenceSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.parseCoreNumber(core[0]),
              let minor = Self.parseCoreNumber(core[1]),
              let patch = Self.parseCoreNumber(core[2]) else {
            throw ParseError.invalid(value)
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = build
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid semantic version: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Compares SemVer precedence. Build metadata is intentionally ignored.
    public func precedence(comparedTo other: SemanticVersion) -> ComparisonResult {
        for (left, right) in [(major, other.major), (minor, other.minor), (patch, other.patch)] {
            let result = Self.compareNumericStrings(left, right)
            if result != .orderedSame { return result }
        }

        if prerelease.isEmpty { return other.prerelease.isEmpty ? .orderedSame : .orderedDescending }
        if other.prerelease.isEmpty { return .orderedAscending }

        for (left, right) in zip(prerelease, other.prerelease) where left != right {
            let leftIsNumeric = Self.isNumeric(left)
            let rightIsNumeric = Self.isNumeric(right)
            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true): return Self.compareNumericStrings(left, right)
            case (true, false): return .orderedAscending
            case (false, true): return .orderedDescending
            case (false, false):
                return left.utf8.lexicographicallyPrecedes(right.utf8)
                    ? .orderedAscending : .orderedDescending
            }
        }
        if prerelease.count == other.prerelease.count { return .orderedSame }
        return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
    }

    public func isAtLeast(_ requiredVersion: SemanticVersion) -> Bool {
        precedence(comparedTo: requiredVersion) != .orderedAscending
    }

    private static func parseCoreNumber(_ value: Substring) -> String? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              value.count == 1 || value.first != "0" else { return nil }
        return String(value)
    }

    private static func identifiersAreValid(
        _ identifiers: [String],
        numericLeadingZerosAllowed: Bool
    ) -> Bool {
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte)
                          || (97...122).contains(byte) || byte == 45
                  }) else { return false }
            let isNumeric = identifier.utf8.allSatisfy { (48...57).contains($0) }
            return numericLeadingZerosAllowed || !isNumeric
                || identifier.count == 1 || identifier.first != "0"
        }
    }

    private static func isNumeric(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func compareNumericStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
        if lhs == rhs { return .orderedSame }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
    }
}
