import Combine
import Foundation

public enum IslandTimerToolMode: String, CaseIterable, Identifiable, Sendable {
    case stopwatch
    case pomodoro
    case countdown

    public nonisolated var id: Self { self }

    public nonisolated var title: String {
        switch self {
        case .stopwatch:
            return "秒表"
        case .pomodoro:
            return "番茄钟"
        case .countdown:
            return "倒计时"
        }
    }

    public nonisolated var systemImage: String {
        switch self {
        case .stopwatch:
            return "stopwatch.fill"
        case .pomodoro:
            return "timer"
        case .countdown:
            return "hourglass"
        }
    }
}

@MainActor
public final class IslandTimerToolsModel: ObservableObject {
    public nonisolated static let pomodoroPresetMinutes = [15, 25, 45, 60]
    public nonisolated static let defaultPomodoroMinutes = 25
    public nonisolated static let defaultPomodoroDuration: TimeInterval = TimeInterval(defaultPomodoroMinutes * 60)
    public nonisolated static let defaultCountdownDuration: TimeInterval = 5 * 60
    public nonisolated static let minimumCountdownMinutes = 1
    public nonisolated static let maximumCountdownMinutes = 120

    @Published public var selectedMode: IslandTimerToolMode = .stopwatch
    @Published public private(set) var stopwatchElapsed: TimeInterval = 0
    @Published public private(set) var pomodoroDuration = IslandTimerToolsModel.defaultPomodoroDuration
    @Published public private(set) var pomodoroRemaining = IslandTimerToolsModel.defaultPomodoroDuration
    @Published public private(set) var countdownDuration = IslandTimerToolsModel.defaultCountdownDuration
    @Published public private(set) var countdownRemaining = IslandTimerToolsModel.defaultCountdownDuration
    @Published public private(set) var runningMode: IslandTimerToolMode?
    @Published public private(set) var sessionMode: IslandTimerToolMode?
    @Published public private(set) var completedMode: IslandTimerToolMode?

    private let tickIntervalNanoseconds: UInt64
    private var tickerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var valueAtStart: TimeInterval = 0

    public init(tickIntervalNanoseconds: UInt64 = 100_000_000) {
        self.tickIntervalNanoseconds = tickIntervalNanoseconds
    }

    deinit {
        tickerTask?.cancel()
    }

    public var displayedTime: TimeInterval {
        switch selectedMode {
        case .stopwatch:
            return stopwatchElapsed
        case .pomodoro:
            return pomodoroRemaining
        case .countdown:
            return countdownRemaining
        }
    }

    public var formattedDisplayedTime: String {
        Self.formattedTime(displayedTime, showsTenths: selectedMode == .stopwatch)
    }

    public var compactTimeText: String {
        guard let sessionMode else {
            return ""
        }
        return Self.formattedTime(
            currentValue(for: sessionMode),
            showsTenths: sessionMode == .stopwatch
        )
    }

    public var isSelectedTimerRunning: Bool {
        runningMode == selectedMode
    }

    public var selectedProgress: Double? {
        switch selectedMode {
        case .stopwatch:
            return nil
        case .pomodoro:
            return Self.progress(
                remaining: pomodoroRemaining,
                duration: pomodoroDuration
            )
        case .countdown:
            return Self.progress(
                remaining: countdownRemaining,
                duration: countdownDuration
            )
        }
    }

    public var statusText: String {
        if completedMode == selectedMode {
            return "已完成"
        }
        if runningMode == selectedMode {
            return "计时中"
        }
        if hasPartialProgress(for: selectedMode) {
            return "已暂停"
        }
        switch selectedMode {
        case .stopwatch:
            return "准备计时"
        case .pomodoro:
            return "\(pomodoroMinutes) 分钟专注"
        case .countdown:
            return "设置时长"
        }
    }

    public var pomodoroMinutes: Int {
        Int((pomodoroDuration / 60).rounded())
    }

    public var canSelectPomodoroPreset: Bool {
        runningMode != .pomodoro
    }

    public var countdownMinutes: Int {
        Int((countdownDuration / 60).rounded())
    }

    public var canDecreaseCountdown: Bool {
        runningMode != .countdown && countdownMinutes > Self.minimumCountdownMinutes
    }

    public var canIncreaseCountdown: Bool {
        runningMode != .countdown && countdownMinutes < Self.maximumCountdownMinutes
    }

    public func toggleSelectedTimer() {
        if isSelectedTimerRunning {
            pauseSelectedTimer(at: Date())
        } else {
            startSelectedTimer(at: Date())
        }
    }

    public func resetSelectedTimer() {
        if runningMode == selectedMode {
            cancelTicker()
            runningMode = nil
            startedAt = nil
        }

        resetValue(for: selectedMode)
        if completedMode == selectedMode {
            completedMode = nil
        }
        if sessionMode == selectedMode {
            sessionMode = nil
        }
    }

    public func selectPomodoroMinutes(_ minutes: Int) {
        guard Self.pomodoroPresetMinutes.contains(minutes), canSelectPomodoroPreset else {
            return
        }

        pomodoroDuration = TimeInterval(minutes * 60)
        pomodoroRemaining = pomodoroDuration
        if completedMode == .pomodoro {
            completedMode = nil
        }
        if sessionMode == .pomodoro {
            sessionMode = nil
        }
    }

    public func adjustCountdownMinutes(by amount: Int) {
        guard runningMode != .countdown else {
            return
        }

        let updatedMinutes = min(
            max(countdownMinutes + amount, Self.minimumCountdownMinutes),
            Self.maximumCountdownMinutes
        )
        countdownDuration = TimeInterval(updatedMinutes * 60)
        countdownRemaining = countdownDuration
        if completedMode == .countdown {
            completedMode = nil
        }
        if sessionMode == .countdown {
            sessionMode = nil
        }
    }

    public func acknowledgeCompletion() {
        guard let completedMode else {
            return
        }

        resetValue(for: completedMode)
        self.completedMode = nil
        if sessionMode == completedMode {
            sessionMode = nil
        }
    }

    func startSelectedTimer(at date: Date) {
        pauseActiveTimer(at: date)

        if displayedTime <= 0, selectedMode != .stopwatch {
            resetValue(for: selectedMode)
        }

        completedMode = nil
        sessionMode = selectedMode
        runningMode = selectedMode
        startedAt = date
        valueAtStart = currentValue(for: selectedMode)
        startTicker()
    }

    func pauseSelectedTimer(at date: Date) {
        guard runningMode == selectedMode else {
            return
        }

        refresh(at: date)
        guard runningMode == selectedMode else {
            return
        }
        cancelTicker()
        runningMode = nil
        startedAt = nil
    }

    func refresh(at date: Date) {
        guard let runningMode, let startedAt else {
            return
        }

        let elapsed = max(0, date.timeIntervalSince(startedAt))
        switch runningMode {
        case .stopwatch:
            stopwatchElapsed = valueAtStart + elapsed
        case .pomodoro:
            pomodoroRemaining = max(0, valueAtStart - elapsed)
            if pomodoroRemaining == 0 {
                complete(runningMode)
            }
        case .countdown:
            countdownRemaining = max(0, valueAtStart - elapsed)
            if countdownRemaining == 0 {
                complete(runningMode)
            }
        }
    }

    public nonisolated static func formattedTime(
        _ interval: TimeInterval,
        showsTenths: Bool
    ) -> String {
        let clampedInterval = max(interval, 0)
        if showsTenths {
            let totalTenths = Int((clampedInterval * 10).rounded(.down))
            let minutes = totalTenths / 600
            let seconds = (totalTenths % 600) / 10
            let tenths = totalTenths % 10
            return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
        }

        let totalSeconds = Int(clampedInterval.rounded(.up))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private nonisolated static func progress(
        remaining: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(1 - remaining / duration, 0), 1)
    }

    private func startTicker() {
        cancelTicker()
        let interval = tickIntervalNanoseconds
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else {
                    return
                }
                self.refresh(at: Date())
            }
        }
    }

    private func pauseActiveTimer(at date: Date) {
        guard runningMode != nil else {
            return
        }
        refresh(at: date)
        guard runningMode != nil else {
            return
        }
        cancelTicker()
        runningMode = nil
        startedAt = nil
    }

    private func complete(_ mode: IslandTimerToolMode) {
        cancelTicker()
        runningMode = nil
        startedAt = nil
        completedMode = mode
    }

    private func cancelTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func currentValue(for mode: IslandTimerToolMode) -> TimeInterval {
        switch mode {
        case .stopwatch:
            return stopwatchElapsed
        case .pomodoro:
            return pomodoroRemaining
        case .countdown:
            return countdownRemaining
        }
    }

    private func resetValue(for mode: IslandTimerToolMode) {
        switch mode {
        case .stopwatch:
            stopwatchElapsed = 0
        case .pomodoro:
            pomodoroRemaining = pomodoroDuration
        case .countdown:
            countdownRemaining = countdownDuration
        }
    }

    private func hasPartialProgress(for mode: IslandTimerToolMode) -> Bool {
        switch mode {
        case .stopwatch:
            return stopwatchElapsed > 0
        case .pomodoro:
            return pomodoroRemaining < pomodoroDuration && pomodoroRemaining > 0
        case .countdown:
            return countdownRemaining < countdownDuration && countdownRemaining > 0
        }
    }
}
