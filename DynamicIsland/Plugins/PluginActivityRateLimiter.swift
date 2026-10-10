import Foundation

/// Host admission for Activity model writes, separate from display scheduling.
/// One plugin shares its budget across IDs and Runtime replacements. There are
/// no timers: replenished entries are removed on the next admission attempt.
@MainActor
struct PluginActivityRateLimiter {
    private struct Bucket {
        let tokens: Double
        let instant: TimeInterval
    }

    private static let capacity = 20.0
    private static let refillPerSecond = 10.0
    private static let maximumBuckets = 1_024
    private var buckets: [String: Bucket] = [:]

    var retainedBucketCount: Int { buckets.count }

    mutating func canAdmit(pluginID: String, at instant: TimeInterval) -> Bool {
        guard instant.isFinite else { return false }
        buckets = buckets.filter { available($0.value, at: instant) < Self.capacity }
        guard buckets[pluginID] != nil || buckets.count < Self.maximumBuckets else { return false }
        return available(buckets[pluginID], at: instant) >= 1
    }

    mutating func recordSuccess(pluginID: String, at instant: TimeInterval) {
        guard instant.isFinite else { return }
        let previous = buckets[pluginID]
        buckets[pluginID] = Bucket(tokens: max(0, available(previous, at: instant) - 1),
                                   instant: max(instant, previous?.instant ?? instant))
    }

    private func available(_ bucket: Bucket?, at instant: TimeInterval) -> Double {
        guard let bucket else { return Self.capacity }
        let elapsed = max(0, instant - bucket.instant)
        return min(Self.capacity, bucket.tokens + elapsed * Self.refillPerSecond)
    }
}
