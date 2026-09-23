import CoreGraphics
import SwiftUI

/// Values a plugin may request. The Host resolves them to platform appearance;
/// plugin payloads never carry point sizes, color components, or padding values.
public nonisolated enum IslandTypographyToken: String, Codable, CaseIterable, Sendable {
    case caption
    case body
    case headline
    case title
    case metric
}

public nonisolated enum IslandSpacingToken: String, Codable, CaseIterable, Sendable {
    case xs
    case sm
    case md
    case lg
}

public nonisolated enum IslandSemanticColorToken: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
    case accent
    case success
    case warning
    case danger
}

public nonisolated enum IslandCornerRadiusToken: String, Codable, CaseIterable, Sendable {
    case sm
    case md
}

/// Host-owned mappings for the finite plugin visual vocabulary.
public enum IslandDesignTokens {
    /// Semantic text styles allow the system to respond to larger text settings.
    /// The renderer remains responsible for truncation and accessibility labels
    /// within the island's fixed physical bounds.
    public static func font(for token: IslandTypographyToken) -> Font {
        switch token {
        case .caption: return .system(.caption2, weight: .medium)
        case .body: return .system(.caption, weight: .regular)
        case .headline: return .system(.subheadline, weight: .semibold)
        case .title: return .system(.headline, weight: .semibold)
        case .metric: return .system(.title, design: .monospaced, weight: .semibold)
        }
    }

    public static func spacing(_ token: IslandSpacingToken) -> CGFloat {
        switch token {
        case .xs: return 4
        case .sm: return 8
        case .md: return 12
        case .lg: return 16
        }
    }

    public static func cornerRadius(_ token: IslandCornerRadiusToken) -> CGFloat {
        switch token {
        case .sm: return 6
        case .md: return 10
        }
    }

    /// Album art keeps the existing 124 pt Host surface size. The smaller
    /// icon role follows the current presentation mode.
    public static func imageSide(_ token: IslandImageSizeToken, mode: ActivityPresentation.Mode) -> CGFloat {
        switch token {
        case .icon: return mode == .expanded ? 20 : 16
        case .thumbnail: return 26
        case .artwork: return 124
        }
    }

    /// The app's island shell is black in both system appearances. Resolve text
    /// and state colors against that actual surface, and strengthen secondary
    /// text when Increase Contrast is enabled.
    public static func color(
        for token: IslandSemanticColorToken,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        let resolved = resolvedColor(for: token, colorScheme: colorScheme, contrast: contrast)
        return Color(.sRGB, red: resolved.red, green: resolved.green, blue: resolved.blue, opacity: 1)
    }

    /// Compact dimensions come from the detected notch and current Host state.
    /// A plugin cannot specify a preferred shell size.
    public static func compactShellSize(
        baseSize: CGSize,
        hasCompactActivity: Bool,
        hasActiveTimer: Bool
    ) -> CGSize {
        IslandVisualStyle.compactShellSize(
            baseSize: baseSize,
            hasCompactActivity: hasCompactActivity,
            hasActiveTimer: hasActiveTimer
        )
    }

    /// The Host selects the expanded height for its active surface and state.
    public static func expandedShellSize(
        for surface: IslandExpandedSurface,
        timerMode: IslandTimerToolMode,
        hasTrayItems: Bool,
        hasError: Bool,
        hasTimerCompletion: Bool
    ) -> CGSize {
        IslandVisualStyle.expandedShellSize(
            for: surface,
            timerMode: timerMode,
            hasTrayItems: hasTrayItems,
            hasError: hasError,
            hasTimerCompletion: hasTimerCompletion
        )
    }

    /// Maximum existing expanded canvas; visible height may be smaller when
    /// the Host chooses one of its compact expanded shells.
    public static var expandedCanvasSize: CGSize { IslandVisualStyle.expandedContentSize }

    static func resolvedColor(
        for token: IslandSemanticColorToken,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> ResolvedColor {
        switch token {
        case .primary:
            return ResolvedColor(red: 1, green: 1, blue: 1)
        case .secondary:
            let component = contrast == .increased ? 0.95 : 0.76
            return ResolvedColor(red: component, green: component, blue: component)
        case .accent:
            return colorScheme == .dark
                ? ResolvedColor(red: 0.39, green: 0.82, blue: 1)
                : ResolvedColor(red: 0.35, green: 0.79, blue: 0.98)
        case .success:
            return ResolvedColor(red: 0.35, green: 0.86, blue: 0.55)
        case .warning:
            return ResolvedColor(red: 1, green: 0.73, blue: 0.28)
        case .danger:
            return ResolvedColor(red: 1, green: 0.42, blue: 0.40)
        }
    }

    nonisolated struct ResolvedColor: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }
}
