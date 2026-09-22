import Foundation

/// Identifies who owns an activity. The identifier is stable within its kind
/// (for example, `music` for a built-in provider or a plugin bundle ID).
public nonisolated struct ActivitySource: Codable, Equatable, Hashable, Sendable {
    public nonisolated enum Kind: String, Codable, Sendable {
        case builtIn
        case plugin
        case external
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

/// A small, serializable summary. Phase 2 can add declarative layout nodes
/// without putting SwiftUI views or platform objects in the activity model.
public nonisolated struct ActivityPresentation: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var symbolName: String?
    public var progress: Double?

    public init(
        title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        progress: Double? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.progress = progress
    }
}

/// The Host routes an action ID back to its source. No executable callback
/// crosses the Activity boundary.
public nonisolated struct ActivityAction: Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A provider updates one event by publishing this value again with the same
/// ID. The manager, rather than the model, owns ID collision protection.
public nonisolated struct IslandActivity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: ActivitySource
    public var priority: ActivityPriority
    public var lifecycle: ActivityLifecycle
    public var presentation: ActivityPresentation
    public let createdAt: Date
    public var expiresAt: Date?
    public var actions: [ActivityAction]

    public init(
        id: String,
        source: ActivitySource,
        priority: ActivityPriority,
        lifecycle: ActivityLifecycle,
        presentation: ActivityPresentation,
        createdAt: Date,
        expiresAt: Date? = nil,
        actions: [ActivityAction] = []
    ) {
        self.id = id
        self.source = source
        self.priority = priority
        self.lifecycle = lifecycle
        self.presentation = presentation
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.actions = actions
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}
