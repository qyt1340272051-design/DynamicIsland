import Foundation
import XCTest
@testable import DynamicIsland

final class ActivityPresentationTests: XCTestCase {
    func testLegacyJSONDecodesAndKeepsSummaryFields() throws {
        let legacy = Data(#"{"title":"Focus","subtitle":"24:58 left","symbolName":"timer","progress":0.4}"#.utf8)
        let presentation = try JSONDecoder().decode(ActivityPresentation.self, from: legacy)

        XCTAssertEqual(presentation.title, "Focus")
        XCTAssertEqual(presentation.subtitle, "24:58 left")
        XCTAssertEqual(presentation.symbolName, "timer")
        XCTAssertEqual(presentation.progress, 0.4)
        XCTAssertNil(presentation.minimal)
        XCTAssertNil(presentation.compact)
        XCTAssertNil(presentation.expanded)
        XCTAssertTrue(presentation.isCompactVisible)
        XCTAssertEqual(presentation.resolvedNode(for: .minimal), .icon(.init("timer")))
        XCTAssertEqual(presentation.resolvedNode(for: .compact), .hStack(.init([
            .icon(.init("timer")), .text(.init("Focus"))
        ])))
        XCTAssertEqual(presentation.resolvedNode(for: .expanded), .vStack(.init([
            .hStack(.init([.icon(.init("timer")), .text(.init("Focus"))])),
            .text(.init("24:58 left")),
            .progress(.init(0.4))
        ])))

        let encoded = try JSONEncoder().encode(presentation)
        XCTAssertEqual(try JSONDecoder().decode(ActivityPresentation.self, from: encoded), presentation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["minimal"])
        XCTAssertNil(object["compact"])
        XCTAssertNil(object["expanded"])
        XCTAssertNil(object["showsCompact"])
    }

    func testProviderCanSuppressCompactPresentationAndRoundTripIt() throws {
        let presentation = ActivityPresentation(title: "Paused", showsCompact: false)

        XCTAssertFalse(presentation.isCompactVisible)
        let data = try JSONEncoder().encode(presentation)
        XCTAssertEqual(try JSONDecoder().decode(ActivityPresentation.self, from: data), presentation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["showsCompact"] as? Bool, false)
    }

    func testMissingLayoutsOnlyFallBackTowardSimplerSuppliedLayouts() {
        let minimal: IslandNode = .icon(.init("timer"))
        let compact: IslandNode = .hStack(.init([.icon(.init("timer")), .text(.init("24:58"))]))
        let withMinimal = ActivityPresentation(title: "Focus", minimal: minimal)
        XCTAssertEqual(withMinimal.resolvedNode(for: .compact), minimal)
        XCTAssertEqual(withMinimal.resolvedNode(for: .expanded), minimal)

        let withCompact = ActivityPresentation(title: "Focus", compact: compact)
        XCTAssertEqual(withCompact.resolvedNode(for: .expanded), compact)
        XCTAssertEqual(withCompact.resolvedNode(for: .minimal), .text(.init("Focus")))

        let expandedOnly = ActivityPresentation(title: "Focus", expanded: .vStack(.init([
            .text(.init("Expanded")), .progress(.init(0.2))
        ])))
        XCTAssertEqual(expandedOnly.resolvedNode(for: .compact), .hStack(.init([.text(.init("Focus"))])))
    }

    func testInvalidOrOverComplexLayoutsUseSafeFallback() {
        let invalidMinimal: IslandNode = .text(.init(String(repeating: "x", count: 300)))
        let invalidCompact: IslandNode = .vStack(.init([
            .text(.init("one")), .text(.init("two"))
        ]))
        let oversizedExpanded: IslandNode = .vStack(.init(
            Array(repeating: .text(.init("row")), count: 8)
        ))
        let presentation = ActivityPresentation(
            title: "Focus", symbolName: "timer", minimal: invalidMinimal,
            compact: invalidCompact, expanded: oversizedExpanded
        )
        XCTAssertEqual(presentation.resolvedNode(for: .minimal), .icon(.init("timer")))
        XCTAssertEqual(presentation.resolvedNode(for: .compact), .hStack(.init([
            .icon(.init("timer")), .text(.init("Focus"))
        ])))
        XCTAssertEqual(presentation.resolvedNode(for: .expanded), .vStack(.init([
            .hStack(.init([.icon(.init("timer")), .text(.init("Focus"))]))
        ])))

        let blank = ActivityPresentation(title: "Focus", compact: .hStack(.init([
            .spacer(.init()), .divider(.init())
        ])))
        XCTAssertEqual(blank.resolvedNode(for: .compact), .hStack(.init([.text(.init("Focus"))])))
    }

    func testTimerProvidesAllThreeFormsWithoutWindowDimensions() throws {
        let minimal: IslandNode = .icon(.init("timer"))
        let compact: IslandNode = .hStack(.init([
            .icon(.init("timer")), .text(.init("24:58"))
        ]))
        let expanded: IslandNode = .vStack(.init([
            .hStack(.init([
                .icon(.init("timer")), .text(.init("Focus 24:58")),
                .spacer(.init()),
                .button(.init(actionID: "timer.pause", label: .icon(.init("pause.fill"))))
            ])),
            .progress(.init(0.42))
        ]))
        let presentation = ActivityPresentation(
            title: "Focus", subtitle: "24:58 left", symbolName: "timer", progress: 0.42,
            minimal: minimal, compact: compact, expanded: expanded
        )

        for (mode, expected) in [(ActivityPresentation.Mode.minimal, minimal),
                                 (.compact, compact), (.expanded, expanded)] {
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(expected, for: mode))
            XCTAssertEqual(presentation.resolvedNode(for: mode), expected)
        }
        let data = try JSONEncoder().encode(presentation)
        XCTAssertEqual(try JSONDecoder().decode(ActivityPresentation.self, from: data), presentation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["width"])
        XCTAssertNil(object["height"])
    }

    func testHostOwnsExpandedShellAndContentHeightBounds() {
        let chrome = Double(2 * IslandVisualStyle.expandedContentPadding
                            + IslandVisualStyle.expandedSurfaceSwitcherHeight
                            + IslandVisualStyle.expandedSurfaceSpacing)
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedChromeHeight, chrome)
        XCTAssertEqual(ActivityPresentation.HostPolicy.maximumExpandedShellHeight,
                       Double(IslandVisualStyle.expandedMusicHeight))
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: 200), 140)
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: 190), 130)
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: 500), 140)
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: 20), 0)
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: .nan), 0)
    }

    func testArtworkIsExpandedOnlyAndBoundedToOneImage() {
        let artwork: IslandNode = .image(.init(source: .brokerResource(id: "music.artwork"), size: .artwork))
        let thumbnail: IslandNode = .image(.init(source: .brokerResource(id: "music.artwork"), size: .thumbnail))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(artwork, for: .minimal))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(artwork, for: .compact))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(artwork, for: .expanded))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(.hStack(.init([artwork, artwork])), for: .expanded))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(thumbnail, for: .minimal))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(thumbnail, for: .compact))

        let compactMusic: IslandNode = .hStack(.init([
            thumbnail, .text(.init("Song")), .icon(.init("waveform")),
            .button(.init(actionID: "music.playPause", label: .icon(.init("pause.fill"))))
        ]))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(compactMusic, for: .compact))

        let presentation = ActivityPresentation(title: "Song", compact: artwork, expanded: artwork)
        XCTAssertEqual(presentation.resolvedNode(for: .compact), .hStack(.init([.text(.init("Song"))])))
        XCTAssertEqual(presentation.resolvedNode(for: .expanded), artwork)
    }

    func testUntitledSliderUsesOneRowAndMusicCanExposeEightActions() {
        let rows = Array(repeating: IslandNode.text(.init("Row")), count: 6)
        let titled: IslandNode = .vStack(.init(rows + [
            .slider(.init(title: "Seek", value: 0.5, actionID: "music.seek"))
        ]))
        let untitled: IslandNode = .vStack(.init(rows + [
            .slider(.init(title: "Seek", value: 0.5, actionID: "music.seek", showsTitle: false))
        ]))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(titled, for: .expanded))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(untitled, for: .expanded))

        let controls: IslandNode = .vStack(.init([.hStack(.init((0..<4).map { index in
            .button(.init(actionID: "music.action\(index)", label: .icon(.init("play.fill"))))
        })), .hStack(.init((4..<8).map { index in
            .button(.init(actionID: "music.action\(index)", label: .icon(.init("play.fill"))))
        }))]))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(controls, for: .expanded))
        let tooMany: IslandNode = .vStack(.init([controls, .button(.init(
            actionID: "music.action8", label: .icon(.init("play.fill"))
        ))]))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(tooMany, for: .expanded))
    }

    func testAccessibilityLabelsCountTowardExpandedTextBudget() {
        let oversized = IslandNode.button(.init(
            actionID: "music.next",
            label: .icon(.init("forward.fill")),
            accessibilityLabel: String(repeating: "x", count: IslandNode.Limits.maxTextBytes)
        ))
        let tree = IslandNode.hStack(.init([oversized, oversized, .text(.init("x"))]))

        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(tree, for: .expanded))
    }
}
