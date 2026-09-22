import Foundation

/// A clock boundary so Activity deadlines can be advanced without wall time in tests.
public nonisolated protocol ActivityClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

public nonisolated struct SystemActivityClock: ActivityClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let seconds = min(max(0, deadline.timeIntervalSinceNow), 86_400)
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Owns one wakeup task for all Activity deadlines. It never schedules
/// business work such as music polling or timer progress.
@MainActor
public final class ActivityScheduler {
    public nonisolated struct Configuration: Sendable {
        public var transientDuration: TimeInterval
        public var maximumTransientContinuousDuration: TimeInterval
        public var criticalMaximumDuration: TimeInterval
        public var ordinaryDebounce: TimeInterval
        public var minimumDwell: TimeInterval
        public var maximumQueuedAge: TimeInterval
        public var maximumQueuedNormal: Int
        public var minimumIntervalBySource: [ActivitySource: TimeInterval]

        public init(
            transientDuration: TimeInterval = 3,
            maximumTransientContinuousDuration: TimeInterval = 30,
            criticalMaximumDuration: TimeInterval = 5,
            ordinaryDebounce: TimeInterval = 0.12,
            minimumDwell: TimeInterval = 0.5,
            maximumQueuedAge: TimeInterval = 8,
            maximumQueuedNormal: Int = 8,
            minimumIntervalBySource: [ActivitySource: TimeInterval] = [:]
        ) {
            self.transientDuration = transientDuration
            self.maximumTransientContinuousDuration = maximumTransientContinuousDuration
            self.criticalMaximumDuration = criticalMaximumDuration
            self.ordinaryDebounce = ordinaryDebounce
            self.minimumDwell = minimumDwell
            self.maximumQueuedAge = maximumQueuedAge
            self.maximumQueuedNormal = maximumQueuedNormal
            self.minimumIntervalBySource = minimumIntervalBySource
        }

        public static var immediate: Self {
            Self(ordinaryDebounce: 0, minimumDwell: 0)
        }
    }

    public let configuration: Configuration
    public let clock: any ActivityClock
    private var wakeTask: Task<Void, Never>?
    private var armedDeadline: Date?
    private var generation = 0

    public init(clock: any ActivityClock = SystemActivityClock(), configuration: Configuration = .init()) {
        self.clock = clock
        self.configuration = configuration
    }

    public func arm(at deadline: Date?, wake: @escaping @MainActor () -> Void) {
        if deadline == armedDeadline { return }
        wakeTask?.cancel()
        armedDeadline = deadline
        generation &+= 1
        guard let deadline else { wakeTask = nil; return }
        let expected = generation
        let clock = self.clock
        wakeTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == expected else { return }
            self.armedDeadline = nil
            wake()
        }
    }

    public func cancel() {
        arm(at: nil, wake: {})
    }

    deinit { wakeTask?.cancel() }
}
