import SwiftUI

/// Host-produced values only. Plugins submit a reference, never this value.
public nonisolated struct IslandCountdownDisplayValue: Equatable, Sendable {
    public let text: String
    public let progress: Double
    public let requiresTick: Bool

    public init(text: String, progress: Double, requiresTick: Bool) {
        self.text = text
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        self.requiresTick = requiresTick
    }
}

/// Only the mounted leaf observes the shared pulse. Static renderer siblings
/// and hidden compact/expanded surfaces do not request display work.
struct IslandCountdownNodeView: View {
    let reference: IslandNode.Countdown
    let mode: ActivityPresentation.Mode
    let tint: Color
    let isVisible: Bool
    let resolve: (IslandNode.Countdown) -> IslandCountdownDisplayValue?
    @ObservedObject var clock: IslandCountdownDisplayClock
    @Environment(\.islandLayoutScale) private var layoutScale
    @State private var consumer = UUID()

    var body: some View {
        let value = resolve(reference)
        let needsTicks = isVisible && value?.requiresTick == true
        Group {
            switch reference.style {
            case .time:
                Text(value?.text ?? "--:--")
                    .font(IslandDesignTokens.font(for: mode == .expanded ? .metric : .caption, scale: layoutScale))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("Countdown")
                    .accessibilityValue(value?.text ?? "Unavailable")
            case .progress:
                ProgressView(value: value?.progress ?? 0)
                    .progressViewStyle(.linear)
                    .controlSize(layoutScale >= 1.5 ? .large : .regular)
                    .tint(tint)
                    .accessibilityLabel("Countdown progress")
                    .accessibilityValue(value.map { "\(Int(($0.progress * 100).rounded())) percent" } ?? "Unavailable")
            }
        }
        .onAppear { clock.setNeedsTicks(needsTicks, for: consumer) }
        .onChange(of: needsTicks) { _, needed in clock.setNeedsTicks(needed, for: consumer) }
        .onDisappear { clock.setNeedsTicks(false, for: consumer) }
    }
}
