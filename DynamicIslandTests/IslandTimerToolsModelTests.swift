import Foundation
import XCTest
@testable import DynamicIsland

final class IslandTimerToolsModelTests: XCTestCase {
    func testStopwatchAccumulatesAndPauses() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        await MainActor.run {
            model.startSelectedTimer(at: start)
            model.refresh(at: start.addingTimeInterval(65.4))
            model.pauseSelectedTimer(at: start.addingTimeInterval(65.4))

            XCTAssertEqual(model.stopwatchElapsed, 65.4, accuracy: 0.01)
            XCTAssertNil(model.runningMode)
            XCTAssertEqual(model.sessionMode, .stopwatch)
            XCTAssertEqual(model.statusText, "已暂停")
            XCTAssertEqual(model.formattedDisplayedTime, "01:05.4")
            XCTAssertEqual(model.compactTimeText, "01:05.4")
        }
    }

    func testPomodoroCompletesAfterTwentyFiveMinutes() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        await MainActor.run {
            model.selectedMode = .pomodoro
            model.startSelectedTimer(at: start)
            model.refresh(at: start.addingTimeInterval(IslandTimerToolsModel.defaultPomodoroDuration))

            XCTAssertEqual(model.pomodoroRemaining, 0)
            XCTAssertNil(model.runningMode)
            XCTAssertEqual(model.sessionMode, .pomodoro)
            XCTAssertEqual(model.completedMode, .pomodoro)
            XCTAssertEqual(model.statusText, "已完成")
            XCTAssertEqual(model.selectedProgress, 1)
        }
    }

    func testCountdownCanBeAdjustedPausedAndReset() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 3_000)

        await MainActor.run {
            model.selectedMode = .countdown
            model.adjustCountdownMinutes(by: 2)
            XCTAssertEqual(model.countdownMinutes, 7)

            model.startSelectedTimer(at: start)
            model.pauseSelectedTimer(at: start.addingTimeInterval(60))
            XCTAssertEqual(model.countdownRemaining, 6 * 60, accuracy: 0.01)
            XCTAssertEqual(model.statusText, "已暂停")

            model.resetSelectedTimer()
            XCTAssertEqual(model.countdownRemaining, 7 * 60)
            XCTAssertNil(model.sessionMode)
            XCTAssertEqual(model.statusText, "设置时长")
        }
    }

    func testRepeatedCountdownAdjustmentsStopAtDurationLimits() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }

        await MainActor.run {
            for _ in 0..<IslandTimerToolsModel.maximumCountdownMinutes {
                model.adjustCountdownMinutes(by: 1)
            }

            XCTAssertEqual(model.countdownMinutes, IslandTimerToolsModel.maximumCountdownMinutes)
            XCTAssertFalse(model.canIncreaseCountdown)

            for _ in 0..<IslandTimerToolsModel.maximumCountdownMinutes {
                model.adjustCountdownMinutes(by: -1)
            }

            XCTAssertEqual(model.countdownMinutes, IslandTimerToolsModel.minimumCountdownMinutes)
            XCTAssertFalse(model.canDecreaseCountdown)
        }
    }

    func testPomodoroPresetChangesDurationAndCannotChangeWhileRunning() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 3_500)

        await MainActor.run {
            model.selectedMode = .pomodoro
            model.selectPomodoroMinutes(45)

            XCTAssertEqual(model.pomodoroMinutes, 45)
            XCTAssertEqual(model.pomodoroRemaining, 45 * 60)
            XCTAssertEqual(model.statusText, "45 分钟专注")

            model.startSelectedTimer(at: start)
            model.selectPomodoroMinutes(15)

            XCTAssertEqual(model.pomodoroMinutes, 45)
            XCTAssertFalse(model.canSelectPomodoroPreset)
        }
    }

    func testAcknowledgingCompletionResetsTimerAndClearsSession() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 3_750)

        await MainActor.run {
            model.selectedMode = .countdown
            model.startSelectedTimer(at: start)
            model.refresh(at: start.addingTimeInterval(model.countdownDuration))
            model.acknowledgeCompletion()

            XCTAssertNil(model.completedMode)
            XCTAssertNil(model.sessionMode)
            XCTAssertEqual(model.countdownRemaining, model.countdownDuration)
        }
    }

    func testStartingAnotherModePausesCurrentTimer() async {
        let model = await MainActor.run {
            IslandTimerToolsModel(tickIntervalNanoseconds: 60_000_000_000)
        }
        let start = Date(timeIntervalSinceReferenceDate: 4_000)

        await MainActor.run {
            model.startSelectedTimer(at: start)
            model.selectedMode = .countdown
            model.startSelectedTimer(at: start.addingTimeInterval(10))

            XCTAssertEqual(model.stopwatchElapsed, 10, accuracy: 0.01)
            XCTAssertEqual(model.runningMode, .countdown)
            XCTAssertEqual(model.sessionMode, .countdown)
        }
    }
}
