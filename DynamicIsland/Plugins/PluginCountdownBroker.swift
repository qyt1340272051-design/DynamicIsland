import Foundation

/// Host-issued identity for one validated package load. Execution sessions may
/// change during suspension without changing this owner; a replacement may not.
nonisolated struct PluginCountdownOwner: Equatable, Hashable, Sendable {
    let pluginID: String
    fileprivate let loadEpoch: UUID

    fileprivate init(pluginID: String) {
        self.pluginID = pluginID
        loadEpoch = UUID()
    }
}

nonisolated struct PluginCountdownGeneration: Equatable, Hashable, Sendable {
    private let value: UUID
    fileprivate init() { value = UUID() }
    var rawValue: String { value.uuidString.lowercased() }

    init?(rawValue: String) {
        guard let value = UUID(uuidString: rawValue), rawValue == value.uuidString.lowercased() else { return nil }
        self.value = value
    }
}

nonisolated enum PluginCountdownState: String, Equatable, Sendable {
    case running, paused, completed
}

nonisolated struct PluginCountdownSnapshot: Equatable, Sendable {
    let id: String
    let generation: PluginCountdownGeneration
    let state: PluginCountdownState
    let durationMilliseconds: Int
    let remaining: Duration
}

nonisolated struct PluginCountdownCompletion: Equatable, Sendable {
    let owner: PluginCountdownOwner
    let snapshot: PluginCountdownSnapshot
    var id: String { snapshot.id }
    var generation: PluginCountdownGeneration { snapshot.generation }
}

nonisolated enum PluginCountdownError: Error, Equatable, Sendable {
    case invalidArguments
    case quotaExceeded
    case ownerAlreadyRegistered
    case inactiveOwner
    case countdownNotFound
    case staleGeneration
    case invalidState
}

/// Host records only: no JS registration, execution credential or tick lives in
/// this store. Future bridge integration must authorize start/resume separately.
@MainActor
final class PluginCountdownBroker {
    typealias Clock = @MainActor @Sendable () -> Duration
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Completion = @MainActor @Sendable (PluginCountdownCompletion) -> Void

    nonisolated struct Diagnostics: Equatable, Sendable {
        let ownerCount: Int
        let recordCount: Int
        let runningCount: Int
        let pausedCount: Int
        let completedCount: Int
        let alarmCount: Int
        let nextDeadline: Duration?
    }

    private struct OwnerEntry {
        let owner: PluginCountdownOwner
        var isActive = true
    }

    private struct Record {
        let owner: PluginCountdownOwner
        let id: String
        let generation: PluginCountdownGeneration
        let durationMilliseconds: Int
        var state: PluginCountdownState
        var remaining: Duration
        var deadline: Duration?
        var completionAcknowledged = false
        var offeredObserver: UUID?

        func snapshot(at instant: Duration) -> PluginCountdownSnapshot {
            let remaining = deadline.map { max(.zero, $0 - instant) } ?? self.remaining
            return .init(id: id, generation: generation, state: state,
                         durationMilliseconds: durationMilliseconds, remaining: remaining)
        }
    }

    private struct Observer {
        let owner: PluginCountdownOwner
        let token: UUID
        let handler: Completion
    }

    private let clock: Clock
    private let sleep: Sleep
    private let automaticScheduling: Bool
    private var owners: [String: OwnerEntry] = [:]
    private var records: [String: Record] = [:]
    private var observers: [String: Observer] = [:]
    private var lastInstant: Duration = .zero
    private var alarmTask: Task<Void, Never>?
    private var alarmDeadline: Duration?
    private var alarmGeneration: UUID?
    private var isShutdown = false

    init(clock: Clock? = nil, automaticScheduling: Bool = true,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .continuous) }) {
        let origin = ContinuousClock.now
        self.clock = clock ?? { origin.duration(to: ContinuousClock.now) }
        self.sleep = sleep
        self.automaticScheduling = automaticScheduling
    }

    deinit { alarmTask?.cancel() }

    var diagnostics: Diagnostics {
        .init(ownerCount: owners.count, recordCount: records.count,
              runningCount: records.values.filter { $0.state == .running }.count,
              pausedCount: records.values.filter { $0.state == .paused }.count,
              completedCount: records.values.filter { $0.state == .completed }.count,
              alarmCount: alarmTask == nil ? 0 : 1, nextDeadline: nextDeadline)
    }

    /// Only the Host load boundary creates owners. No caller-supplied epoch is
    /// accepted, and duplicate registration cannot displace a current owner.
    func registerOwner(pluginID: String) throws -> PluginCountdownOwner {
        guard !isShutdown else { throw PluginCountdownError.inactiveOwner }
        guard PluginManifest.isValidPluginID(pluginID) else { throw PluginCountdownError.invalidArguments }
        guard owners[pluginID] == nil else { throw PluginCountdownError.ownerAlreadyRegistered }
        guard owners.count < 128 else { throw PluginCountdownError.quotaExceeded }
        let owner = PluginCountdownOwner(pluginID: pluginID)
        owners[pluginID] = OwnerEntry(owner: owner)
        return owner
    }

    @discardableResult
    func replaceOwner(_ owner: PluginCountdownOwner) throws -> PluginCountdownOwner {
        try requireOwner(owner, active: false)
        let replacement = PluginCountdownOwner(pluginID: owner.pluginID)
        records.removeValue(forKey: owner.pluginID)
        observers.removeValue(forKey: owner.pluginID)
        owners[owner.pluginID] = OwnerEntry(owner: replacement)
        rescheduleAlarm()
        return replacement
    }

    func suspendOwner(_ owner: PluginCountdownOwner) throws {
        try requireOwner(owner, active: false)
        owners[owner.pluginID]?.isActive = false
        rescheduleAlarm()
    }

    /// Reconcile the retained continuous deadline only after this owner becomes
    /// active. An old VM's delivery lease is deliberately outside this store.
    func reactivateOwner(_ owner: PluginCountdownOwner) throws {
        try requireOwner(owner, active: false)
        let now = try instant()
        owners[owner.pluginID]?.isActive = true
        processDue(at: now)
    }

    func removeOwner(_ owner: PluginCountdownOwner) throws {
        try requireOwner(owner, active: false)
        records.removeValue(forKey: owner.pluginID)
        observers.removeValue(forKey: owner.pluginID)
        owners.removeValue(forKey: owner.pluginID)
        rescheduleAlarm()
    }

    /// Replacing a listener cannot change the business record. A completed
    /// record remains pending until an active owner has a current listener.
    @discardableResult
    func observeCompletions(owner: PluginCountdownOwner, handler: @escaping Completion) throws -> UUID {
        try requireOwner(owner, active: false)
        let now = try instant()
        let token = UUID()
        if var record = records[owner.pluginID], !record.completionAcknowledged {
            record.offeredObserver = nil
            records[owner.pluginID] = record
        }
        observers[owner.pluginID] = Observer(owner: owner, token: token, handler: handler)
        processDue(at: now)
        return token
    }

    func removeCompletionObserver(owner: PluginCountdownOwner, token: UUID) throws {
        try requireOwner(owner, active: false)
        guard observers[owner.pluginID]?.owner == owner, observers[owner.pluginID]?.token == token else { return }
        observers.removeValue(forKey: owner.pluginID)
        if var record = records[owner.pluginID], !record.completionAcknowledged,
           record.offeredObserver == token {
            record.offeredObserver = nil
            records[owner.pluginID] = record
        }
    }

    /// A Host offer is not a VM receipt. Only the current observer may ACK the
    /// exact completed generation after its receiver actually accepted it.
    @discardableResult
    func acknowledgeCompletion(owner: PluginCountdownOwner, id: String,
                               generation: PluginCountdownGeneration, observerToken: UUID) throws -> Bool {
        var record = try requireRecord(owner: owner, id: id, generation: generation)
        guard record.state == .completed else { throw PluginCountdownError.invalidState }
        guard !record.completionAcknowledged, record.offeredObserver == observerToken,
              observers[owner.pluginID]?.owner == owner,
              observers[owner.pluginID]?.token == observerToken else { return false }
        record.completionAcknowledged = true
        record.offeredObserver = nil
        records[owner.pluginID] = record
        return true
    }

    /// Queue rejection releases the offer without immediately invoking Host
    /// code again. A later get, pump, or observation can retry the completion.
    @discardableResult
    func releaseCompletionOffer(owner: PluginCountdownOwner, id: String,
                                generation: PluginCountdownGeneration, observerToken: UUID) throws -> Bool {
        var record = try requireRecord(owner: owner, id: id, generation: generation)
        guard !record.completionAcknowledged, record.offeredObserver == observerToken,
              observers[owner.pluginID]?.owner == owner,
              observers[owner.pluginID]?.token == observerToken else { return false }
        record.offeredObserver = nil
        records[owner.pluginID] = record
        return true
    }

    /// A genuine, subsequently authorized start may atomically restart the
    /// same local ID. A different local ID still requires an explicit stop.
    func start(owner: PluginCountdownOwner, id: String,
               durationMilliseconds: Int) throws -> PluginCountdownSnapshot {
        try requireOwner(owner)
        try Self.validateID(id)
        guard (1_000...86_400_000).contains(durationMilliseconds) else {
            throw PluginCountdownError.invalidArguments
        }
        if let current = records[owner.pluginID] {
            guard current.owner == owner, current.id == id else { throw PluginCountdownError.quotaExceeded }
        } else {
            guard records.count < 128 else { throw PluginCountdownError.quotaExceeded }
        }
        let now = try instant()
        let duration = Duration.milliseconds(durationMilliseconds)
        let record = Record(owner: owner, id: id, generation: .init(),
                            durationMilliseconds: durationMilliseconds, state: .running,
                            remaining: duration, deadline: now + duration)
        records[owner.pluginID] = record
        armAlarm(at: now)
        return record.snapshot(at: now)
    }

    func get(owner: PluginCountdownOwner, id: String) throws -> PluginCountdownSnapshot? {
        try requireOwner(owner)
        try Self.validateID(id)
        let now = try instant()
        processDue(at: now)
        // Completion callbacks may synchronously replace or remove this owner.
        try requireOwner(owner)
        guard let record = records[owner.pluginID], record.id == id else { return nil }
        return record.snapshot(at: try instant())
    }

    /// Rendering may project the deadline, but must not settle business state
    /// or synchronously call a VM observer during SwiftUI evaluation.
    func snapshotForDisplay(owner: PluginCountdownOwner, id: String,
                            generation: PluginCountdownGeneration) -> PluginCountdownSnapshot? {
        guard (try? requireOwner(owner)) != nil,
              let record = records[owner.pluginID], record.owner == owner,
              record.id == id, record.generation == generation,
              let now = try? instant() else { return nil }
        if record.state == .running, let deadline = record.deadline, deadline <= now {
            return .init(id: id, generation: generation, state: .completed,
                         durationMilliseconds: record.durationMilliseconds, remaining: .zero)
        }
        return record.snapshot(at: now)
    }

    func pause(owner: PluginCountdownOwner, id: String,
               generation: PluginCountdownGeneration) throws -> PluginCountdownSnapshot {
        let record = try requireRecord(owner: owner, id: id, generation: generation)
        let now = try instant()
        guard record.state == .running, let deadline = record.deadline else {
            throw PluginCountdownError.invalidState
        }
        guard deadline > now else {
            processDue(at: now)
            throw PluginCountdownError.invalidState
        }
        let paused = Record(owner: owner, id: id, generation: .init(),
                            durationMilliseconds: record.durationMilliseconds, state: .paused,
                            remaining: deadline - now, deadline: nil)
        records[owner.pluginID] = paused
        armAlarm(at: now)
        return paused.snapshot(at: now)
    }

    func resume(owner: PluginCountdownOwner, id: String,
                generation: PluginCountdownGeneration) throws -> PluginCountdownSnapshot {
        let record = try requireRecord(owner: owner, id: id, generation: generation)
        guard record.state == .paused, record.remaining > .zero else {
            throw PluginCountdownError.invalidState
        }
        let now = try instant()
        let resumed = Record(owner: owner, id: id, generation: .init(),
                             durationMilliseconds: record.durationMilliseconds, state: .running,
                             remaining: record.remaining, deadline: now + record.remaining)
        records[owner.pluginID] = resumed
        armAlarm(at: now)
        return resumed.snapshot(at: now)
    }

    func stop(owner: PluginCountdownOwner, id: String, generation: PluginCountdownGeneration) throws {
        _ = try requireRecord(owner: owner, id: id, generation: generation)
        records.removeValue(forKey: owner.pluginID)
        rescheduleAlarm()
    }

    /// Host execution teardown may clear business work without unregistering
    /// the current package owner or its independently managed observer scope.
    func clearRecord(owner: PluginCountdownOwner) throws {
        try requireOwner(owner)
        records.removeValue(forKey: owner.pluginID)
        rescheduleAlarm()
    }

    /// Manual deterministic pump; production uses the same path for its one
    /// nearest alarm. Suspended owners retain their unprocessed deadlines.
    func processDue() {
        guard !isShutdown, let now = try? instant() else { return }
        processDue(at: now)
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelAlarm()
        records.removeAll()
        owners.removeAll()
        observers.removeAll()
    }

    private var nextDeadline: Duration? {
        records.values.compactMap { record in
            guard owners[record.owner.pluginID]?.owner == record.owner,
                  owners[record.owner.pluginID]?.isActive == true,
                  record.state == .running else { return nil }
            return record.deadline
        }.min()
    }

    private func requireOwner(_ owner: PluginCountdownOwner, active: Bool = true) throws {
        guard !isShutdown, let entry = owners[owner.pluginID], entry.owner == owner,
              !active || entry.isActive else { throw PluginCountdownError.inactiveOwner }
    }

    private func requireRecord(owner: PluginCountdownOwner, id: String,
                               generation: PluginCountdownGeneration) throws -> Record {
        try requireOwner(owner)
        try Self.validateID(id)
        guard let record = records[owner.pluginID], record.id == id else {
            throw PluginCountdownError.countdownNotFound
        }
        guard record.owner == owner else { throw PluginCountdownError.inactiveOwner }
        guard record.generation == generation else { throw PluginCountdownError.staleGeneration }
        return record
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 80, id.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }) else { throw PluginCountdownError.invalidArguments }
    }

    private func instant() throws -> Duration {
        let value = clock()
        guard value >= .zero else { throw PluginCountdownError.invalidArguments }
        lastInstant = max(lastInstant, value)
        return lastInstant
    }

    private func processDue(at now: Duration) {
        for key in records.keys.sorted() {
            guard var record = records[key], record.state == .running,
                  owners[key]?.owner == record.owner, owners[key]?.isActive == true,
                  let deadline = record.deadline, deadline <= now else { continue }
            record.state = .completed
            record.remaining = .zero
            record.deadline = nil
            records[key] = record
        }
        armAlarm(at: now)
        let completions = records.values.filter {
            $0.state == .completed && !$0.completionAcknowledged && $0.offeredObserver == nil
        }.sorted { $0.owner.pluginID < $1.owner.pluginID }
        for candidate in completions {
            let key = candidate.owner.pluginID
            guard !isShutdown, var current = records[key],
                  current.owner == candidate.owner, current.generation == candidate.generation,
                  current.state == .completed, !current.completionAcknowledged, current.offeredObserver == nil,
                  owners[key]?.owner == candidate.owner, owners[key]?.isActive == true,
                  let observer = observers[key], observer.owner == candidate.owner else { continue }
            // Reserve before Host code so reentrant get/pump cannot duplicate
            // this in-flight offer. Only an explicit receiver ACK consumes it.
            current.offeredObserver = observer.token
            records[key] = current
            observer.handler(.init(owner: current.owner, snapshot: current.snapshot(at: now)))
        }
    }

    private func rescheduleAlarm() {
        guard let now = try? instant() else { cancelAlarm(); return }
        armAlarm(at: now)
    }

    private func armAlarm(at now: Duration) {
        guard automaticScheduling, !isShutdown, let deadline = nextDeadline else { cancelAlarm(); return }
        if alarmTask != nil, alarmDeadline == deadline { return }
        cancelAlarm()
        let generation = UUID()
        alarmGeneration = generation
        alarmDeadline = deadline
        let interval = max(.zero, deadline - now)
        let sleep = self.sleep
        alarmTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(interval) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.alarmFired(generation: generation)
        }
    }

    private func alarmFired(generation: UUID) {
        guard !isShutdown, alarmGeneration == generation else { return }
        alarmTask = nil
        alarmDeadline = nil
        alarmGeneration = nil
        processDue()
    }

    private func cancelAlarm() {
        alarmGeneration = nil
        alarmDeadline = nil
        alarmTask?.cancel()
        alarmTask = nil
    }
}
