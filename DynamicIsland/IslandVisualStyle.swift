import CoreGraphics

public enum IslandVisualStyle {
    public static let expandedShellSize = CGSize(width: 480, height: 190)
    public static let expandedFileTrayHeight: CGFloat = 164
    public static let expandedCompactContentHeight: CGFloat = 152
    public static let expandedContentSize = CGSize(width: 468, height: 190)
    public static let expandedContentPadding: CGFloat = 12
    public static let expandedShellCornerRadius: CGFloat = 26
    public static let playingCompactHorizontalExpansion: CGFloat = 72
    public static let timerCompactHorizontalExpansion: CGFloat = 126
    public static let hoverShellShadowOpacity: Double = 0.28
    public static let hoverShellShadowRadius: CGFloat = 18
    public static let hoverShellShadowYOffset: CGFloat = 8
    public static let expandedShellStrokeOpacity: Double = 0
    public static let draggingShellStrokeOpacity: Double = 1

    public static func expandedShellSize(
        for surface: IslandExpandedSurface,
        timerMode: IslandTimerToolMode,
        hasTrayItems: Bool,
        hasError: Bool,
        hasTimerCompletion: Bool
    ) -> CGSize {
        let height: CGFloat
        if hasTimerCompletion || (surface == .fileTray && hasError) {
            height = expandedShellSize.height
        } else {
            switch surface {
            case .music:
                height = expandedShellSize.height
            case .fileTray:
                height = hasTrayItems ? expandedFileTrayHeight : expandedCompactContentHeight
            case .tools:
                height = timerMode == .stopwatch ? expandedCompactContentHeight : expandedShellSize.height
            }
        }

        return CGSize(width: expandedShellSize.width, height: height)
    }

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
