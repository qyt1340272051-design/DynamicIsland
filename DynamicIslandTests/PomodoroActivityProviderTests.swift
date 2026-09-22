import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroActivityProviderTests: XCTestCase {
    func testActualTimerPauseResumeAndStopRoundTripThroughActivity() throws {
        let model = IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        let manager = ActivityManager(configuration: .immediate)
        let provider = PomodoroActivityProvider(model: model, manager: manager)
        let router = ActionRouter(manager: manager)
        let registration = provider.registerActions(with: router)
        defer { router.unregister(source: PomodoroActivityProvider.source, registration: registration) }
        XCTAssertNil(manager.activity(id: PomodoroActivityProvider.activityID))

        let start = Date()
        model.selectedMode = .pomodoro
        model.startSelectedTimer(at: start)
        try provider.synchronize()
        XCTAssertEqual(manager.current?.source, PomodoroActivityProvider.source)
        XCTAssertEqual(Set(manager.current?.actions.map(\.id) ?? []),
                       Set([PomodoroActivityProvider.pauseActionID, PomodoroActivityProvider.stopActionID]))

        let runningSnapshot = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(router.dispatch(
            id: runningSnapshot.activity.id,
            source: runningSnapshot.activity.source,
            instanceToken: runningSnapshot.instanceToken,
            action: .init(actionID: PomodoroActivityProvider.pauseActionID, value: .none)
        ), .handled)
        XCTAssertNil(model.runningMode)
        XCTAssertLessThan(model.pomodoroRemaining, model.pomodoroDuration)
        XCTAssertEqual(Set(manager.current?.actions.map(\.id) ?? []),
                       Set([PomodoroActivityProvider.resumeActionID, PomodoroActivityProvider.stopActionID]))
        XCTAssertEqual(router.dispatch(
            id: runningSnapshot.activity.id,
            source: runningSnapshot.activity.source,
            instanceToken: runningSnapshot.instanceToken,
            action: .init(actionID: PomodoroActivityProvider.pauseActionID, value: .none)
        ), .undeclaredAction)

        let pausedSnapshot = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(router.dispatch(
            id: pausedSnapshot.activity.id,
            source: pausedSnapshot.activity.source,
            instanceToken: pausedSnapshot.instanceToken,
            action: .init(actionID: PomodoroActivityProvider.resumeActionID, value: .none)
        ), .handled)
        XCTAssertEqual(model.runningMode, .pomodoro)
        model.refresh(at: Date().addingTimeInterval(30))
        try provider.synchronize()
        XCTAssertLessThan(model.pomodoroRemaining, model.pomodoroDuration - 29)

        let resumedSnapshot = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(router.dispatch(
            id: resumedSnapshot.activity.id,
            source: resumedSnapshot.activity.source,
            instanceToken: resumedSnapshot.instanceToken,
            action: .init(actionID: PomodoroActivityProvider.stopActionID, value: .none)
        ), .handled)
        XCTAssertNil(model.sessionMode)
        XCTAssertNil(model.runningMode)
        XCTAssertEqual(model.pomodoroRemaining, model.pomodoroDuration)
        XCTAssertNil(manager.activity(id: PomodoroActivityProvider.activityID))
    }

    func testInvalidOrStaleActionsDoNotChangeTimer() throws {
        let model = IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        let manager = ActivityManager(configuration: .immediate)
        let provider = PomodoroActivityProvider(model: model, manager: manager)
        XCTAssertFalse(provider.handle(actionID: PomodoroActivityProvider.pauseActionID))

        let start = Date()
        model.selectedMode = .pomodoro
        model.startSelectedTimer(at: start)
        try provider.synchronize()
        XCTAssertFalse(provider.handle(actionID: PomodoroActivityProvider.resumeActionID))
        XCTAssertFalse(provider.handle(actionID: "pomodoro.unknown"))
        XCTAssertEqual(model.runningMode, .pomodoro)

        XCTAssertTrue(provider.handle(actionID: PomodoroActivityProvider.stopActionID))
        XCTAssertFalse(provider.handle(actionID: PomodoroActivityProvider.stopActionID))
        XCTAssertNil(manager.current)
    }

    func testAllPomodoroLayoutsRespectHostPolicy() throws {
        let model = IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        let manager = ActivityManager(configuration: .immediate)
        let provider = PomodoroActivityProvider(model: model, manager: manager)
        model.selectedMode = .pomodoro
        model.startSelectedTimer(at: Date())
        try provider.synchronize()

        let presentation = try XCTUnwrap(manager.current?.presentation)
        for mode in ActivityPresentation.Mode.allCases {
            let node = presentation.resolvedNode(for: mode)
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: mode), "\(mode)")
        }
    }

    func testObservedTimerStartAndResetSynchronizeWithoutManualCalls() async {
        let model = IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        let manager = ActivityManager(configuration: .immediate)
        let provider = PomodoroActivityProvider(model: model, manager: manager)
        model.selectedMode = .pomodoro
        model.startSelectedTimer(at: Date())

        for _ in 0..<20 {
            if manager.current?.id == PomodoroActivityProvider.activityID { break }
            await Task.yield()
        }
        XCTAssertEqual(manager.current?.id, PomodoroActivityProvider.activityID)

        model.resetSelectedTimer()
        for _ in 0..<20 {
            if manager.activity(id: PomodoroActivityProvider.activityID) == nil { break }
            await Task.yield()
        }
        XCTAssertNil(manager.activity(id: PomodoroActivityProvider.activityID))
        withExtendedLifetime(provider) {}
    }
}
