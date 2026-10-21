import Foundation
import OSLog

/// Maps event-driven IOKit battery snapshots into one semantic Activity. A
/// category change ends the previous admission before reusing the fixed ID,
/// because ActivityManager intentionally rejects lifecycle-policy mutation.
@MainActor
public final class BatteryActivityProvider {
    public nonisolated static let activityID = "builtin.battery"
    public nonisolated static let source = ActivitySource(kind: .builtIn, identifier: "battery")
    public nonisolated static let presentationDuration: TimeInterval = 3
    /// Power-source notifications receive one immediate read and one short
    /// confirmation read. The confirmation catches IOKit snapshots that settle
    /// just after the notification without delaying the first response.
    public nonisolated static let defaultDebounceNanoseconds: UInt64 = 250_000_000

    nonisolated enum Classification: Equatable, Sendable {
        case charging
        case low
        case critical
    }

    private let service: any BatteryService
    private let manager: ActivityManager
    private let debounceNanoseconds: UInt64
    private let now: () -> Date
    private var observation: (any BatteryObservation)?
    private var pendingRefresh: Task<Void, Never>?
    private var classification: Classification?
    private var lastState: BatteryState?
    private let logger = Logger(subsystem: "DynamicIsland", category: "BatteryActivityProvider")

    public init(
        service: any BatteryService,
        manager: ActivityManager,
        debounceNanoseconds: UInt64 = BatteryActivityProvider.defaultDebounceNanoseconds,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.manager = manager
        self.debounceNanoseconds = debounceNanoseconds
        self.now = now

        do {
            observation = try service.observeChanges { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
        } catch {
            logger.error("Failed to observe battery state: \(String(describing: error), privacy: .public)")
        }
        refresh(isInitial: true)
    }

    deinit {
        pendingRefresh?.cancel()
        observation?.cancel()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        refresh(isInitial: false)

        let delay = debounceNanoseconds
        guard delay > 0 else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.refresh(isInitial: false)
        }
    }

    private func refresh(isInitial: Bool) {
        let state: BatteryState?
        do {
            state = try service.currentState()
        } catch {
            logger.error("Failed to read battery state: \(String(describing: error), privacy: .public)")
            return
        }
        guard state != lastState else { return }

        let previous = classification
        let next = state.flatMap { Self.classify($0, previous: previous) }
        lastState = state

        if next != previous {
            endExistingActivity()
            classification = next
            guard let state, let next,
                  !isInitial || next != .charging else { return }
            publishNew(state: state, classification: next)
            return
        }

        guard let state, let next,
              let existing = manager.activity(id: Self.activityID) else { return }
        updateExisting(existing, state: state, classification: next)
    }

    private func publishNew(state: BatteryState, classification: Classification) {
        do {
            try manager.publish(Self.makeActivity(
                for: state,
                classification: classification,
                createdAt: now()
            ))
        } catch {
            logger.error("Failed to publish Battery Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateExisting(
        _ existing: IslandActivity,
        state: BatteryState,
        classification: Classification
    ) {
        var updated = Self.makeActivity(
            for: state,
            classification: classification,
            createdAt: existing.createdAt
        )
        // Data updates do not extend the original transient presentation.
        updated.expiresAt = existing.expiresAt
        do {
            try manager.update(updated)
        } catch ActivityManagerError.notFound {
            // A transient may expire between the lookup and update. Remaining
            // in the same category must not show it again for every percent.
        } catch ActivityManagerError.expired {
            // The original transient reached its hard expiry.
        } catch {
            logger.error("Failed to update Battery Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func endExistingActivity() {
        guard manager.activity(id: Self.activityID) != nil else { return }
        do {
            try manager.end(id: Self.activityID, source: Self.source)
        } catch ActivityManagerError.notFound {
            return
        } catch {
            logger.error("Failed to end Battery Activity: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func classify(
        _ state: BatteryState,
        previous: Classification?
    ) -> Classification? {
        guard state.powerSource == .battery else {
            // The AC power-source bit changes before `isCharging` on some Macs.
            // Treat a non-full external-power state as charging so plug-in
            // feedback is not held back while that secondary flag catches up.
            return !state.isCharged ? .charging : nil
        }

        if previous == .critical, state.level < 0.12 { return .critical }
        if state.level <= 0.10 { return .critical }
        if previous == .low, state.level < 0.22 { return .low }
        if state.level <= 0.20 { return .low }
        return nil
    }

    /// Deterministic data factory shared with tests and the screen matrix.
    nonisolated static func makeActivity(
        for state: BatteryState,
        classification: Classification,
        createdAt: Date
    ) -> IslandActivity {
        let percentage = "\(Int((state.level * 100).rounded()))%"
        let title: String
        let subtitle: String
        let symbolName: String
        let statusColor: IslandSemanticColorToken
        let priority: ActivityPriority
        let policy: ActivityLifecycle.Policy

        switch classification {
        case .charging:
            title = "正在充电"
            subtitle = "当前电量 \(percentage)"
            symbolName = "battery.100percent.bolt"
            statusColor = .success
            // Plug-in feedback must not wait behind a three-second normal
            // transient (for example, volume feedback) before it can appear.
            priority = .important
            policy = .transient
        case .low:
            title = "电量偏低"
            subtitle = "剩余电量 \(percentage)"
            symbolName = "battery.25percent"
            statusColor = .warning
            priority = .defaultForBuiltIn(.batteryLow)
            policy = .transient
        case .critical:
            title = "电量严重不足"
            subtitle = "剩余电量 \(percentage)，请尽快充电"
            symbolName = "battery.0percent"
            statusColor = .danger
            priority = .defaultForBuiltIn(.batteryCritical)
            policy = .critical
        }

        let compact: IslandNode = .hStack(.init([
            .text(.init(title)),
            .spacer(.init()),
            .text(.init(percentage, color: statusColor)),
            .progress(.init(state.level, style: .battery, color: statusColor))
        ]))
        let expanded: IslandNode = .vStack(.init([
            .hStack(.init([
                .text(.init(title)),
                .spacer(.init()),
                .text(.init(percentage, color: statusColor)),
                .progress(.init(state.level, style: .battery, color: statusColor))
            ])),
            .progress(.init(state.level, color: statusColor))
        ]))

        return IslandActivity(
            id: Self.activityID,
            source: Self.source,
            priority: priority,
            lifecycle: ActivityLifecycle(policy: policy),
            presentation: ActivityPresentation(
                title: title,
                subtitle: subtitle,
                symbolName: symbolName,
                progress: state.level,
                minimal: .icon(.init(symbolName)),
                compact: compact,
                expanded: expanded,
                showsCompact: true
            ),
            createdAt: createdAt,
            expiresAt: policy == .transient
                ? createdAt.addingTimeInterval(Self.presentationDuration)
                : nil
        )
    }
}
