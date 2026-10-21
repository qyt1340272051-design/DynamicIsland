import Foundation

nonisolated enum SuperIslandViewConversionError: Error, Equatable, Sendable {
    case invalidArguments
    case unsupportedNode
    case unsupportedProperty
    case unsupportedValue
    case quotaExceeded
}

/// Independently implements the bounded View description protocol documented
/// by SuperIsland commit 68cce87205a88a004e74e33f40bbcb253f8287e9. No upstream
/// implementation or JavaScript/native reference is retained by this adapter.
nonisolated struct SuperIslandViewConverter: Sendable {
    /// Differences cannot disappear when the caller later presents a package's
    /// compatibility level. These are a finite Host vocabulary, not user text.
    typealias Limitation = PluginCompatibilityLayoutLimitation

    nonisolated struct Conversion: Equatable, Sendable {
        let node: IslandNode
        let limitations: Set<Limitation>
        /// References only. Conversion does not declare, register or authorize
        /// actions; the existing Activity/ActionRouter boundary still does so.
        let actionIDs: Set<String>
    }

    /// JSON input independently rejects duplicate fields and excessive wire
    /// size. JSON depth counts object/array containers, unlike node depth.
    static func convertJSON(_ source: String) throws -> Conversion {
        let value: PluginBridgeJSON
        do {
            value = try PluginBridgeJSON.parse(source, maximumBytes: IslandNode.Limits.maxJSONBytes,
                maximumDepth: maximumJSONDepth, maximumNodes: maximumJSONNodes)
        } catch PluginBridgeJSON.ParseError.limitExceeded {
            throw SuperIslandViewConversionError.quotaExceeded
        } catch {
            throw SuperIslandViewConversionError.invalidArguments
        }
        return try convert(value)
    }

    /// The caller supplies a data-only snapshot. Accessors, coercions, JSValue,
    /// native objects and callbacks are deliberately outside this interface.
    static func convert(_ value: PluginBridgeJSON) throws -> Conversion {
        do {
            try value.validate(maximumDepth: maximumJSONDepth, maximumNodes: maximumJSONNodes,
                               maximumStringBytes: IslandNode.Limits.maxTextBytes)
        } catch PluginBridgeJSON.ParseError.limitExceeded {
            throw SuperIslandViewConversionError.quotaExceeded
        } catch {
            throw SuperIslandViewConversionError.invalidArguments
        }
        // Validation above bounds this encoding before any recursive mapping.
        guard try value.encodedData().count <= IslandNode.Limits.maxJSONBytes else {
            throw SuperIslandViewConversionError.quotaExceeded
        }
        var count = 0
        var limitations: Set<Limitation> = []
        let mapped = try map(value, depth: 1, count: &count, limitations: &limitations)
        let node: IslandNode
        do {
            node = try PluginIslandNodeConverter.parse(mapped)
        } catch PluginBridgeErrorCode.quotaExceeded {
            throw SuperIslandViewConversionError.quotaExceeded
        } catch {
            throw SuperIslandViewConversionError.invalidArguments
        }
        return Conversion(node: node, limitations: limitations,
                          actionIDs: PluginIslandNodeConverter.actionIDs(in: node))
    }

    private static let maximumJSONDepth = IslandNode.Limits.maxDepth * 2 + 2
    private static let maximumJSONNodes = IslandNode.Limits.maxNodes * 12
    private static let textStyles: Set<String> = [
        "largeTitle", "title", "subtitle", "headline", "body", "caption", "footnote",
        "monospaced", "monospacedSmall"
    ]
    private static let iconSizes: Set<Double> = [12, 14, 16, 20, 24, 28, 32]
    private static let stackSpacings: Set<Double> = [0, 4, 8, 12, 16]

    private static func map(_ value: PluginBridgeJSON, depth: Int, count: inout Int,
                            limitations: inout Set<Limitation>) throws -> PluginBridgeJSON {
        guard depth <= IslandNode.Limits.maxDepth, count < IslandNode.Limits.maxNodes else {
            throw SuperIslandViewConversionError.quotaExceeded
        }
        count += 1
        guard case .object(let fields) = value, case .string(let kind) = fields["type"] else {
            throw SuperIslandViewConversionError.invalidArguments
        }
        switch kind {
        case "text":
            try checkFields(fields, required: ["type", "value"], optional: ["style", "color", "lineLimit"])
            guard case .string(let content) = fields["value"] else {
                throw SuperIslandViewConversionError.invalidArguments
            }
            if let style = fields["style"] { try checkToken(style, allowed: textStyles) }
            if let lineLimit = fields["lineLimit"] {
                let lines = try finiteNumber(lineLimit)
                guard lines.rounded(.towardZero) == lines, (1...16).contains(lines) else {
                    throw SuperIslandViewConversionError.unsupportedValue
                }
            }
            // Host text is mode-specific and single-line, including when the
            // upstream description omitted its unlimited lineLimit default.
            limitations.formUnion([.hostTextTypography, .hostTextLineLimit])
            let color = try color(fields["color"], limitations: &limitations)
            return .object(["type": .string("text"), "content": .string(content),
                            "color": .string(color.rawValue)])
        case "icon":
            try checkFields(fields, required: ["type", "name"], optional: ["size", "color"])
            if let size = fields["size"] {
                guard iconSizes.contains(try finiteNumber(size)) else {
                    throw SuperIslandViewConversionError.unsupportedValue
                }
            }
            _ = try color(fields["color"], limitations: &limitations)
            // IslandNode.Icon has neither a point size nor a color field.
            limitations.insert(.hostIconAppearance)
            return .object(["type": .string("icon"),
                            "symbolName": .string(try identifier(fields["name"],
                                maximumBytes: IslandNode.Limits.maxIdentifierBytes, allowsColon: true))])
        case "hstack", "vstack":
            try checkFields(fields, required: ["type", "children"],
                            optional: ["spacing", "align", "distribution"])
            guard case .array(let values) = fields["children"] else {
                throw SuperIslandViewConversionError.invalidArguments
            }
            guard values.count <= IslandNode.Limits.maxChildren else {
                throw SuperIslandViewConversionError.quotaExceeded
            }
            if let spacing = fields["spacing"] {
                guard stackSpacings.contains(try finiteNumber(spacing)) else {
                    throw SuperIslandViewConversionError.unsupportedValue
                }
            }
            if let align = fields["align"] {
                try checkToken(align, allowed: kind == "hstack"
                    ? ["top", "center", "bottom"] : ["leading", "center", "trailing"])
            }
            if let distribution = fields["distribution"] {
                try checkToken(distribution, allowed: ["natural", "fillEqually"])
                if distribution == .string("fillEqually") {
                    limitations.insert(.hostStackDistribution)
                }
            }
            // Physical spacing/alignment belongs to the existing Host renderer.
            // Defaults also differ by mode and by stack axis.
            limitations.formUnion([.hostStackSpacing, .hostStackAlignment])
            var children: [PluginBridgeJSON] = []
            children.reserveCapacity(values.count)
            for child in values {
                children.append(try map(child, depth: depth + 1, count: &count, limitations: &limitations))
            }
            return .object(["type": .string(kind == "hstack" ? "hStack" : "vStack"),
                            "children": .array(children)])
        case "progress":
            try checkFields(fields, required: ["type", "value"], optional: ["total", "color"])
            let amount = try finiteNumber(fields["value"])
            let total = try fields["total"].map { try finiteNumber($0) } ?? 1
            guard total > 0, amount >= 0, amount <= total else {
                throw SuperIslandViewConversionError.invalidArguments
            }
            let ratio = amount / total
            guard ratio.isFinite, (0...1).contains(ratio) else {
                throw SuperIslandViewConversionError.invalidArguments
            }
            let color = try color(fields["color"], limitations: &limitations)
            return .object(["type": .string("progress"), "value": .number(ratio),
                            "style": .string("linear"), "color": .string(color.rawValue)])
        case "button":
            try checkFields(fields, required: ["type", "label", "action"])
            let action = try identifier(fields["action"], maximumBytes: IslandNode.Limits.maxActionIDBytes)
            guard let label = fields["label"] else { throw SuperIslandViewConversionError.invalidArguments }
            let converted = try map(label, depth: depth + 1, count: &count, limitations: &limitations)
            limitations.insert(.hostButtonAppearance)
            return .object(["type": .string("button"), "actionID": .string(action), "label": converted])
        default:
            throw SuperIslandViewConversionError.unsupportedNode
        }
    }

    private static func checkFields(_ fields: [String: PluginBridgeJSON], required: Set<String>,
                                    optional: Set<String> = []) throws {
        guard required.allSatisfy({ fields[$0] != nil }) else {
            throw SuperIslandViewConversionError.invalidArguments
        }
        let allowed = required.union(optional)
        guard fields.count <= allowed.count, fields.keys.allSatisfy(allowed.contains) else {
            throw SuperIslandViewConversionError.unsupportedProperty
        }
    }

    private static func checkToken(_ value: PluginBridgeJSON, allowed: Set<String>) throws {
        guard case .string(let token) = value else { throw SuperIslandViewConversionError.invalidArguments }
        guard allowed.contains(token) else { throw SuperIslandViewConversionError.unsupportedValue }
    }

    private static func finiteNumber(_ value: PluginBridgeJSON?) throws -> Double {
        guard case .number(let number) = value, number.isFinite else {
            throw SuperIslandViewConversionError.invalidArguments
        }
        return number
    }

    private static func identifier(_ value: PluginBridgeJSON?, maximumBytes: Int,
                                   allowsColon: Bool = false) throws -> String {
        guard case .string(let identifier) = value, !identifier.isEmpty else {
            throw SuperIslandViewConversionError.invalidArguments
        }
        guard identifier.utf8.count <= maximumBytes else { throw SuperIslandViewConversionError.quotaExceeded }
        guard identifier.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || (allowsColon && byte == 58)
        }) else { throw SuperIslandViewConversionError.invalidArguments }
        return identifier
    }

    private static func color(_ value: PluginBridgeJSON?, limitations: inout Set<Limitation>) throws
        -> IslandSemanticColorToken {
        guard let value else { return .primary }
        // Upstream RGBA and arbitrary CSS/hex colors have no finite Host token.
        if case .object = value { throw SuperIslandViewConversionError.unsupportedValue }
        guard case .string(let name) = value else { throw SuperIslandViewConversionError.invalidArguments }
        let token: IslandSemanticColorToken
        switch name {
        case "white": return .primary
        case "gray": token = .secondary
        case "red": token = .danger
        case "green": token = .success
        case "blue": token = .accent
        case "yellow", "orange": token = .warning
        default: throw SuperIslandViewConversionError.unsupportedValue
        }
        limitations.insert(.semanticColors)
        return token
    }
}
