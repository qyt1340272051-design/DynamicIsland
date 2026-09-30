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
            return .init(bodyWidth: 28, bodyHeight: 13, terminalWidth: 2, terminalGap: 1, inset: 1.5)
        case .compact:
            return .init(bodyWidth: 40, bodyHeight: 18, terminalWidth: 3, terminalGap: 2, inset: 2)
        case .expanded:
            return .init(bodyWidth: 48, bodyHeight: 22, terminalWidth: 4, terminalGap: 2, inset: 2.5)
        }
    }

    private var fillColor: Color {
        IslandDesignTokens.color(for: colorToken, colorScheme: colorScheme, contrast: contrast)
    }

    private var outlineColor: Color {
        IslandDesignTokens.color(for: .primary, colorScheme: colorScheme, contrast: contrast)
    }

    var body: some View {
        let metrics = configuration
        HStack(spacing: metrics.terminalGap) {
            GeometryReader { proxy in
                let innerWidth = max(0, proxy.size.width - 2 * metrics.inset)
                let innerHeight = max(0, proxy.size.height - 2 * metrics.inset)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: metrics.bodyHeight * 0.27, style: .continuous)
                        .fill(outlineColor.opacity(contrast == .increased ? 0.34 : 0.24))
                        .padding(metrics.inset)

                    RoundedRectangle(cornerRadius: innerHeight * 0.24, style: .continuous)
                        .fill(fillColor)
                        .frame(width: innerWidth * level, height: innerHeight)
                        .offset(x: metrics.inset)

                    RoundedRectangle(cornerRadius: metrics.bodyHeight * 0.3, style: .continuous)
                        .stroke(outlineColor.opacity(contrast == .increased ? 0.9 : 0.72), lineWidth: 1)
                }
            }
            .frame(width: metrics.bodyWidth, height: metrics.bodyHeight)

            Capsule(style: .continuous)
                .fill(outlineColor.opacity(contrast == .increased ? 0.9 : 0.72))
                .frame(width: metrics.terminalWidth, height: metrics.bodyHeight * 0.38)
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
        let terminalGap: CGFloat
        let inset: CGFloat

        var totalWidth: CGFloat { bodyWidth + terminalGap + terminalWidth }
    }
}
