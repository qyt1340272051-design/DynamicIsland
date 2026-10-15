import Foundation

/// The Host maps these finite image roles to physical sizes. A plugin cannot
/// request an arbitrary point size through an Activity payload.
public nonisolated enum IslandImageSizeToken: String, Codable, CaseIterable, Sendable {
    case icon
    case thumbnail
    case artwork
}

/// The Host owns the physical appearance of each progress style. Payloads can
/// select only from this finite vocabulary and cannot supply dimensions.
public nonisolated enum IslandProgressStyleToken: String, Codable, CaseIterable, Sendable {
    case linear
    case battery
}

/// Countdown values reference a Host record; no deadline or elapsed state is
/// embedded in the node. The Host owns the appearance of both finite styles.
public nonisolated enum IslandCountdownStyleToken: String, Codable, CaseIterable, Sendable {
    case time
    case progress
}

/// Data-only UI description. The Host owns rendering and action dispatch.
public nonisolated indirect enum IslandNode: Codable, Equatable, Sendable {
    case text(Text)
    case icon(Icon)
    case image(Image)
    case hStack(Stack)
    case vStack(Stack)
    case zStack(Stack)
    case spacer(Spacer)
    case divider(Divider)
    case progress(Progress)
    case countdown(Countdown)
    case button(Button)
    case toggle(Toggle)
    case slider(Slider)

    public nonisolated struct Text: Codable, Equatable, Sendable {
        public var content: String
        public var color: IslandSemanticColorToken

        private enum CodingKeys: String, CodingKey { case content, color }

        public init(_ content: String, color: IslandSemanticColorToken = .primary) {
            self.content = content
            self.color = color
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decode(String.self, forKey: .content)
            color = try container.decodeIfPresent(IslandSemanticColorToken.self, forKey: .color) ?? .primary
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(content, forKey: .content)
            if color != .primary { try container.encode(color, forKey: .color) }
        }
    }

    public nonisolated struct Icon: Codable, Equatable, Sendable {
        public var symbolName: String
        public init(_ symbolName: String) { self.symbolName = symbolName }
    }

    public nonisolated struct Image: Codable, Equatable, Sendable {
        public var source: ImageSource
        public var size: IslandImageSizeToken

        private enum CodingKeys: String, CodingKey { case source, size }

        public init(source: ImageSource, size: IslandImageSizeToken = .icon) {
            self.source = source
            self.size = size
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try container.decode(ImageSource.self, forKey: .source)
            size = try container.decodeIfPresent(IslandImageSizeToken.self, forKey: .size) ?? .icon
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .source)
            if size != .icon { try container.encode(size, forKey: .size) }
        }
    }

    public nonisolated struct Stack: Codable, Equatable, Sendable {
        public var children: [IslandNode]
        public init(_ children: [IslandNode]) { self.children = children }
    }

    public nonisolated struct Spacer: Codable, Equatable, Sendable {
        public init() {}
    }

    public nonisolated struct Divider: Codable, Equatable, Sendable {
        public init() {}
    }

    /// Normalized progress, in the inclusive range 0...1.
    public nonisolated struct Progress: Codable, Equatable, Sendable {
        public var value: Double
        public var style: IslandProgressStyleToken
        public var color: IslandSemanticColorToken

        private enum CodingKeys: String, CodingKey { case value, style, color }

        public init(
            _ value: Double,
            style: IslandProgressStyleToken = .linear,
            color: IslandSemanticColorToken = .accent
        ) {
            self.value = value
            self.style = style
            self.color = color
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Double.self, forKey: .value)
            style = try container.decodeIfPresent(IslandProgressStyleToken.self, forKey: .style) ?? .linear
            color = try container.decodeIfPresent(IslandSemanticColorToken.self, forKey: .color) ?? .accent
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            if style != .linear { try container.encode(style, forKey: .style) }
            if color != .accent { try container.encode(color, forKey: .color) }
        }
    }

    public nonisolated struct Countdown: Codable, Equatable, Sendable {
        public var id: String
        public var generation: String
        public var style: IslandCountdownStyleToken
        public var color: IslandSemanticColorToken

        private enum CodingKeys: String, CodingKey { case id, generation, style, color }

        public init(id: String, generation: String, style: IslandCountdownStyleToken = .time,
                    color: IslandSemanticColorToken = .accent) {
            self.id = id
            self.generation = generation
            self.style = style
            self.color = color
        }

        public init(from decoder: Decoder) throws {
            try IslandNode.checkCountdownFields(decoder, allowed: ["id", "generation", "style", "color"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            generation = try container.decode(String.self, forKey: .generation)
            style = container.contains(.style) ? try container.decode(IslandCountdownStyleToken.self, forKey: .style) : .time
            color = container.contains(.color) ? try container.decode(IslandSemanticColorToken.self, forKey: .color) : .accent
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            try validate()
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(generation, forKey: .generation)
            if style != .time { try container.encode(style, forKey: .style) }
            if color != .accent { try container.encode(color, forKey: .color) }
        }

        fileprivate func validate() throws {
            guard !id.isEmpty, id.utf8.count <= Limits.maxActionIDBytes,
                  id.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                          || byte == 45 || byte == 46 || byte == 95
                  }), generation.utf8.count == 36,
                  let uuid = UUID(uuidString: generation), uuid.uuidString.lowercased() == generation else {
                throw ValidationError.invalidIdentifier
            }
        }
    }

    public nonisolated struct Button: Codable, Equatable, Sendable {
        public var actionID: String
        public var label: IslandNode
        public var accessibilityLabel: String?

        public init(actionID: String, label: IslandNode, accessibilityLabel: String? = nil) {
            self.actionID = actionID
            self.label = label
            self.accessibilityLabel = accessibilityLabel
        }
    }

    public nonisolated struct Toggle: Codable, Equatable, Sendable {
        public var title: String
        public var isOn: Bool
        public var actionID: String
        public init(title: String, isOn: Bool, actionID: String) {
            self.title = title
            self.isOn = isOn
            self.actionID = actionID
        }
    }

    /// Normalized slider value, in the inclusive range 0...1.
    public nonisolated struct Slider: Codable, Equatable, Sendable {
        public var title: String
        public var value: Double
        public var actionID: String
        public var showsTitle: Bool

        private enum CodingKeys: String, CodingKey { case title, value, actionID, showsTitle }

        public init(title: String, value: Double, actionID: String, showsTitle: Bool = true) {
            self.title = title
            self.value = value
            self.actionID = actionID
            self.showsTitle = showsTitle
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            value = try container.decode(Double.self, forKey: .value)
            actionID = try container.decode(String.self, forKey: .actionID)
            showsTitle = try container.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(value, forKey: .value)
            try container.encode(actionID, forKey: .actionID)
            if !showsTitle { try container.encode(false, forKey: .showsTitle) }
        }
    }

    /// Identifiers only: the Host resolves plugin assets and Broker resources.
    /// A plugin cannot embed a URL or a filesystem path in the node tree.
    public nonisolated enum ImageSource: Codable, Equatable, Sendable {
        case systemSymbol(name: String)
        case pluginAsset(id: String)
        case brokerResource(id: String)

        private enum CodingKeys: String, CodingKey { case type, name, id }
        private enum Kind: String, Codable { case systemSymbol, pluginAsset, brokerResource }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .type)
            switch kind {
            case .systemSymbol: self = .systemSymbol(name: try container.decode(String.self, forKey: .name))
            case .pluginAsset: self = .pluginAsset(id: try container.decode(String.self, forKey: .id))
            case .brokerResource: self = .brokerResource(id: try container.decode(String.self, forKey: .id))
            }
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            try validate()
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .systemSymbol(let name):
                try container.encode(Kind.systemSymbol, forKey: .type)
                try container.encode(name, forKey: .name)
            case .pluginAsset(let id):
                try container.encode(Kind.pluginAsset, forKey: .type)
                try container.encode(id, forKey: .id)
            case .brokerResource(let id):
                try container.encode(Kind.brokerResource, forKey: .type)
                try container.encode(id, forKey: .id)
            }
        }

        fileprivate func validate() throws {
            switch self {
            case .systemSymbol(let name): try IslandNode.checkIdentifier(name, maxBytes: Limits.maxIdentifierBytes)
            case .pluginAsset(let id), .brokerResource(let id):
                try IslandNode.checkIdentifier(id, maxBytes: Limits.maxIdentifierBytes)
            }
        }
    }

    public nonisolated enum Limits {
        public static let maxDepth = 8
        public static let maxChildren = 16
        public static let maxNodes = 128
        public static let maxTextBytes = 256
        public static let maxIdentifierBytes = 128
        public static let maxActionIDBytes = 80
        public static let maxJSONBytes = 65_536
    }

    public nonisolated enum ValidationError: Error, Equatable, Sendable {
        case depthExceeded
        case tooManyChildren
        case tooManyNodes
        case textTooLong
        case invalidIdentifier
        case invalidNumber
        case jsonTooLarge
    }

    /// Entry point for untrusted plugin JSON. Also validates encoded trees.
    public static func decodeJSON(_ data: Data) throws -> IslandNode {
        guard data.count <= Limits.maxJSONBytes else { throw ValidationError.jsonTooLarge }
        return try JSONDecoder().decode(IslandNode.self, from: data)
    }

    public func encodeJSON() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Limits.maxJSONBytes else { throw ValidationError.jsonTooLarge }
        return data
    }

    public func validate() throws {
        var count = 0
        try validate(depth: 1, count: &count)
    }

    /// Read-only references in authored order, including button labels. A
    /// malformed tree yields no partial inventory. Validation bounds the walk
    /// to maxDepth / maxNodes before any references are collected.
    public var countdownReferences: [Countdown] {
        guard (try? validate()) != nil else { return [] }
        var result: [Countdown] = []
        collectCountdownReferences(into: &result)
        return result
    }

    private func collectCountdownReferences(into result: inout [Countdown]) {
        switch self {
        case .countdown(let countdown): result.append(countdown)
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            for child in stack.children { child.collectCountdownReferences(into: &result) }
        case .button(let button): button.label.collectCountdownReferences(into: &result)
        case .text, .icon, .image, .spacer, .divider, .progress, .toggle, .slider: break
        }
    }

    private func validate(depth: Int, count: inout Int) throws {
        guard depth <= Limits.maxDepth else { throw ValidationError.depthExceeded }
        count += 1
        guard count <= Limits.maxNodes else { throw ValidationError.tooManyNodes }
        switch self {
        case .text(let node): try Self.checkText(node.content)
        case .icon(let node): try Self.checkIdentifier(node.symbolName, maxBytes: Limits.maxIdentifierBytes)
        case .image(let node): try node.source.validate()
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            guard stack.children.count <= Limits.maxChildren else { throw ValidationError.tooManyChildren }
            for child in stack.children { try child.validate(depth: depth + 1, count: &count) }
        case .spacer, .divider: break
        case .progress(let node): try Self.checkNormalized(node.value)
        case .countdown(let node): try node.validate()
        case .button(let node):
            try Self.checkIdentifier(node.actionID, maxBytes: Limits.maxActionIDBytes)
            if let accessibilityLabel = node.accessibilityLabel {
                try Self.checkText(accessibilityLabel)
            }
            try node.label.validate(depth: depth + 1, count: &count)
        case .toggle(let node):
            try Self.checkText(node.title)
            try Self.checkIdentifier(node.actionID, maxBytes: Limits.maxActionIDBytes)
        case .slider(let node):
            try Self.checkText(node.title)
            try Self.checkNormalized(node.value)
            try Self.checkIdentifier(node.actionID, maxBytes: Limits.maxActionIDBytes)
        }
    }

    private static func checkText(_ value: String) throws {
        guard value.utf8.count <= Limits.maxTextBytes else { throw ValidationError.textTooLong }
    }

    private static func checkIdentifier(_ value: String, maxBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maxBytes,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 58 || byte == 95
              }) else { throw ValidationError.invalidIdentifier }
    }

    private static func checkNormalized(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw ValidationError.invalidNumber }
    }

    private struct CountdownFieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func checkCountdownFields(_ decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: CountdownFieldKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown countdown field"))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, content, symbolName, source, size, children, value, actionID, label
        case accessibilityLabel, title, isOn, showsTitle, style, color, id, generation
    }
    private enum Kind: String, Codable {
        case text, icon, image, hStack, vStack, zStack, spacer, divider, progress, countdown, button, toggle, slider
    }

    public init(from decoder: Decoder) throws {
        // Check before descending: an attacker must not induce an unbounded decoder stack.
        let depth = 1 + decoder.codingPath.filter { $0.intValue != nil || $0.stringValue == CodingKeys.label.rawValue }.count
        guard depth <= Limits.maxDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "IslandNode depth exceeded"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .text: self = .text(.init(
            try container.decode(String.self, forKey: .content),
            color: try container.decodeIfPresent(IslandSemanticColorToken.self, forKey: .color) ?? .primary
        ))
        case .icon: self = .icon(.init(try container.decode(String.self, forKey: .symbolName)))
        case .image: self = .image(.init(
            source: try container.decode(ImageSource.self, forKey: .source),
            size: try container.decodeIfPresent(IslandImageSizeToken.self, forKey: .size) ?? .icon
        ))
        case .hStack, .vStack, .zStack:
            var nested = try container.nestedUnkeyedContainer(forKey: .children)
            if let count = nested.count, count > Limits.maxChildren {
                throw DecodingError.dataCorruptedError(forKey: .children, in: container, debugDescription: "Too many children")
            }
            var children: [IslandNode] = []
            while !nested.isAtEnd {
                guard children.count < Limits.maxChildren else {
                    throw DecodingError.dataCorruptedError(forKey: .children, in: container, debugDescription: "Too many children")
                }
                children.append(try nested.decode(IslandNode.self))
            }
            let stack = Stack(children)
            switch kind {
            case .hStack: self = .hStack(stack)
            case .vStack: self = .vStack(stack)
            case .zStack: self = .zStack(stack)
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid stack kind")
            }
        case .spacer: self = .spacer(.init())
        case .divider: self = .divider(.init())
        case .progress: self = .progress(.init(
            try container.decode(Double.self, forKey: .value),
            style: try container.decodeIfPresent(IslandProgressStyleToken.self, forKey: .style) ?? .linear,
            color: try container.decodeIfPresent(IslandSemanticColorToken.self, forKey: .color) ?? .accent
        ))
        case .countdown:
            try Self.checkCountdownFields(decoder, allowed: ["type", "id", "generation", "style", "color"])
            self = .countdown(.init(
                id: try container.decode(String.self, forKey: .id),
                generation: try container.decode(String.self, forKey: .generation),
                style: container.contains(.style) ? try container.decode(IslandCountdownStyleToken.self, forKey: .style) : .time,
                color: container.contains(.color) ? try container.decode(IslandSemanticColorToken.self, forKey: .color) : .accent
            ))
        case .button: self = .button(.init(
            actionID: try container.decode(String.self, forKey: .actionID),
            label: try container.decode(IslandNode.self, forKey: .label),
            accessibilityLabel: try container.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        ))
        case .toggle: self = .toggle(.init(
            title: try container.decode(String.self, forKey: .title),
            isOn: try container.decode(Bool.self, forKey: .isOn),
            actionID: try container.decode(String.self, forKey: .actionID)
        ))
        case .slider: self = .slider(.init(
            title: try container.decode(String.self, forKey: .title),
            value: try container.decode(Double.self, forKey: .value),
            actionID: try container.decode(String.self, forKey: .actionID),
            showsTitle: try container.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        ))
        }
        do { try validate() }
        catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid IslandNode: \(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let node):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(node.content, forKey: .content)
            if node.color != .primary { try container.encode(node.color, forKey: .color) }
        case .icon(let node):
            try container.encode(Kind.icon, forKey: .type)
            try container.encode(node.symbolName, forKey: .symbolName)
        case .image(let node):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(node.source, forKey: .source)
            if node.size != .icon { try container.encode(node.size, forKey: .size) }
        case .hStack(let node):
            try container.encode(Kind.hStack, forKey: .type)
            try container.encode(node.children, forKey: .children)
        case .vStack(let node):
            try container.encode(Kind.vStack, forKey: .type)
            try container.encode(node.children, forKey: .children)
        case .zStack(let node):
            try container.encode(Kind.zStack, forKey: .type)
            try container.encode(node.children, forKey: .children)
        case .spacer:
            try container.encode(Kind.spacer, forKey: .type)
        case .divider:
            try container.encode(Kind.divider, forKey: .type)
        case .progress(let node):
            try container.encode(Kind.progress, forKey: .type)
            try container.encode(node.value, forKey: .value)
            if node.style != .linear { try container.encode(node.style, forKey: .style) }
            if node.color != .accent { try container.encode(node.color, forKey: .color) }
        case .countdown(let node):
            try container.encode(Kind.countdown, forKey: .type)
            try container.encode(node.id, forKey: .id)
            try container.encode(node.generation, forKey: .generation)
            if node.style != .time { try container.encode(node.style, forKey: .style) }
            if node.color != .accent { try container.encode(node.color, forKey: .color) }
        case .button(let node):
            try container.encode(Kind.button, forKey: .type)
            try container.encode(node.actionID, forKey: .actionID)
            try container.encode(node.label, forKey: .label)
            try container.encodeIfPresent(node.accessibilityLabel, forKey: .accessibilityLabel)
        case .toggle(let node):
            try container.encode(Kind.toggle, forKey: .type)
            try container.encode(node.title, forKey: .title)
            try container.encode(node.isOn, forKey: .isOn)
            try container.encode(node.actionID, forKey: .actionID)
        case .slider(let node):
            try container.encode(Kind.slider, forKey: .type)
            try container.encode(node.title, forKey: .title)
            try container.encode(node.value, forKey: .value)
            try container.encode(node.actionID, forKey: .actionID)
            if !node.showsTitle { try container.encode(false, forKey: .showsTitle) }
        }
    }
}
