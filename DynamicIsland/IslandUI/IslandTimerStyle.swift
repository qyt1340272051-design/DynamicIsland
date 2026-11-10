import SwiftUI

/// Shared final-point metrics for native timers and authored timer displays.
enum IslandTimerStyle {
    static let timeFontSize: CGFloat = 26
    static let controlSide: CGFloat = 32
    static let progressHeight: CGFloat = 4
    static let toolShellSize = CGSize(width: 440, height: IslandVisualStyle.expandedTimerHeight)
    private static let legacyToolShellSize = CGSize(width: 440, height: 188)

    /// The bounded two-column timer composition needs less room than arbitrary
    /// tool trees. Match public node styles/structure, never a plugin identifier.
    static func expandedToolShellSize(for presentation: ActivityPresentation) -> CGSize? {
        guard let node = presentation.expanded,
              ActivityPresentation.HostPolicy.accepts(node, for: .expanded),
              case .vStack(let root) = node, (2...3).contains(root.children.count),
              case .hStack(let row) = root.children[0], row.children.count == 3,
              case .vStack(let time) = row.children[0], time.children.count == 2,
              case .spacer = row.children[1],
              case .vStack(let controls) = row.children[2], (2...3).contains(controls.children.count) else { return nil }
        switch time.children[1] {
        case .text(let text) where text.font == .timer: break
        case .countdown(let countdown) where countdown.style == .timer: break
        default: return nil
        }
        switch root.children[1] {
        case .progress(let progress) where progress.style == .track: break
        case .countdown(let countdown) where countdown.style == .track: break
        default: return nil
        }
        if root.children.count == 3 {
            guard case .text(let hint) = root.children[2], hint.font == .caption else { return nil }
        }
        return controls.children.count == 2 ? toolShellSize : legacyToolShellSize
    }
}

struct IslandTimerProgressTrack: View {
    let progress: Double
    let tint: Color
    @Environment(\.islandLayoutScale) private var layoutScale

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, progress))))
            }
        }
        .frame(height: IslandTimerStyle.progressHeight * layoutScale)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(min(1, max(0, progress)) * 100)) percent")
    }
}
