import SwiftUI

/// Deterministic, bounded motion shared by the view and its regression tests.
/// Each cycle rests at the leading edge, travels to the trailing edge, rests,
/// then returns. Native text stays at its authored font size throughout.
nonisolated enum IslandMarqueeMotion {
    static func overflow(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard contentWidth.isFinite, viewportWidth.isFinite,
              contentWidth > 0, viewportWidth > 0 else { return 0 }
        return max(0, contentWidth - viewportWidth)
    }

    static func shouldAnimate(contentWidth: CGFloat, viewportWidth: CGFloat,
                              isVisible: Bool, reduceMotion: Bool) -> Bool {
        isVisible && !reduceMotion && overflow(contentWidth: contentWidth, viewportWidth: viewportWidth) > 0.5
    }

    static func offset(for elapsed: TimeInterval, contentWidth: CGFloat, viewportWidth: CGFloat,
                       pointsPerSecond: CGFloat = 24, pause: TimeInterval = 1) -> CGFloat {
        let distance = overflow(contentWidth: contentWidth, viewportWidth: viewportWidth)
        guard distance > 0, elapsed.isFinite, elapsed > 0,
              pointsPerSecond.isFinite, pointsPerSecond > 0,
              pause.isFinite, pause >= 0 else { return 0 }
        let travel = Double(distance / pointsPerSecond)
        let cycle = 2 * (pause + travel)
        guard travel.isFinite, cycle.isFinite, cycle > 0 else { return 0 }
        var phase = elapsed.truncatingRemainder(dividingBy: cycle)
        if phase <= pause { return 0 }
        phase -= pause
        if phase < travel { return max(-distance, -CGFloat(phase) * pointsPerSecond) }
        phase -= travel
        if phase <= pause { return -distance }
        phase -= pause
        return min(0, max(-distance, -distance + CGFloat(phase) * pointsPerSecond))
    }
}

/// One native-font line whose overlay may move within its allocated width.
/// The hidden anchor participates in layout; the unrestricted text overlay
/// never enlarges that layout or causes the renderer to choose its summary.
struct IslandMarqueeText: View {
    let content: String
    let font: Font
    let tint: Color
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutScale) private var layoutScale
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var epoch = Date()

    private var animates: Bool {
        IslandMarqueeMotion.shouldAnimate(contentWidth: contentWidth, viewportWidth: viewportWidth,
                                          isVisible: isVisible, reduceMotion: reduceMotion)
    }

    var body: some View {
        Text(content)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                updateViewport(width)
            }
            .overlay(alignment: .leading) {
                if animates {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        let offset = IslandMarqueeMotion.offset(for: timeline.date.timeIntervalSince(epoch),
                            contentWidth: contentWidth, viewportWidth: viewportWidth,
                            pointsPerSecond: 24 * IslandDesignTokens.normalizedLayoutScale(layoutScale))
                        overlayText.offset(x: offset)
                    }
                } else {
                    overlayText
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityHidden(!isVisible)
            .onChange(of: content) { _, _ in resetMotion() }
            .onChange(of: font) { _, _ in resetMotion() }
            .onChange(of: layoutScale) { _, _ in resetMotion() }
            .onChange(of: isVisible) { _, _ in resetMotion() }
            .onChange(of: reduceMotion) { _, _ in resetMotion() }
            .onAppear { resetMotion() }
            // Parent progress updates animate their Activity presentation.
            // Marquee movement is driven only by its own timeline position.
            .transaction { $0.animation = nil }
    }

    private var overlayText: some View {
        Text(content)
            .font(font)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                let bounded = width.isFinite ? max(0, width) : 0
                guard abs(bounded - contentWidth) > 0.25 else { return }
                contentWidth = bounded
                resetMotion()
            }
            .accessibilityHidden(true)
    }

    private func updateViewport(_ width: CGFloat) {
        let bounded = width.isFinite ? max(0, width) : 0
        guard abs(bounded - viewportWidth) > 0.25 else { return }
        viewportWidth = bounded
        resetMotion()
    }

    private func resetMotion() { epoch = Date() }
}
