import SwiftUI

struct IslandTimerToolsView: View {
    @Environment(\.islandLayoutScale) private var layoutScale
    @ObservedObject var model: IslandTimerToolsModel
    let onAcknowledgeCompletion: () -> Void

    private func p(_ value: CGFloat) -> CGFloat { value * layoutScale }

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
        VStack(spacing: p(4)) {
            IslandTimerModePicker(selection: $model.selectedMode)
                .frame(width: p(120), height: p(24))

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
        VStack(spacing: p(4)) {
            HStack(alignment: .center, spacing: p(14)) {
                VStack(alignment: .leading, spacing: p(3)) {
                    Label(model.statusText, systemImage: model.selectedMode.systemImage)
                        .font(.system(size: p(10), weight: .semibold))
                        .foregroundStyle(modeTint.opacity(0.88))

                    Text(model.formattedDisplayedTime)
                        .font(.system(size: p(26), weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.numericText())
                        .animation(IslandCountdownDurationAnimation.animation, value: model.countdownMinutes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: p(8)) {
                    if model.selectedMode == .countdown {
                        countdownDurationControl
                    }

                    HStack(spacing: p(8)) {
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
        // Keep the time's native font height when the shorter stopwatch Host
        // proposes its content budget. Only horizontal overflow may scale text.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(model.selectedMode)
        .transition(IslandTimerModeTransition.content)
    }

    private func completionContent(for mode: IslandTimerToolMode) -> some View {
        VStack(spacing: p(8)) {
            Text("\(mode.title)已完成")
                .font(.system(size: p(13), weight: .semibold))

            Button(action: onAcknowledgeCompletion) {
                Image(systemName: "checkmark")
                    .font(.system(size: p(20), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: p(46), height: p(46))
                    .background(tint(for: mode), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.24), lineWidth: p(0.5))
                    }
            }
            .buttonStyle(.plain)
            .help("确认并收起")
            .accessibilityLabel("确认并收起")

            Text("点击确认并收起")
                .font(.system(size: p(10), weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }

    private var countdownDurationControl: some View {
        VStack(alignment: .trailing, spacing: p(4)) {
            Text("按住加减按钮可快速调整")
                .font(.system(size: p(9), weight: .medium))
                .foregroundStyle(.white.opacity(0.42))

            HStack(spacing: p(6)) {
                adjustmentButton(
                    systemName: "minus",
                    help: "减少一分钟",
                    isEnabled: model.canDecreaseCountdown
                ) {
                    adjustCountdownMinutes(by: -1)
                }

                Text("\(model.countdownMinutes) 分钟")
                    .font(.system(size: p(10), weight: .medium))
                    .monospacedDigit()
                    .frame(width: p(48))
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
            .frame(height: p(4))
            .animation(.linear(duration: 0.1), value: progress)
        } else {
            Color.clear.frame(height: p(4))
        }
    }

    private var modeTint: Color {
        tint(for: model.selectedMode)
    }

    private func tint(for mode: IslandTimerToolMode) -> Color {
        switch mode {
        case .stopwatch:
            return .cyan
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
                .font(.system(size: p(12), weight: .bold))
                .foregroundStyle(.white)
                .frame(width: p(32), height: p(32))
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
                .font(.system(size: p(9), weight: .bold))
                .frame(width: p(22), height: p(22))
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
