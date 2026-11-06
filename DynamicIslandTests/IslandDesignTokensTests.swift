import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import DynamicIsland

final class IslandDesignTokensTests: XCTestCase {
    func testTokenVocabulariesRoundTripAndRejectArbitraryValues() throws {
        try assertFiniteCodable(IslandTypographyToken.allCases, expected: [
            "caption", "body", "headline", "title", "metric"
        ])
        try assertFiniteCodable(IslandSpacingToken.allCases, expected: [
            "xs", "sm", "md", "lg"
        ])
        try assertFiniteCodable(IslandSemanticColorToken.allCases, expected: [
            "primary", "secondary", "accent", "success", "warning", "danger"
        ])
        try assertFiniteCodable(IslandCornerRadiusToken.allCases, expected: ["sm", "md"])
        try assertFiniteCodable(IslandImageSizeToken.allCases, expected: ["icon", "thumbnail", "artwork"])

        XCTAssertThrowsError(try JSONDecoder().decode(IslandTypographyToken.self, from: Data(#""72pt""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(IslandSpacingToken.self, from: Data(#""99""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(IslandSemanticColorToken.self, from: Data("\"#ff0000\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(IslandImageSizeToken.self, from: Data("\"200pt\"".utf8)))
    }

    func testSpacingAndCornerRadiiUseFiniteHostValues() {
        XCTAssertEqual(IslandSpacingToken.allCases.map { IslandDesignTokens.spacing($0) }, [4, 8, 12, 16])
        XCTAssertEqual(IslandCornerRadiusToken.allCases.map { IslandDesignTokens.cornerRadius($0) }, [6, 10])
    }

    func testCompactAndExpandedBoundsFollowExistingHostGeometry() {
        XCTAssertEqual(IslandDesignTokens.imageSide(.icon, mode: .minimal), 16)
        XCTAssertEqual(IslandDesignTokens.imageSide(.icon, mode: .compact), 16)
        XCTAssertEqual(IslandDesignTokens.imageSide(.icon, mode: .expanded), 20)
        XCTAssertEqual(IslandDesignTokens.imageSide(.thumbnail, mode: .compact), 26)
        XCTAssertEqual(IslandDesignTokens.imageSide(.artwork, mode: .expanded), 112)
        let compactBase = CGSize(width: 270, height: 32)
        XCTAssertEqual(
            IslandDesignTokens.compactShellSize(baseSize: compactBase, hasCompactActivity: false, hasActiveTimer: false),
            compactBase
        )
        XCTAssertEqual(
            IslandDesignTokens.compactShellSize(baseSize: compactBase, hasCompactActivity: true, hasActiveTimer: false),
            IslandVisualStyle.compactShellSize(baseSize: compactBase, hasCompactActivity: true)
        )
        XCTAssertEqual(
            IslandDesignTokens.compactShellSize(baseSize: compactBase, hasCompactActivity: true, hasActiveTimer: true),
            IslandVisualStyle.compactShellSize(baseSize: compactBase, hasCompactActivity: true, hasActiveTimer: true)
        )

        for (surface, mode, expectedHeight) in [
            (IslandExpandedSurface.music, IslandTimerToolMode.stopwatch, IslandVisualStyle.expandedMusicHeight),
            (.fileTray, .stopwatch, IslandVisualStyle.expandedCompactContentHeight),
            (.tools, .stopwatch, IslandVisualStyle.expandedCompactContentHeight),
            (.tools, .countdown, IslandVisualStyle.expandedTimerHeight)
        ] {
            let size = IslandDesignTokens.expandedShellSize(
                for: surface,
                timerMode: mode,
                hasTrayItems: false,
                hasError: false,
                hasTimerCompletion: false
            )
            XCTAssertEqual(size.width, IslandVisualStyle.expandedShellSize.width)
            XCTAssertEqual(size.height, expectedHeight)
            XCTAssertLessThanOrEqual(size.height, IslandDesignTokens.expandedCanvasSize.height)
        }
        XCTAssertEqual(IslandDesignTokens.expandedCanvasSize, IslandVisualStyle.expandedContentSize)
        XCTAssertLessThan(IslandDesignTokens.expandedCanvasSize.width, IslandPanelGeometry.expandedSize.width)
    }

    func testSemanticColorsRemainReadableOnTheBlackIslandInBothAppearances() {
        for scheme in [ColorScheme.dark, .light] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                for token in IslandSemanticColorToken.allCases {
                    let color = IslandDesignTokens.resolvedColor(
                        for: token,
                        colorScheme: scheme,
                        contrast: contrast
                    )
                    XCTAssertGreaterThanOrEqual(
                        contrastRatioAgainstBlack(color),
                        4.5,
                        "\(token) must remain legible in \(scheme), \(contrast)"
                    )
                }
            }
        }

        let standard = IslandDesignTokens.resolvedColor(
            for: .secondary, colorScheme: .dark, contrast: .standard
        )
        let increased = IslandDesignTokens.resolvedColor(
            for: .secondary, colorScheme: .dark, contrast: .increased
        )
        XCTAssertGreaterThan(contrastRatioAgainstBlack(increased), contrastRatioAgainstBlack(standard))
        XCTAssertNotEqual(
            IslandDesignTokens.resolvedColor(for: .accent, colorScheme: .dark, contrast: .standard),
            IslandDesignTokens.resolvedColor(for: .accent, colorScheme: .light, contrast: .standard)
        )
    }

    @MainActor
    func testReferenceTypographyPreservesSemanticStylesAndScaledFontsUseFinalPoints() {
        let mappings: [(IslandTypographyToken, Font, NSFont.TextStyle, Font.Weight, Font.Design)] = [
            (.caption, .system(.caption2, weight: .medium), .caption2, .medium, .default),
            (.body, .system(.caption, weight: .regular), .caption1, .regular, .default),
            (.headline, .system(.subheadline, weight: .semibold), .subheadline, .semibold, .default),
            (.title, .system(.headline, weight: .semibold), .headline, .semibold, .default),
            (.metric, .system(.title, design: .monospaced, weight: .semibold), .title1, .semibold, .monospaced)
        ]
        for (token, semantic, style, weight, design) in mappings {
            XCTAssertEqual(IslandDesignTokens.font(for: token), semantic)
            for scale in [CGFloat(0.875), 1.75] {
                let finalPointSize = NSFont.preferredFont(forTextStyle: style, options: [:]).pointSize * scale
                XCTAssertEqual(IslandDesignTokens.font(for: token, scale: scale),
                               .system(size: finalPointSize, weight: weight, design: design), token.rawValue)
            }
        }
    }

    func testLayoutEnvironmentDefaultsAndRejectsInvalidMultipliers() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.islandLayoutScale, 1)
        environment.islandLayoutScale = 1.75
        XCTAssertEqual(environment.islandLayoutScale, 1.75)
        for invalid in [CGFloat.nan, .infinity, 0, -1] {
            environment.islandLayoutScale = invalid
            XCTAssertEqual(environment.islandLayoutScale, 1)
        }
    }

    func testHostTokenDimensionsResolveDirectlyToFinalPoints() {
        for scale in [CGFloat(0.875), 1, 1.75] {
            XCTAssertEqual(IslandDesignTokens.spacing(.sm, scale: scale), 8 * scale)
            XCTAssertEqual(IslandDesignTokens.cornerRadius(.md, scale: scale), 10 * scale)
            XCTAssertEqual(IslandDesignTokens.imageSide(.artwork, mode: .expanded, scale: scale), 112 * scale)
            XCTAssertEqual(IslandDesignTokens.imageSide(.icon, mode: .compact, scale: scale), 16 * scale)
        }
    }

    private func assertFiniteCodable<Token: Codable & CaseIterable & RawRepresentable & Equatable>(
        _ cases: [Token],
        expected: [String]
    ) throws where Token.RawValue == String {
        XCTAssertEqual(cases.map(\.rawValue), expected)
        for value in cases {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(Token.self, from: encoded), value)
        }
    }

    private func contrastRatioAgainstBlack(_ color: IslandDesignTokens.ResolvedColor) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
        return (luminance + 0.05) / 0.05
    }
}
