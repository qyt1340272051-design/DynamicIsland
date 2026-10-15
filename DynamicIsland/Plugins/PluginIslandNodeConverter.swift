import Foundation

/// Strict data-only conversion into the Host's finite UI vocabulary. The
/// traversal is bounded before descending, independently of Bridge JSON limits.
nonisolated struct PluginIslandNodeConverter: Sendable {
    static func parse(_ value: PluginBridgeJSON) throws -> IslandNode {
        var nodeCount = 0
        let node = try parse(value, depth: 1, nodeCount: &nodeCount)
        do {
            try node.validate()
        } catch let error as IslandNode.ValidationError {
            switch error {
            case .depthExceeded, .tooManyChildren, .tooManyNodes, .textTooLong, .jsonTooLarge:
                throw PluginBridgeErrorCode.quotaExceeded
            case .invalidIdentifier, .invalidNumber:
                throw PluginBridgeErrorCode.invalidArguments
            }
        } catch {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return node
    }

    /// Call after parsing. Bounds also protect callers that supply a manually
    /// constructed tree; invalid trees cannot induce an unbounded traversal.
    static func actionIDs(in node: IslandNode) -> Set<String> {
        var result: Set<String> = []
        var nodeCount = 0
        collectActionIDs(in: node, depth: 1, nodeCount: &nodeCount, result: &result)
        return result
    }

    static func countdownNodes(in node: IslandNode) -> [IslandNode.Countdown] {
        node.countdownReferences
    }

    private static func parse(_ value: PluginBridgeJSON, depth: Int,
                              nodeCount: inout Int) throws -> IslandNode {
        guard depth <= IslandNode.Limits.maxDepth,
              nodeCount < IslandNode.Limits.maxNodes else {
            throw PluginBridgeErrorCode.quotaExceeded
        }
        nodeCount += 1
        guard case .object(let fields) = value,
              case .string(let kind) = fields["type"] else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        switch kind {
        case "text":
            try checkFields(fields, required: ["type", "content"], optional: ["color"])
            return .text(.init(
                try text(fields["content"]),
                color: try fields["color"].map { try token($0, as: IslandSemanticColorToken.self) } ?? .primary
            ))
        case "icon":
            try checkFields(fields, required: ["type", "symbolName"])
            return .icon(.init(try identifier(fields["symbolName"], allowsColon: true)))
        case "image":
            try checkFields(fields, required: ["type", "source"], optional: ["size"])
            guard let source = fields["source"] else { throw PluginBridgeErrorCode.invalidArguments }
            return .image(.init(
                source: try imageSource(source),
                size: try fields["size"].map { try token($0, as: IslandImageSizeToken.self) } ?? .icon
            ))
        case "hStack", "vStack", "zStack":
            try checkFields(fields, required: ["type", "children"])
            guard case .array(let values) = fields["children"] else {
                throw PluginBridgeErrorCode.invalidArguments
            }
            guard values.count <= IslandNode.Limits.maxChildren else {
                throw PluginBridgeErrorCode.quotaExceeded
            }
            var children: [IslandNode] = []
            children.reserveCapacity(values.count)
            for child in values {
                children.append(try parse(child, depth: depth + 1, nodeCount: &nodeCount))
            }
            let stack = IslandNode.Stack(children)
            switch kind {
            case "hStack": return .hStack(stack)
            case "vStack": return .vStack(stack)
            default: return .zStack(stack)
            }
        case "spacer":
            try checkFields(fields, required: ["type"])
            return .spacer(.init())
        case "divider":
            try checkFields(fields, required: ["type"])
            return .divider(.init())
        case "progress":
            try checkFields(fields, required: ["type", "value"], optional: ["style", "color"])
            return .progress(.init(
                try normalized(fields["value"]),
                style: try fields["style"].map { try token($0, as: IslandProgressStyleToken.self) } ?? .linear,
                color: try fields["color"].map { try token($0, as: IslandSemanticColorToken.self) } ?? .accent
            ))
        case "countdown":
            try checkFields(fields, required: ["type", "id", "generation"], optional: ["style", "color"])
            return .countdown(.init(
                id: try identifier(fields["id"], maximumBytes: IslandNode.Limits.maxActionIDBytes),
                generation: try countdownGeneration(fields["generation"]),
                style: try fields["style"].map { try token($0, as: IslandCountdownStyleToken.self) } ?? .time,
                color: try fields["color"].map { try token($0, as: IslandSemanticColorToken.self) } ?? .accent
            ))
        case "button":
            try checkFields(fields, required: ["type", "actionID", "label"], optional: ["accessibilityLabel"])
            guard let label = fields["label"] else { throw PluginBridgeErrorCode.invalidArguments }
            return .button(.init(
                actionID: try actionID(fields["actionID"]),
                label: try parse(label, depth: depth + 1, nodeCount: &nodeCount),
                accessibilityLabel: try fields["accessibilityLabel"].map { try text($0) }
            ))
        case "toggle":
            try checkFields(fields, required: ["type", "title", "isOn", "actionID"])
            return .toggle(.init(
                title: try text(fields["title"]),
                isOn: try boolean(fields["isOn"]),
                actionID: try actionID(fields["actionID"])
            ))
        case "slider":
            try checkFields(fields, required: ["type", "title", "value", "actionID"], optional: ["showsTitle"])
            return .slider(.init(
                title: try text(fields["title"]),
                value: try normalized(fields["value"]),
                actionID: try actionID(fields["actionID"]),
                showsTitle: try fields["showsTitle"].map { try boolean($0) } ?? true
            ))
        default:
            throw PluginBridgeErrorCode.invalidArguments
        }
    }

    private static func imageSource(_ value: PluginBridgeJSON) throws -> IslandNode.ImageSource {
        guard case .object(let fields) = value,
              case .string(let kind) = fields["type"] else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        switch kind {
        case "systemSymbol":
            try checkFields(fields, required: ["type", "name"])
            return .systemSymbol(name: try identifier(fields["name"], allowsColon: true))
        case "pluginAsset", "brokerResource":
            try checkFields(fields, required: ["type", "id"])
            // An asset/resource ID has no URL scheme, path, or data encoding.
            let id = try identifier(fields["id"])
            return kind == "pluginAsset" ? .pluginAsset(id: id) : .brokerResource(id: id)
        default:
            throw PluginBridgeErrorCode.invalidArguments
        }
    }

    private static func checkFields(_ fields: [String: PluginBridgeJSON],
                                    required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(fields.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
    }

    private static func text(_ value: PluginBridgeJSON?) throws -> String {
        guard case .string(let string) = value else { throw PluginBridgeErrorCode.invalidArguments }
        guard string.utf8.count <= IslandNode.Limits.maxTextBytes else {
            throw PluginBridgeErrorCode.quotaExceeded
        }
        return string
    }

    private static func identifier(_ value: PluginBridgeJSON?,
                                   maximumBytes: Int = IslandNode.Limits.maxIdentifierBytes,
                                   allowsColon: Bool = false) throws -> String {
        guard case .string(let string) = value, !string.isEmpty else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        guard string.utf8.count <= maximumBytes else { throw PluginBridgeErrorCode.quotaExceeded }
        guard string.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || (allowsColon && byte == 58)
        }) else { throw PluginBridgeErrorCode.invalidArguments }
        return string
    }

    private static func actionID(_ value: PluginBridgeJSON?) throws -> String {
        try identifier(value, maximumBytes: IslandNode.Limits.maxActionIDBytes)
    }

    private static func countdownGeneration(_ value: PluginBridgeJSON?) throws -> String {
        guard case .string(let string) = value, string.utf8.count == 36,
              let uuid = UUID(uuidString: string), uuid.uuidString.lowercased() == string else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return string
    }

    private static func token<T: RawRepresentable>(_ value: PluginBridgeJSON,
                                                  as type: T.Type) throws -> T where T.RawValue == String {
        guard case .string(let string) = value, let token = type.init(rawValue: string) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return token
    }

    private static func normalized(_ value: PluginBridgeJSON?) throws -> Double {
        guard case .number(let number) = value, number.isFinite, (0...1).contains(number) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return number
    }

    private static func boolean(_ value: PluginBridgeJSON?) throws -> Bool {
        guard case .boolean(let boolean) = value else { throw PluginBridgeErrorCode.invalidArguments }
        return boolean
    }

    private static func collectActionIDs(in node: IslandNode, depth: Int, nodeCount: inout Int,
                                         result: inout Set<String>) {
        guard depth <= IslandNode.Limits.maxDepth, nodeCount < IslandNode.Limits.maxNodes else { return }
        nodeCount += 1
        switch node {
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            for child in stack.children.prefix(IslandNode.Limits.maxChildren) {
                collectActionIDs(in: child, depth: depth + 1, nodeCount: &nodeCount, result: &result)
            }
        case .button(let button):
            result.insert(button.actionID)
            collectActionIDs(in: button.label, depth: depth + 1, nodeCount: &nodeCount, result: &result)
        case .toggle(let toggle): result.insert(toggle.actionID)
        case .slider(let slider): result.insert(slider.actionID)
        case .text, .icon, .image, .spacer, .divider, .progress, .countdown: break
        }
    }
}
