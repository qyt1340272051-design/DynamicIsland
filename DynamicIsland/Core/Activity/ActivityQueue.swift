import Foundation

/// A deterministic view of eligible Activity data. Storage and transitions
/// remain exclusively in ActivityManager.
public nonisolated struct ActivityQueue {
    public static func ordered(
        _ activities: [IslandActivity],
        at date: Date,
        currentlyPresentedID: String?
    ) -> [IslandActivity] {
        activities.filter {
            !$0.isExpired(at: date) &&
            ($0.lifecycle.state == .queued || $0.lifecycle.state == .background || $0.lifecycle.state == .presented)
        }.sorted {
            ActivityPriority.precedes($0, $1, currentlyPresentedID: currentlyPresentedID)
        }
    }

    public static func next(
        _ activities: [IslandActivity],
        at date: Date,
        current: IslandActivity?
    ) -> IslandActivity? {
        let ranked = ordered(activities, at: date, currentlyPresentedID: current?.id)
        if let current,
           current.lifecycle.state == .presented,
           !current.lifecycle.policy.isInterruptible,
           ranked.contains(where: { $0.id == current.id }) {
            return ranked.first(where: { $0.id == current.id })
        }
        return ranked.first
    }
}
