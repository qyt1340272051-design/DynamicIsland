import Foundation

/// Converts bounded, data-only plugin arguments into Host-owned Activity data.
/// Ownership, time and lifecycle state are supplied by the Host, never by JS.
nonisolated struct PluginActivityConverter: Sendable {
    nonisolated struct Request: Equatable, Sendable {
        let localID: String
        let priority: ActivityPriority?
        let policy: ActivityLifecycle.Policy?
        let presentation: ActivityPresentation?
        let actions: [ActivityAction]?
        let isUpdate: Bool

        /// Publish supplies a complete value using Host defaults. Update patches
        /// only supplied fields and preserves the existing event's lifetime.
        func materialize(source: ActivitySource, namespacedID: String, now: Date,
                         existing: IslandActivity? = nil) throws -> IslandActivity {
            if isUpdate {
                guard var activity = existing else { throw PluginBridgeErrorCode.activityNotFound }
                guard activity.id == namespacedID, activity.source == source else {
                    throw PluginBridgeErrorCode.invalidArguments
                }
                // The scheduler owns state transitions. Rebuilding lifecycle
                // here would reopen dismissed events or discard their state.
                if let policy, policy != activity.lifecycle.policy {
                    throw PluginBridgeErrorCode.invalidArguments
                }
                if let priority { activity.priority = priority }
                if let presentation { activity.presentation = presentation }
                if let actions { activity.actions = actions }
                try PluginActivityConverter.validateLayoutActions(in: activity)
                return activity
            }

            guard let presentation else { throw PluginBridgeErrorCode.invalidArguments }
            let activity = IslandActivity(
                id: namespacedID, source: source, priority: priority ?? .normal,
                lifecycle: .init(policy: policy ?? .transient),
                presentation: presentation, createdAt: now, actions: actions ?? []
            )
            try PluginActivityConverter.validateLayoutActions(in: activity)
            return activity
        }
    }

    static func parse(_ value: PluginBridgeJSON, isUpdate: Bool) throws -> Request {
        let fields = try object(value, required: isUpdate ? ["id"] : ["id", "presentation"],
                                optional: ["priority", "lifecycle", "presentation", "actions"])
        guard !isUpdate || fields.count > 1 else { throw PluginBridgeErrorCode.invalidArguments }
        let localID = try identifier(fields["id"], maximumBytes: 80)
        let priority = try fields["priority"].map { value -> ActivityPriority in
            guard let requested = ActivityPriority(rawValue: try string(value, maximumBytes: 32)) else {
                throw PluginBridgeErrorCode.invalidArguments
            }
            // Elevated plugin priority awaits the Host grant policy in T28.
            return requested == .background ? .background : .normal
        }
        let policy = try fields["lifecycle"].map { value -> ActivityLifecycle.Policy in
            let lifecycle = try object(value, required: ["policy"])
            guard let requested = ActivityLifecycle.Policy(rawValue: try string(lifecycle["policy"], maximumBytes: 32)) else {
                throw PluginBridgeErrorCode.invalidArguments
            }
            // A plugin cannot make its Activity noninterruptible at this stage.
            return requested == .critical ? .transient : requested
        }
        let presentation = try fields["presentation"].map(parsePresentation)
        let actions = try fields["actions"].map(parseActions)
        return Request(localID: localID, priority: priority, policy: policy,
                       presentation: presentation, actions: actions, isUpdate: isUpdate)
    }

    private static func parsePresentation(_ value: PluginBridgeJSON) throws -> ActivityPresentation {
        let fields = try object(value, required: ["title"], optional: ["subtitle", "symbolName", "progress", "minimal", "compact", "expanded"])
        let title = try string(fields["title"], maximumBytes: 256, nonempty: true)
        let subtitle = try fields["subtitle"].map { try string($0, maximumBytes: 256) }
        let symbolName = try fields["symbolName"].map {
            try identifier($0, maximumBytes: 128, allowsColon: true)
        }
        let progress = try fields["progress"].map { value -> Double in
            guard case .number(let number) = value, number.isFinite, (0...1).contains(number) else {
                throw PluginBridgeErrorCode.invalidArguments
            }
            return number
        }
        return ActivityPresentation(
            title: title, subtitle: subtitle, symbolName: symbolName, progress: progress,
            minimal: try fields["minimal"].map(PluginIslandNodeConverter.parse),
            compact: try fields["compact"].map(PluginIslandNodeConverter.parse),
            expanded: try fields["expanded"].map(PluginIslandNodeConverter.parse)
        )
    }

    static func hasLayouts(in presentation: ActivityPresentation) -> Bool {
        presentation.minimal != nil || presentation.compact != nil || presentation.expanded != nil
    }

    static func layoutActionIDs(in presentation: ActivityPresentation) -> Set<String> {
        [presentation.minimal, presentation.compact, presentation.expanded]
            .compactMap { $0 }.reduce(into: Set<String>()) { result, node in
                result.formUnion(PluginIslandNodeConverter.actionIDs(in: node))
            }
    }

    private static func validateLayoutActions(in activity: IslandActivity) throws {
        let referenced = layoutActionIDs(in: activity.presentation)
        guard referenced.isSubset(of: Set(activity.actions.map(\.id))) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
    }

    private static func parseActions(_ value: PluginBridgeJSON) throws -> [ActivityAction] {
        guard case .array(let values) = value else { throw PluginBridgeErrorCode.invalidArguments }
        guard values.count <= 8 else { throw PluginBridgeErrorCode.quotaExceeded }
        var identifiers: Set<String> = []
        return try values.map { value in
            let fields = try object(value, required: ["id", "title"])
            let id = try identifier(fields["id"], maximumBytes: 80)
            guard identifiers.insert(id).inserted else { throw PluginBridgeErrorCode.invalidArguments }
            return ActivityAction(id: id, title: try string(fields["title"], maximumBytes: 128, nonempty: true))
        }
    }

    private static func object(_ value: PluginBridgeJSON, required: Set<String>,
                               optional: Set<String> = []) throws -> [String: PluginBridgeJSON] {
        guard case .object(let fields) = value,
              required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)) else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        return fields
    }

    private static func string(_ value: PluginBridgeJSON?, maximumBytes: Int,
                               nonempty: Bool = false) throws -> String {
        guard case .string(let string) = value,
              !nonempty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        guard string.utf8.count <= maximumBytes else { throw PluginBridgeErrorCode.quotaExceeded }
        return string
    }

    private static func identifier(_ value: PluginBridgeJSON?, maximumBytes: Int,
                                   allowsColon: Bool = false) throws -> String {
        let result = try string(value, maximumBytes: maximumBytes, nonempty: true)
        guard result.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || (allowsColon && byte == 58)
        }) else { throw PluginBridgeErrorCode.invalidArguments }
        return result
    }
}
