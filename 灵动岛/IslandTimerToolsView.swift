import SwiftUI

struct IslandTimerToolsView: View {
    @ObservedObject var model: IslandTimerToolsModel
    let onAcknowledgeCompletion: () -> Void
    @Namespace private var pomodoroPresetSelection

    var body: some View {
        Group {
            if let completedMode = model.completedMode {
                completionContent(for: completedMode)
            } else {
                timerControls
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.completedMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timerControls: some View {
        VStack(spacing: 8) {
            Picker("计时工具", selection: $model.selectedMode) {
                ForEach(IslandTimerToolMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(height: 26)

            ZStack(alignment: .topLeading) {
                selectedTimerContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(IslandTimerModeTransition.animation, value: model.selectedMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedTimerContent: some View {
        VStack(spacing: 8) {
            if model.selectedMode == .pomodoro {
                pomodoroPresetPicker
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(model.statusText, systemImage: model.selectedMode.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(modeTint.opacity(0.88))

                    Text(model.formattedDisplayedTime)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.numericText())
                        .animation(IslandPomodoroPresetAnimation.animation, value: model.pomodoroMinutes)
                        .animation(IslandCountdownDurationAnimation.animation, value: model.countdownMinutes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 8) {
                    if model.selectedMode == .countdown {
                        countdownDurationControl
                    }

                    HStack(spacing: 8) {
                        timerButton(
                            systemName: "arrow.counterclockwise",
                            help: "重置",
                            emphasized: false,
                            action: model.resetSelectedTimer
                        )
                        timerButton(
                            systemName: model.isSelectedTimerRunning ? "pause.fill" : "play.fill",
                            help: model.isSelectedTimerRunning ? "暂停" : "开始",
                            emphasized: true,
                            action: model.toggleSelectedTimer
                        )
                    }
                }
            }

            timerProgress
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(model.selectedMode)
        .transition(IslandTimerModeTransition.content)
    }

    private func completionContent(for mode: IslandTimerToolMode) -> some View {
        VStack(spacing: 8) {
            Text("\(mode.title)已完成")
                .font(.system(size: 13, weight: .semibold))

            Button(action: onAcknowledgeCompletion) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint(for: mode), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help("确认并收起")
            .accessibilityLabel("确认并收起")

            Text("点击确认并收起")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }

    private var pomodoroPresetPicker: some View {
        HStack(spacing: 6) {
            ForEach(IslandTimerToolsModel.pomodoroPresetMinutes, id: \.self) { minutes in
                let isSelected = model.pomodoroMinutes == minutes
                Button {
                    withAnimation(IslandPomodoroPresetAnimation.animation) {
                        model.selectPomodoroMinutes(minutes)
                    }
                } label: {
                    Text("\(minutes) 分")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.72))
                        .frame(width: 42, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.09))

                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(modeTint.opacity(0.78))
                                    .matchedGeometryEffect(
                                        id: "pomodoro-preset-selection",
                                        in: pomodoroPresetSelection
                                    )
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(isSelected ? 0.2 : 0.08), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!model.canSelectPomodoroPreset)
                .opacity(model.canSelectPomodoroPreset || isSelected ? 1 : 0.45)
                .animation(IslandPomodoroPresetAnimation.animation, value: isSelected)
                .help("设置为 \(minutes) 分钟")
                .accessibilityLabel("\(minutes) 分钟")
            }

            Spacer(minLength: 0)
        }
    }

    private var countdownDurationControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("按住加减按钮可快速调整")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))

            HStack(spacing: 6) {
                adjustmentButton(
                    systemName: "minus",
                    help: "减少一分钟",
                    isEnabled: model.canDecreaseCountdown
                ) {
                    adjustCountdownMinutes(by: -1)
                }

                Text("\(model.countdownMinutes) 分钟")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 48)
                    .contentTransition(.numericText())
                    .animation(IslandCountdownDurationAnimation.animation, value: model.countdownMinutes)

                adjustmentButton(
                    systemName: "plus",
                    help: "增加一分钟",
                    isEnabled: model.canIncreaseCountdown
                ) {
                    adjustCountdownMinutes(by: 1)
                }
            }
        }
    }

    private func adjustCountdownMinutes(by amount: Int) {
        withAnimation(IslandCountdownDurationAnimation.animation) {
            model.adjustCountdownMinutes(by: amount)
        }
    }

    @ViewBuilder
    private var timerProgress: some View {
        if let progress = model.selectedProgress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(modeTint)
                        .frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.1), value: progress)
        } else {
            Color.clear.frame(height: 4)
        }
    }

    private var modeTint: Color {
        tint(for: model.selectedMode)
    }

    private func tint(for mode: IslandTimerToolMode) -> Color {
        switch mode {
        case .stopwatch:
            return .cyan
        case .pomodoro:
            return .red
        case .countdown:
            return .orange
        }
    }

    private func timerButton(
        systemName: String,
        help: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    emphasized ? modeTint.opacity(0.82) : Color.white.opacity(0.11),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func adjustmentButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHint("按住可连续调整")
    }
}
