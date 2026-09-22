import Combine
import Foundation
import OSLog

/// Host-owned bridge for the existing timer model. This is an Activity API
/// consumer, not the later JavaScript Pomodoro plugin described by T35.
@MainActor
public final class PomodoroActivityProvider {
    public nonisolated static let activityID = "builtin.pomodoro"
    public nonisolated static let source = ActivitySource(kind: .builtIn, identifier: "pomodoro")
    public nonisolated static let pauseActionID = "pomodoro.pause"
    public nonisolated static let resumeActionID = "pomodoro.resume"
    public nonisolated static let stopActionID = "pomodoro.stop"

    private let model: IslandTimerToolsModel
    private let manager: ActivityManager
    private var observation: AnyCancellable?
    private let logger = Logger(subsystem: "DynamicIsland", category: "PomodoroActivityProvider")

    public init(model: IslandTimerToolsModel, manager: ActivityManager) {
        self.model = model
        self.manager = manager
        observation = model.objectWillChange.sink { [weak self] _ in
            // ObservableObject publishes before its stored properties change.
            // Read the completed model state on the following main-actor turn.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.synchronizeAfterModelChange()
            }
        }
        synchronizeAfterModelChange()
    }

    /// Install the source handler in the Host. The returned registration must
    /// be unregistered when the Host tears down this provider.
    @discardableResult
    public func registerActions(with router: ActionRouter) -> UUID {
        router.register(source: Self.source) { [weak self] action in
            guard action.activityID == Self.activityID, action.value == .none else { return }
            self?.handle(actionID: action.actionID)
        }
    }

    /// May also be called by a Host after restoring timer state or in tests.
    public func synchronize() throws {
        guard model.sessionMode == .pomodoro else {
            if manager.activity(id: Self.activityID) != nil {
                try manager.end(id: Self.activityID, source: Self.source)
            }
            return
        }

        let activity = makeActivity()
        if let existing = manager.activity(id: Self.activityID),
           existing.presentation == activity.presentation,
           existing.actions == activity.actions {
            return
        }
        try manager.publish(activity)
    }

    /// Called only after ActionRouter validates the activity, source, action
    /// declaration, and instance token. Returns false for stale timer state.
    @discardableResult
    public func handle(actionID: String, at date: Date = Date()) -> Bool {
        guard model.sessionMode == .pomodoro else { return false }
        switch actionID {
        case Self.pauseActionID:
            guard model.runningMode == .pomodoro else { return false }
            model.selectedMode = .pomodoro
            model.pauseSelectedTimer(at: date)
        case Self.resumeActionID:
            guard model.runningMode == nil,
                  model.completedMode != .pomodoro,
                  model.pomodoroRemaining > 0 else { return false }
            model.selectedMode = .pomodoro
            model.startSelectedTimer(at: date)
        case Self.stopActionID:
            model.selectedMode = .pomodoro
            model.resetSelectedTimer()
        default:
            return false
        }
        synchronizeAfterModelChange()
        return true
    }

    private func synchronizeAfterModelChange() {
        do {
            try synchronize()
        } catch {
            logger.error("Failed to synchronize Pomodoro Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeActivity() -> IslandActivity {
        let complete = model.completedMode == .pomodoro
        let running = model.runningMode == .pomodoro
        let remainingSeconds = Int(ceil(max(0, model.pomodoroRemaining)))
        let timeText = IslandTimerToolsModel.formattedTime(Double(remainingSeconds), showsTenths: false)
        let status = complete ? "已完成" : (running ? "计时中" : "已暂停")
        let progress = min(max(1 - Double(remainingSeconds) / model.pomodoroDuration, 0), 1)
        let primaryAction = complete ? nil : (running ? Self.pauseActionID : Self.resumeActionID)
        let primaryLabel = running ? "暂停" : "继续"
        let primarySymbol = running ? "pause.fill" : "play.fill"

        var controls: [IslandNode] = []
        var actions: [ActivityAction] = []
        if let primaryAction {
            controls.append(.button(.init(actionID: primaryAction, label: .text(.init(primaryLabel)))))
            actions.append(ActivityAction(id: primaryAction, title: primaryLabel))
        }
        controls.append(.button(.init(actionID: Self.stopActionID, label: .text(.init("结束")))))
        actions.append(ActivityAction(id: Self.stopActionID, title: "结束"))

        var compactItems: [IslandNode] = [
            .icon(.init("timer")),
            .text(.init(timeText))
        ]
        if let primaryAction {
            compactItems.append(.button(.init(actionID: primaryAction, label: .icon(.init(primarySymbol)))))
        }

        let presentation = ActivityPresentation(
            title: "番茄钟",
            subtitle: "\(status) · \(timeText)",
            symbolName: "timer",
            progress: progress,
            minimal: .icon(.init("timer")),
            compact: .hStack(.init(compactItems)),
            expanded: .vStack(.init([
                .hStack(.init([.icon(.init("timer")), .text(.init("番茄钟 · \(status)"))])),
                .text(.init(timeText)),
                .progress(.init(progress)),
                .hStack(.init(controls))
            ]))
        )

        return IslandActivity(
            id: Self.activityID,
            source: Self.source,
            priority: .normal,
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: presentation,
            createdAt: Date(),
            actions: actions
        )
    }
}
