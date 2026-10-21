import Combine
import Foundation
import OSLog

/// Turns semantic system-volume changes from `IslandViewModel` into one
/// short-lived Activity. The event boundary prevents music's own volume
/// controls from replacing the music Activity while a slider is being used.
@MainActor
public final class VolumeActivityProvider {
    public nonisolated static let activityID = "builtin.volume"
    public nonisolated static let source = ActivitySource(kind: .builtIn, identifier: "volume")
    public nonisolated static let presentationDuration: TimeInterval = 1.5
    public nonisolated static let defaultDebounceNanoseconds: UInt64 = 40_000_000

    private let manager: ActivityManager
    private let debounceNanoseconds: UInt64
    private let now: () -> Date
    private var observation: AnyCancellable?
    private var pendingPublication: Task<Void, Never>?
    private let logger = Logger(subsystem: "DynamicIsland", category: "VolumeActivityProvider")

    public init(
        viewModel: IslandViewModel,
        manager: ActivityManager,
        debounceNanoseconds: UInt64 = VolumeActivityProvider.defaultDebounceNanoseconds,
        now: @escaping () -> Date = Date.init
    ) {
        self.manager = manager
        self.debounceNanoseconds = debounceNanoseconds
        self.now = now
        observation = viewModel.$volumeActivityEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                self?.schedulePublication(of: event)
            }
    }

    private func schedulePublication(of event: VolumeActivityEvent) {
        pendingPublication?.cancel()
        let delay = debounceNanoseconds
        pendingPublication = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.publish(event)
        }
    }

    private func publish(_ event: VolumeActivityEvent) {
        do {
            try manager.publish(Self.makeActivity(for: event, createdAt: now()))
            if manager.current?.id == Self.activityID {
                try manager.renewTransientPresentation(
                    id: Self.activityID,
                    source: Self.source,
                    by: Self.presentationDuration
                )
            }
        } catch {
            logger.error("Failed to publish Volume Activity: \(String(describing: error), privacy: .public)")
        }
    }

    /// Internal deterministic factory shared with Host visual verification.
    /// Runtime callers still publish through the debounced event path above.
    nonisolated static func makeActivity(
        for event: VolumeActivityEvent,
        createdAt: Date
    ) -> IslandActivity {
        let level = normalized(event.volume)
        let percentage = "\(Int((level * 100).rounded()))%"
        let symbolName = symbolName(level: level, isMuted: event.isMuted)
        let compact: IslandNode = .hStack(.init([
            .icon(.init(symbolName)),
            .spacer(.init()),
            .text(.init(percentage))
        ]))
        let expanded: IslandNode = .vStack(.init([
            .hStack(.init([
                .icon(.init(symbolName)),
                .text(.init(event.isMuted ? "系统音量 · 已静音" : "系统音量")),
                .spacer(.init()),
                .text(.init(percentage))
            ])),
            .progress(.init(level))
        ]))
        return IslandActivity(
            id: Self.activityID,
            source: Self.source,
            priority: .defaultForBuiltIn(.volume),
            lifecycle: ActivityLifecycle(policy: .transient),
            presentation: ActivityPresentation(
                title: "系统音量",
                subtitle: event.isMuted ? "已静音 · \(percentage)" : percentage,
                symbolName: symbolName,
                progress: level,
                minimal: .icon(.init(symbolName)),
                compact: compact,
                expanded: expanded
            ),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(Self.presentationDuration)
        )
    }

    private nonisolated static func normalized(_ volume: Float) -> Double {
        guard volume.isFinite else { return 0 }
        return min(max(Double(volume), 0), 1)
    }

    private nonisolated static func symbolName(level: Double, isMuted: Bool) -> String {
        if isMuted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
