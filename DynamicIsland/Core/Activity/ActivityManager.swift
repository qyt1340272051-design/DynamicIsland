import Combine
import Foundation
import OSLog

public enum ActivityManagerError: Error, Equatable {
    case invalidIdentifier
    case invalidInitialState
    case sourceMismatch
    case policyMismatch
    case invalidDuration
    case notPresentedTransient
    case notFound
    case expired
    case disabledSource
    case quotaExceeded
    case invalidToolPolicy
}

/// Host-owned identity for one admission of an Activity ID. An update keeps
/// the token; ending and publishing the same ID creates a different token.
public nonisolated struct ActivityInstanceToken: Equatable, Hashable, Sendable {
    fileprivate let value: UUID

    fileprivate init() { value = UUID() }
}

/// The Activity and its identity must be captured together by an interactive
/// view. Looking up a token later by ID could authorize a stale button.
public nonisolated struct ActivitySnapshot: Equatable, Sendable {
    public let activity: IslandActivity
    public let instanceToken: ActivityInstanceToken
}

/// A read-only inventory used by engine stress tests to catch retained
/// per-Activity scheduling state after an event has ended.
nonisolated struct ActivityManagerDiagnostics: Equatable, Sendable {
    let activityCount: Int
    let instanceTokenCount: Int
    let displayDeadlineCount: Int
    let firstPresentedCount: Int
    let rateLimitedSourceCount: Int
    let scheduledWakeDeadline: Date?
}

/// The sole mutable boundary for Activity data and presentation state.
@MainActor
public final class ActivityManager: ObservableObject {
    /// The Host supplies its actual presentation mode; plugin data cannot
    /// expand the island or choose an expanded surface.
    public nonisolated enum PresentationContext: Equatable, Sendable {
        case compact
        case expanded
    }

    @Published public private(set) var current: IslandActivity?
    @Published public private(set) var currentSnapshot: ActivitySnapshot?
    @Published public private(set) var toolSnapshots: [ActivitySnapshot] = []
    @Published public private(set) var selectedToolSnapshot: ActivitySnapshot?

    private nonisolated struct ToolSelection: Equatable {
        let id: String
        let source: ActivitySource
        let instanceToken: ActivityInstanceToken

        init(_ snapshot: ActivitySnapshot) {
            id = snapshot.activity.id
            source = snapshot.activity.source
            instanceToken = snapshot.instanceToken
        }
    }

    private var activities: [String: IslandActivity] = [:]
    private var instanceTokens: [String: ActivityInstanceToken] = [:]
    private var selectedTool: ToolSelection?
    private var presentationContext: PresentationContext = .expanded
    private var displayDeadlines: [String: Date] = [:]
    private var firstPresentedAt: [String: Date] = [:]
    private var currentSince: Date?
    private var ordinaryDebounceUntil: Date?
    private var lastPresentedAt: [ActivitySource: Date] = [:]
    private var requiresPluginActivation = false
    private var enabledPluginSources: Set<ActivitySource> = []
    private let logger = Logger(subsystem: "DynamicIsland", category: "ActivityManager")
    private let scheduler: ActivityScheduler

    public init(clock: any ActivityClock = SystemActivityClock(), configuration: ActivityScheduler.Configuration = .init()) {
        scheduler = ActivityScheduler(clock: clock, configuration: configuration)
    }

    public func activity(id: String) -> IslandActivity? { activities[id] }

    /// Change candidate eligibility and clear a folded user choice in one
    /// transaction. Expanded remains the default for existing Core callers.
    public func setPresentationContext(_ context: PresentationContext) {
        presentationContext = context
        if context == .compact { selectedTool = nil }
        reconcile()
    }

    /// Only a Host user interaction can select a tool. Capture the original
    /// snapshot in the chooser; never resolve a replacement token by ID.
    /// Acceptance retains the choice while a higher-priority status is shown.
    @discardableResult
    public func selectTool(_ snapshot: ActivitySnapshot) -> Bool {
        guard presentationContext == .expanded else { return false }
        reconcile()
        let selection = ToolSelection(snapshot)
        guard toolSnapshots.contains(where: { ToolSelection($0) == selection }) else { return false }
        selectedTool = selection
        reconcile(userSelection: selection)
        return true
    }

    public func clearToolSelection() {
        selectedTool = nil
        reconcile()
    }

    func activityCount(for source: ActivitySource) -> Int {
        activities.values.filter { $0.source == source }.count
    }

    var diagnostics: ActivityManagerDiagnostics {
        ActivityManagerDiagnostics(
            activityCount: activities.count,
            instanceTokenCount: instanceTokens.count,
            displayDeadlineCount: displayDeadlines.count,
            firstPresentedCount: firstPresentedAt.count,
            rateLimitedSourceCount: lastPresentedAt.count,
            scheduledWakeDeadline: scheduler.scheduledWakeDeadline
        )
    }

    public func publish(_ activity: IslandActivity) throws {
        try validateIdentity(activity)
        reconcile()
        if activities[activity.id] != nil {
            try update(activity)
            return
        }
        guard activity.lifecycle.state == .queued else { throw ActivityManagerError.invalidInitialState }
        guard !activity.isExpired(at: scheduler.clock.now()) else { throw ActivityManagerError.expired }
        let admitted = IslandActivity(
            id: activity.id,
            source: activity.source,
            priority: activity.priority,
            lifecycle: activity.lifecycle,
            presentation: activity.presentation,
            createdAt: scheduler.clock.now(),
            expiresAt: activity.expiresAt,
            actions: activity.actions
        )
        activities[admitted.id] = admitted
        instanceTokens[admitted.id] = ActivityInstanceToken()
        log(admitted, from: nil, to: .queued, reason: "publish")
        reconcile()
    }

    public func update(_ activity: IslandActivity) throws {
        try validateIdentity(activity)
        reconcile()
        guard var stored = activities[activity.id] else { throw ActivityManagerError.notFound }
        guard stored.source == activity.source else { throw ActivityManagerError.sourceMismatch }
        guard stored.lifecycle.policy == activity.lifecycle.policy else { throw ActivityManagerError.policyMismatch }
        if activity.isExpired(at: scheduler.clock.now()) {
            expire(id: activity.id, reason: "updateExpired")
            reconcile()
            throw ActivityManagerError.expired
        }
        stored.priority = activity.priority
        stored.presentation = activity.presentation
        stored.expiresAt = activity.expiresAt
        stored.actions = activity.actions
        activities[activity.id] = stored
        log(stored, from: stored.lifecycle.state, to: stored.lifecycle.state, reason: "update")
        reconcile()
    }

    public func dismiss(id: String, source: ActivitySource) throws {
        try transition(id: id, source: source, event: .dismiss, reason: "dismiss")
    }

    public func end(id: String, source: ActivitySource) throws {
        try transition(id: id, source: source, event: .sourceEnd, reason: "sourceEnd")
    }

    /// Host lifecycle cleanup includes queued, background, and dismissed
    /// activities, and reconciles the visible island only once after removal.
    public func endAll(source: ActivitySource) {
        for id in activities.keys.sorted() {
            guard let activity = activities[id], activity.source == source else { continue }
            log(activity, from: activity.lifecycle.state, to: .ended, reason: "sourceStopped")
            remove(id: id)
        }
        lastPresentedAt.removeValue(forKey: source)
        reconcile()
    }

    /// Enabled by the production plugin lifecycle boundary. Standalone engine
    /// fixtures and the DEBUG provider can still exercise synthetic sources.
    func requirePluginActivation() {
        requiresPluginActivation = true
    }

    func setPluginSourceEnabled(_ enabled: Bool, for source: ActivitySource) {
        guard source.kind == .plugin else { return }
        if enabled { enabledPluginSources.insert(source) }
        else {
            enabledPluginSources.remove(source)
            if selectedTool?.source == source { selectedTool = nil }
        }
        reconcile()
    }

    /// Host-only signal for ongoing user interaction such as volume dragging.
    /// Each renewal is capped to the normal transient duration, and the total
    /// continuous display cannot exceed the configured maximum.
    public func renewTransientPresentation(id: String, source: ActivitySource, by requestedDuration: TimeInterval? = nil) throws {
        reconcile()
        guard let activity = activities[id] else { throw ActivityManagerError.notFound }
        guard activity.source == source else { throw ActivityManagerError.sourceMismatch }
        guard current?.id == id, activity.lifecycle.state == .presented,
              activity.lifecycle.policy == .transient,
              let first = firstPresentedAt[id], let existing = displayDeadlines[id] else {
            throw ActivityManagerError.notPresentedTransient
        }
        if let requestedDuration, (!requestedDuration.isFinite || requestedDuration <= 0) {
            throw ActivityManagerError.invalidDuration
        }
        let now = scheduler.clock.now()
        let ordinary = positiveDuration(scheduler.configuration.transientDuration)
        let maximum = max(ordinary, positiveDuration(scheduler.configuration.maximumTransientContinuousDuration))
        let interval = min(requestedDuration ?? ordinary, ordinary)
        let latest = first.addingTimeInterval(maximum)
        displayDeadlines[id] = min(latest, max(existing, now.addingTimeInterval(interval)))
        log(activity, from: .presented, to: .presented, reason: "renewPresentation")
        armNextWake(rateDeadline: nil)
    }

    /// Deterministic test boundary. Live deadlines also call this through the scheduler.
    public func processDeadlines() { reconcile() }

    private func validateIdentity(_ activity: IslandActivity) throws {
        guard !activity.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !activity.source.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActivityManagerError.invalidIdentifier
        }
        if activity.isTool, activity.lifecycle.policy != .persistent, activity.lifecycle.policy != .progress {
            throw ActivityManagerError.invalidToolPolicy
        }
        if !activity.isTool, activity.presentation.compactPolicy != nil {
            throw ActivityManagerError.invalidToolPolicy
        }
        if activity.source.kind == .plugin, requiresPluginActivation,
           !enabledPluginSources.contains(activity.source) {
            throw ActivityManagerError.disabledSource
        }
    }

    private func transition(id: String, source: ActivitySource, event: ActivityLifecycle.Event, reason: String) throws {
        reconcile()
        guard var stored = activities[id] else { throw ActivityManagerError.notFound }
        guard stored.source == source else { throw ActivityManagerError.sourceMismatch }
        let old = stored.lifecycle.state
        stored.lifecycle = try stored.lifecycle.applying(event)
        log(stored, from: old, to: stored.lifecycle.state, reason: reason)
        if stored.lifecycle.isTerminal { remove(id: id) }
        else { activities[id] = stored }
        reconcile()
    }

    private func remove(id: String) {
        if selectedTool?.id == id { selectedTool = nil }
        activities.removeValue(forKey: id)
        instanceTokens.removeValue(forKey: id)
        displayDeadlines.removeValue(forKey: id)
        firstPresentedAt.removeValue(forKey: id)
    }

    private func expire(id: String, reason: String) {
        guard var stored = activities[id] else { return }
        let previous = stored.lifecycle.state
        do {
            stored.lifecycle = try stored.lifecycle.applying(.expire)
            log(stored, from: previous, to: .ended, reason: reason)
            remove(id: id)
        } catch {
            logger.error("Invalid expiry transition for id=\(id, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    private func expireDue() {
        let now = scheduler.clock.now()
        for id in activities.keys.sorted() {
            guard let activity = activities[id] else { continue }
            if activity.isExpired(at: now) {
                expire(id: id, reason: "expiresAt")
            } else if let deadline = displayDeadlines[id], deadline <= now {
                if activity.lifecycle.policy == .critical {
                    do {
                        var hidden = activity
                        hidden.lifecycle = try hidden.lifecycle.applying(.dismiss)
                        activities[id] = hidden
                        displayDeadlines.removeValue(forKey: id)
                        firstPresentedAt.removeValue(forKey: id)
                        log(hidden, from: activity.lifecycle.state, to: .dismissed, reason: "criticalMaximumDuration")
                    } catch {
                        logger.error("Invalid critical timeout for id=\(id, privacy: .private): \(String(describing: error), privacy: .public)")
                    }
                } else {
                    expire(id: id, reason: "displayDuration")
                }
            } else if activity.lifecycle.state == .queued,
                      activity.priority == .normal,
                      activity.lifecycle.policy == .transient,
                      now.timeIntervalSince(activity.createdAt) >= scheduler.configuration.maximumQueuedAge {
                expire(id: id, reason: "queueAge")
            }
        }
    }

    private func trimNormalQueue() {
        let limit = max(0, scheduler.configuration.maximumQueuedNormal)
        let pending = activities.values.filter {
            $0.lifecycle.state == .queued && $0.priority == .normal && $0.lifecycle.policy == .transient
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        for activity in pending.prefix(max(0, pending.count - limit)) {
            expire(id: activity.id, reason: "queueCapacity")
        }
    }

    private func refreshToolSnapshots(at now: Date) {
        let snapshots = activities.values.filter { activity in
            activity.isTool && !activity.isExpired(at: now)
                && [.queued, .presented, .background].contains(activity.lifecycle.state)
                && (!requiresPluginActivation || activity.source.kind != .plugin
                    || enabledPluginSources.contains(activity.source))
        }.sorted {
            ($0.source.kind.rawValue, $0.source.identifier, $0.id)
                < ($1.source.kind.rawValue, $1.source.identifier, $1.id)
        }.compactMap { activity in
            instanceTokens[activity.id].map { ActivitySnapshot(activity: activity, instanceToken: $0) }
        }
        let selected = selectedTool.flatMap { selection in
            snapshots.first { ToolSelection($0) == selection }
        }
        if selected == nil { selectedTool = nil }
        if toolSnapshots != snapshots { toolSnapshots = snapshots }
        if selectedToolSnapshot != selected { selectedToolSnapshot = selected }
    }

    private func reconcile(userSelection: ToolSelection? = nil) {
        expireDue()
        trimNormalQueue()
        let now = scheduler.clock.now()
        refreshToolSnapshots(at: now)
        defer { refreshToolSnapshots(at: now) }
        func isAutomaticCompactTool(_ activity: IslandActivity) -> Bool {
            presentationContext == .compact && activity.isTool
                && activity.presentation.compactPolicy == .automatic
                && activity.presentation.isCompactVisible
        }
        // Inventory contains only live, admitted tool instances. An opt-in
        // must not make a disabled or dismissed source eligible again.
        let eligibleToolIDs = Set(toolSnapshots.filter {
            $0.activity.id == selectedToolSnapshot?.activity.id || isAutomaticCompactTool($0.activity)
        }.map { $0.activity.id })
        let activeCurrent = current.flatMap { activities[$0.id] }.flatMap {
            $0.lifecycle.state == .presented ? $0 : nil
        }
        let eligibleCurrent = activeCurrent.flatMap { activity in
            !activity.isTool || eligibleToolIDs.contains(activity.id) ? activity : nil
        }
        let eligibleActivities = activities.values.filter {
            !$0.isTool || eligibleToolIDs.contains($0.id)
        }
        let ranked = ActivityQueue.ordered(eligibleActivities, at: now, currentlyPresentedID: eligibleCurrent?.id)
        let automaticTools = ranked.filter(isAutomaticCompactTool)
        var rateDeadline: Date?
        func isRateEligible(_ activity: IslandActivity) -> Bool {
            if activity.id == eligibleCurrent?.id || activity.priority == .critical { return true }
            let minimum = max(0, scheduler.configuration.minimumIntervalBySource[activity.source] ?? 0)
            guard minimum > 0, let last = lastPresentedAt[activity.source] else { return true }
            let eligibleAt = last.addingTimeInterval(minimum)
            if eligibleAt <= now { return true }
            rateDeadline = minDate(rateDeadline, eligibleAt)
            return false
        }
        let candidate: IslandActivity?
        if let eligibleCurrent, !eligibleCurrent.lifecycle.policy.isInterruptible {
            candidate = eligibleCurrent
        } else if selectedToolSnapshot != nil || !automaticTools.isEmpty {
            // A selected or explicitly opted-in compact tool wins over
            // ordinary persistent statuses, including music's current-peer
            // tie. Event statuses retain their priority and source limits.
            let blockingStatus = ranked.first { activity in
                !activity.isTool
                    && (activity.priority == .important || activity.priority == .critical
                        || (activity.priority == .normal && activity.lifecycle.policy == .transient))
                    && isRateEligible(activity)
            }
            if let blockingStatus { candidate = blockingStatus }
            else if let selected = selectedToolSnapshot,
                    userSelection == selectedTool || isRateEligible(selected.activity) {
                candidate = selected.activity
            } else if let automatic = automaticTools.first(where: isRateEligible) {
                candidate = automatic
            } else {
                candidate = ranked.first { !$0.isTool && isRateEligible($0) }
            }
        } else {
            candidate = ranked.first(where: isRateEligible)
        }
        guard let next = candidate else {
            if let activeCurrent, activeCurrent.isTool, var stored = activities[activeCurrent.id],
               let background = try? stored.lifecycle.applying(.moveToBackground) {
                stored.lifecycle = background
                activities[stored.id] = stored
                log(stored, from: .presented, to: .background, reason: "toolSelectionCleared")
            }
            setCurrent(nil)
            currentSince = nil
            ordinaryDebounceUntil = nil
            armNextWake(rateDeadline: rateDeadline)
            return
        }
        if activeCurrent?.id == next.id {
            setCurrent(next)
            ordinaryDebounceUntil = nil
            armNextWake(rateDeadline: rateDeadline)
            return
        }

        let urgent = next.priority == .critical || next.priority == .important
        let explicitToolSelection = next.isTool && userSelection != nil && userSelection == selectedTool
        if !urgent, !explicitToolSelection, eligibleCurrent != nil {
            if ordinaryDebounceUntil == nil {
                ordinaryDebounceUntil = now.addingTimeInterval(max(0, scheduler.configuration.ordinaryDebounce))
            }
            let dwellUntil = currentSince?.addingTimeInterval(max(0, scheduler.configuration.minimumDwell)) ?? now
            let allowedAt = max(ordinaryDebounceUntil ?? now, dwellUntil)
            if allowedAt > now {
                setCurrent(activeCurrent)
                armNextWake(rateDeadline: minDate(rateDeadline, allowedAt))
                return
            }
        }
        ordinaryDebounceUntil = nil
        var selected = next
        let previous = selected.lifecycle.state
        do { selected.lifecycle = try selected.lifecycle.applying(.present) }
        catch {
            logger.error("Invalid present transition for id=\(selected.id, privacy: .private): \(String(describing: error), privacy: .public)")
            armNextWake(rateDeadline: rateDeadline)
            return
        }
        if let old = activeCurrent, var stored = activities[old.id] {
            let previous = stored.lifecycle.state
            do { stored.lifecycle = try stored.lifecycle.applying(.moveToBackground) }
            catch {
                logger.error("Invalid background transition for id=\(old.id, privacy: .private): \(String(describing: error), privacy: .public)")
                armNextWake(rateDeadline: rateDeadline)
                return
            }
            activities[old.id] = stored
            log(stored, from: previous, to: stored.lifecycle.state, reason: "preempt")
        }
        activities[selected.id] = selected
        setCurrent(selected)
        currentSince = now
        // Only configured sources participate in rate limiting. Retaining
        // every one-off source here would make the dictionary grow forever
        // even after its Activity ended.
        if max(0, scheduler.configuration.minimumIntervalBySource[selected.source] ?? 0) > 0 {
            lastPresentedAt[selected.source] = now
        }
        if displayDeadlines[selected.id] == nil {
            firstPresentedAt[selected.id] = now
            switch selected.lifecycle.policy {
            case .transient:
                displayDeadlines[selected.id] = now.addingTimeInterval(positiveDuration(scheduler.configuration.transientDuration))
            case .critical:
                displayDeadlines[selected.id] = now.addingTimeInterval(positiveDuration(scheduler.configuration.criticalMaximumDuration))
            case .persistent, .progress:
                break
            }
        }
        log(selected, from: previous, to: .presented, reason: "select")
        armNextWake(rateDeadline: rateDeadline)
    }

    private func armNextWake(rateDeadline: Date?) {
        let now = scheduler.clock.now()
        var next = rateDeadline.flatMap { $0 > now ? $0 : nil }
        for activity in activities.values {
            if let expiry = activity.expiresAt, expiry > now { next = minDate(next, expiry) }
            if activity.lifecycle.state == .queued, activity.priority == .normal, activity.lifecycle.policy == .transient {
                let age = activity.createdAt.addingTimeInterval(scheduler.configuration.maximumQueuedAge)
                if age > now { next = minDate(next, age) }
            }
        }
        for deadline in displayDeadlines.values where deadline > now { next = minDate(next, deadline) }
        if let debounce = ordinaryDebounceUntil, debounce > now { next = minDate(next, debounce) }
        scheduler.arm(at: next) { [weak self] in self?.reconcile() }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date { lhs.map { min($0, rhs) } ?? rhs }

    private func positiveDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0.001
    }

    private func setCurrent(_ next: IslandActivity?) {
        let snapshot = next.flatMap { activity in
            instanceTokens[activity.id].map { ActivitySnapshot(activity: activity, instanceToken: $0) }
        }
        if currentSnapshot != snapshot { currentSnapshot = snapshot }
        if current != next { current = next }
    }

    /// Reconcile deadlines and check the exact Activity instance before an
    /// action can reach its source. The caller must also check its action list.
    func activeActionActivity(
        id: String,
        source: ActivitySource,
        instanceToken: ActivityInstanceToken
    ) -> IslandActivity? {
        reconcile()
        guard let activity = activities[id],
              activity.source == source,
              activity.lifecycle.state == .presented,
              currentSnapshot?.activity.id == id,
              currentSnapshot?.instanceToken == instanceToken,
              instanceTokens[id] == instanceToken,
              !activity.isExpired(at: scheduler.clock.now()) else { return nil }
        return activity
    }

    private func log(_ activity: IslandActivity, from: ActivityLifecycle.State?, to: ActivityLifecycle.State, reason: String) {
        logger.info("source=\(activity.source.identifier, privacy: .private) id=\(activity.id, privacy: .private) from=\(from?.rawValue ?? "none", privacy: .public) to=\(to.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }
}
