import Foundation

/// A compatible module supplies two data snapshots, never Host identity,
/// lifetime, priority, callbacks, or a request to manipulate the window.
nonisolated enum SuperIslandModuleConverter {
    static let localID = "superisland-module"

    nonisolated struct Conversion: Equatable, Sendable {
        let presentation: ActivityPresentation
        let actions: [ActivityAction]
        let limitations: Set<SuperIslandViewConverter.Limitation>

        func request(isUpdate: Bool) -> PluginActivityConverter.Request {
            .init(localID: SuperIslandModuleConverter.localID, priority: .background,
                  policy: .persistent, presentation: presentation, actions: actions,
                  isUpdate: isUpdate)
        }
    }

    static func convert(_ value: PluginBridgeJSON, title: String) throws -> Conversion {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        // Manifest names count Unicode scalars, while Activity titles have a
        // byte bound. A valid name can still exceed the ordinary bridge limit.
        guard title.utf8.count <= 256 else { throw PluginBridgeErrorCode.quotaExceeded }
        guard case .object(let fields) = value, Set(fields.keys) == ["compact", "expanded"],
              let compactValue = fields["compact"], let expandedValue = fields["expanded"] else {
            throw PluginBridgeErrorCode.invalidArguments
        }
        let compact: SuperIslandViewConverter.Conversion
        let expanded: SuperIslandViewConverter.Conversion
        do {
            compact = try SuperIslandViewConverter.convert(compactValue)
            expanded = try SuperIslandViewConverter.convert(expandedValue)
        } catch SuperIslandViewConversionError.quotaExceeded {
            throw PluginBridgeErrorCode.quotaExceeded
        } catch {
            throw PluginBridgeErrorCode.invalidArguments
        }
        let actionIDs = compact.actionIDs.union(expanded.actionIDs)
        guard actionIDs.count <= 8 else { throw PluginBridgeErrorCode.quotaExceeded }
        // Sorting makes the complete declaration independent of Dictionary/Set
        // iteration and keeps the ordinary eight-action Host bound intact.
        let actions = actionIDs.sorted().map { ActivityAction(id: $0, title: $0) }
        let presentation = ActivityPresentation(title: title, compact: compact.node,
            expanded: expanded.node, showsCompact: true, role: .tool, compactPolicy: .selectedOnly)
        return .init(presentation: presentation, actions: actions,
                     limitations: compact.limitations.union(expanded.limitations))
    }
}
