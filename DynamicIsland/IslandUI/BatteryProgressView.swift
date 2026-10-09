import SwiftUI

/// Host-owned rendering for the finite `battery` progress style. Payloads
/// provide only a normalized value and semantic color; dimensions, shape and
/// animation remain under Host control.
struct BatteryProgressView: View {
    let value: Double
    let colorToken: IslandSemanticColorToken
    let mode: ActivityPresentation.Mode

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private var configuration: Configuration {
        switch mode {
        case .minimal:
            return .init(bodyWidth: 26, bodyHeight: 12, terminalWidth: 2, terminalHeight: 4, terminalGap: 1)
        case .compact:
            return .init(bodyWidth: 42, bodyHeight: 20, terminalWidth: 3, terminalHeight: 7, terminalGap: 2)
        case .expanded:
            return .init(bodyWidth: 50, bodyHeight: 24, terminalWidth: 4, terminalHeight: 9, terminalGap: 2)
        }
    }

    private var fillColor: Color {
        IslandDesignTokens.color(for: colorToken, colorScheme: colorScheme, contrast: contrast)
    }

    private var trackOpacity: Double {
        contrast == .increased ? 0.56 : 0.42
    }

    var body: some View {
        let metrics = configuration
        HStack(spacing: metrics.terminalGap) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(fillColor.opacity(trackOpacity))

                Rectangle()
                    .fill(fillColor)
                    .frame(width: metrics.bodyWidth * level, height: metrics.bodyHeight)
            }
            .frame(width: metrics.bodyWidth, height: metrics.bodyHeight)
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))

            Capsule(style: .continuous)
                .fill(fillColor.opacity(trackOpacity))
                .frame(width: metrics.terminalWidth, height: metrics.terminalHeight)
        }
        .frame(width: metrics.totalWidth, height: metrics.bodyHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }

    private struct Configuration {
        let bodyWidth: CGFloat
        let bodyHeight: CGFloat
        let terminalWidth: CGFloat
        let terminalHeight: CGFloat
        let terminalGap: CGFloat

        var totalWidth: CGFloat { bodyWidth + terminalGap + terminalWidth }
        var cornerRadius: CGFloat { bodyHeight * 0.28 }
    }
}
