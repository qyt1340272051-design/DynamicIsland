import Foundation

/// A finite set of Host-controlled priority levels. The plugin converter caps
/// requests at normal until elevated Host grants are defined by a later phase.
public nonisolated enum ActivityPriority: String, Codable, CaseIterable, Sendable {
    case background
    case normal
    case important
    case critical

    private var rank: Int {
        switch self {
        case .background: return 0
        case .normal: return 1
        case .important: return 2
        case .critical: return 3
        }
    }

    /// Initial defaults for the built-in providers. Providers may choose a
    /// different level for a particular event, subject to Host policy.
    public static func defaultForBuiltIn(_ kind: BuiltInActivityKind) -> Self {
        switch kind {
        case .music: return .background
        case .volume, .batteryCharging, .download, .airPods: return .normal
        case .batteryLow, .timerCompletion: return .important
        case .batteryCritical: return .critical
        }
    }

    /// Total ordering used by the future queue. A current display holds its
    /// place among interruptible peers; a noninterruptible peer goes first.
    /// Older creation times and finally IDs make the result deterministic.
    public static func precedes(
        _ lhs: IslandActivity,
        _ rhs: IslandActivity,
        currentlyPresentedID: String?
    ) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority.rank > rhs.priority.rank
        }
        if lhs.lifecycle.policy.isInterruptible != rhs.lifecycle.policy.isInterruptible {
            return !lhs.lifecycle.policy.isInterruptible
        }
        let lhsIsCurrent = lhs.id == currentlyPresentedID
        let rhsIsCurrent = rhs.id == currentlyPresentedID
        if lhsIsCurrent != rhsIsCurrent {
            return lhsIsCurrent
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}

public nonisolated enum BuiltInActivityKind: String, Codable, CaseIterable, Sendable {
    case music
    case volume
    case batteryCharging
    case batteryLow
    case batteryCritical
    case download
    case airPods
    case timerCompletion
}
