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
            Array(repeating: .text(.init("row")), count: 6)
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
}
