import CoreGraphics

public enum IslandVisualStyle {
    public static let expandedShellSize = CGSize(width: 500, height: 220)
    public static let expandedShellCornerRadius: CGFloat = 30
    public static let playingCompactHorizontalExpansion: CGFloat = 72
    public static let timerCompactHorizontalExpansion: CGFloat = 126
    public static let hoverShellShadowOpacity: Double = 0.28
    public static let hoverShellShadowRadius: CGFloat = 18
    public static let hoverShellShadowYOffset: CGFloat = 8
    public static let expandedShellStrokeOpacity: Double = 0
    public static let draggingShellStrokeOpacity: Double = 1

    public static func shellShadowOpacity(isCompactHovering: Bool) -> Double {
        isCompactHovering ? hoverShellShadowOpacity : 0
    }

    public static func compactShellSize(
        baseSize: CGSize,
        isPlaying: Bool,
        hasActiveTimer: Bool = false
    ) -> CGSize {
        let horizontalExpansion: CGFloat
        if hasActiveTimer {
            horizontalExpansion = timerCompactHorizontalExpansion
        } else if isPlaying {
            horizontalExpansion = playingCompactHorizontalExpansion
        } else {
            horizontalExpansion = 0
        }

        return CGSize(
            width: baseSize.width + horizontalExpansion,
            height: baseSize.height
        )
    }

    public static func compactContentOpacity(isExpanded: Bool, hasCompactContent: Bool) -> Double {
        !isExpanded && hasCompactContent ? 1 : 0
    }

    public static func shellCornerRadii(isExpanded: Bool, shellHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        if isExpanded {
            return (expandedShellCornerRadius, expandedShellCornerRadius)
        }

        return (0, shellHeight / 2)
    }
}
