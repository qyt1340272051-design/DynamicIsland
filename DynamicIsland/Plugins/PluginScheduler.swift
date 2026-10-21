import Foundation

public nonisolated enum PluginSchedulerPolicy: String, Equatable, Sendable {
    case active
    case background
    case lowPower

    var minimumDelay: TimeInterval {
        switch self {
        case .active: 1
        case .background: 30
        case .lowPower: 60
        }
    }

    var coalescingQuantum: TimeInterval {
        switch self {
        case .active: 1
        case .background: 5
        case .lowPower: 15
        }
    }
}

public nonisolated enum PluginSchedulerError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments
    case quotaExceeded
    case inactiveExecution

    public var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .quotaExceeded: "quotaExceeded"
        case .inactiveExecution: "inactiveExecution"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid refresh scheduling arguments."
        case .quotaExceeded: "The Host refresh scheduling limit was reached."
        case .inactiveExecution: "This plugin execution is inactive."
        }
    }
}

public nonisolated struct PluginRefreshRequest: Equatable, Sendable {
    public let delayMilliseconds: Int

    public init(delayMilliseconds: Int) throws {
        guard (1_000...86_400_000).contains(delayMilliseconds) else {
            throw PluginSchedulerError.invalidArguments
        }
        self.delayMilliseconds = delayMilliseconds
    }

    static func parse(_ json: PluginBridgeJSON) throws -> Self {
        guard case .object(let fields) = json, fields.count == 1,
              case .number(let delay)? = fields["delayMs"], delay.isFinite,
              delay.rounded(.towardZero) == delay,
              (1_000...86_400_000).contains(delay) else {
            throw PluginSchedulerError.invalidArguments
        }
        return try Self(delayMilliseconds: Int(delay))
    }
}

public nonisolated struct PluginRefreshResponse: Equatable, Sendable {
    public let policy: PluginSchedulerPolicy

    public init(policy: PluginSchedulerPolicy) {
        self.policy = policy
    }
}

/// One shared Host scheduler owns all plugin refresh deadlines. A refresh is a
/// one-shot admission: it never creates a VM timer, polls an idle VM, or replays
/// missed ticks. Scheduling another refresh requires another admitted request.
@MainActor
public final class PluginScheduler {
    public nonisolated struct Snapshot: Equatable, Sendable {
        public let policy: PluginSchedulerPolicy
        public let pendingCount: Int
        public let nextDeadline: TimeInterval?
        public let wakeCount: UInt64
        public let timerCount: Int
    }

    private nonisolated struct Pending: Sendable {
        let id: UUID
        let pluginID: String
        var deadline: TimeInterval
        let admission: PluginResourceAdmission
        let cancellationID: UUID
        let delivery: PluginRefreshDelivery
    }

    private let clock: @MainActor () -> TimeInterval
    private let automaticScheduling: Bool
    private var policy: PluginSchedulerPolicy
    private var pending: [String: Pending] = [:]
    private var timerTask: Task<Void, Never>?
    private var timerDeadline: TimeInterval?
    private var timerGeneration: UUID?
    private var lastInstant: TimeInterval = 0
    private var wakeCount: UInt64 = 0
    private var stopped = false

    public init(
        policy: PluginSchedulerPolicy = .active,
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticScheduling: Bool = true
    ) {
        self.policy = policy
        self.clock = clock
        self.automaticScheduling = automaticScheduling
    }

    deinit {
        timerTask?.cancel()
        for entry in pending.values {
            entry.admission.unregister(entry.cancellationID)
            entry.delivery.finish(.failure(.inactiveExecution))
        }
    }

    public var snapshot: Snapshot {
        Snapshot(policy: policy, pendingCount: pending.count,
                 nextDeadline: pending.values.map(\.deadline).min(), wakeCount: wakeCount,
                 timerCount: timerTask == nil ? 0 : 1)
    }

    /// Registers a bounded deadline and returns immediately. Completion runs
    /// once inside a short execution gate. It must enqueue the bridge reply;
    /// it must not reenter scheduling, revoke admission, or block this callback.
    public func schedule(
        request: PluginRefreshRequest,
        pluginID: String,
        admission: PluginResourceAdmission,
        completion: @escaping @Sendable (Result<PluginRefreshResponse, PluginSchedulerError>) -> Void
    ) throws {
        guard !stopped else { throw PluginSchedulerError.inactiveExecution }
        guard !pluginID.isEmpty, pluginID.utf8.count <= PluginManifest.Limits.maxPluginIDBytes,
              let now = instant() else { throw PluginSchedulerError.invalidArguments }
        do {
            try admission.perform {
                guard pending[pluginID] == nil, pending.count < 128 else {
                    throw PluginSchedulerError.quotaExceeded
                }
            }
        } catch {
            throw Self.map(error)
        }

        let id = UUID()
        let delivery = PluginRefreshDelivery(completion: completion)
        let cancellationID: UUID
        do {
            cancellationID = try admission.registerCancellation { [weak self] in
                // Close the delivery gate synchronously. The MainActor removal
                // may wait, but an already due entry can no longer succeed.
                delivery.cancel()
                Task { @MainActor [weak self] in
                    self?.cancel(pluginID: pluginID, id: id)
                }
            }
        } catch {
            throw Self.map(error)
        }
        let seconds = TimeInterval(request.delayMilliseconds) / 1_000
        let deadline = coalesced(now + max(seconds, policy.minimumDelay), policy: policy)
        pending[pluginID] = Pending(id: id, pluginID: pluginID, deadline: deadline,
                                   admission: admission, cancellationID: cancellationID,
                                   delivery: delivery)
        armTimer()
    }

    /// Entering a more restrictive policy postpones existing requests from the
    /// policy-change instant. Leaving it keeps deadlines unchanged so overdue
    /// background work cannot be accelerated into an immediate catch-up burst.
    public func setPolicy(_ newPolicy: PluginSchedulerPolicy) {
        guard !stopped else { return }
        guard newPolicy != policy else { return }
        let previous = policy
        policy = newPolicy
        if newPolicy.minimumDelay > previous.minimumDelay, let now = instant() {
            for pluginID in Array(pending.keys) {
                guard var entry = pending[pluginID] else { continue }
                entry.deadline = coalesced(max(entry.deadline, now + newPolicy.minimumDelay),
                                           policy: newPolicy)
                pending[pluginID] = entry
            }
        }
        armTimer()
    }

    /// The injected clock and this pump let tests advance time without sleeping
    /// or installing timers. Each due request is removed before its callback.
    func processDue() {
        guard !stopped else { return }
        guard let now = instant() else { return }
        let due = pending.values.filter { $0.deadline <= now }
            .sorted { $0.deadline == $1.deadline
                ? $0.pluginID < $1.pluginID : $0.deadline < $1.deadline }
        if !due.isEmpty { wakeCount &+= 1 }
        for entry in due {
            finish(entry, result: .success(PluginRefreshResponse(policy: policy)))
        }
        armTimer()
    }

    /// Terminal Host teardown. No pending request can be replayed by an old
    /// timer or revived admission, and this instance rejects new schedules.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        timerTask?.cancel()
        timerTask = nil
        timerDeadline = nil
        timerGeneration = nil
        let entries = Array(pending.values)
        pending.removeAll()
        for entry in entries {
            entry.admission.unregister(entry.cancellationID)
            entry.delivery.finish(.failure(.inactiveExecution))
        }
    }

    private func cancel(pluginID: String, id: UUID) {
        guard let entry = pending[pluginID], entry.id == id else { return }
        finish(entry, result: .failure(.inactiveExecution))
        armTimer()
    }

    private func finish(_ entry: Pending,
                        result: Result<PluginRefreshResponse, PluginSchedulerError>) {
        guard pending[entry.pluginID]?.id == entry.id else { return }
        pending.removeValue(forKey: entry.pluginID)
        entry.admission.unregister(entry.cancellationID)
        do {
            try entry.admission.perform { entry.delivery.finish(result) }
        } catch {
            entry.delivery.finish(.failure(.inactiveExecution))
        }
    }

    private func instant() -> TimeInterval? {
        let value = clock()
        guard value.isFinite, value >= 0 else { return nil }
        // Production uptime is monotonic. A faulty injected clock cannot make
        // a previously observed instant travel backwards and defer work again.
        lastInstant = max(lastInstant, value)
        return lastInstant
    }

    private func coalesced(_ deadline: TimeInterval, policy: PluginSchedulerPolicy) -> TimeInterval {
        ceil(deadline / policy.coalescingQuantum) * policy.coalescingQuantum
    }

    private func armTimer() {
        guard automaticScheduling, !stopped else { return }
        let deadline = pending.values.map(\.deadline).min()
        if timerTask != nil, timerDeadline == deadline { return }
        timerTask?.cancel()
        timerTask = nil
        timerDeadline = nil
        timerGeneration = nil
        guard let deadline, let now = instant() else { return }
        let generation = UUID()
        timerGeneration = generation
        timerDeadline = deadline
        // A zero interval only occurs for a deadline made due while MainActor
        // was occupied. It delivers one request, never recurring missed ticks.
        let interval = min(86_415, max(0, deadline - now))
        let nanoseconds = UInt64((interval * 1_000_000_000).rounded(.up))
        timerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timerFired(generation: generation)
        }
    }

    private func timerFired(generation: UUID) {
        guard timerGeneration == generation else { return }
        timerTask = nil
        timerDeadline = nil
        timerGeneration = nil
        processDue()
    }

    private nonisolated static func map(_ error: Error) -> PluginSchedulerError {
        if let error = error as? PluginSchedulerError { return error }
        return .inactiveExecution
    }
}

/// Cancellation is callable off the main actor and closes success delivery
/// before its queued Host cleanup. Completion holds only this short local gate.
private nonisolated final class PluginRefreshDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: @Sendable (Result<PluginRefreshResponse, PluginSchedulerError>) -> Void
    private var canceled = false
    private var finished = false

    init(completion: @escaping @Sendable (Result<PluginRefreshResponse, PluginSchedulerError>) -> Void) {
        self.completion = completion
    }

    func cancel() {
        lock.lock(); canceled = true; lock.unlock()
    }

    func finish(_ result: Result<PluginRefreshResponse, PluginSchedulerError>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        completion(canceled ? .failure(.inactiveExecution) : result)
    }
}
