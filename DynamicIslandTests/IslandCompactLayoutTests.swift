import AppKit
import Combine
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCompactLayoutTests: XCTestCase {
    private let base = CGSize(width: 179, height: 32)

    func testAsymmetricWingsKeepBothCameraEdgesAtTheirOriginalPositions() {
        let layout = IslandCompactLayout.nativeTimer(baseSize: base, textWidth: 58)
        XCTAssertEqual(layout.leadingWidth, 38)
        XCTAssertEqual(layout.trailingWidth, 70)
        XCTAssertEqual(layout.centerOffset, 16)
        for cameraCenter in [CGFloat(-620), 0, 735] {
            let shellOrigin = cameraCenter + layout.centerOffset - layout.size.width / 2
            XCTAssertEqual(shellOrigin + layout.leadingWidth, cameraCenter - base.width / 2,
                           accuracy: 0.000_001)
            XCTAssertEqual(shellOrigin + layout.size.width - layout.trailingWidth,
                           cameraCenter + base.width / 2, accuracy: 0.000_001)
        }
    }

    func testVolumeReservesFull100PercentWithoutBreathingAtDigitTransitions() {
        let layouts = ["0%", "9%", "10%", "99%", "100%"].map { percentage in
            IslandCompactLayout.activity(baseSize: base, presentation: .init(
                title: "Volume", compact: .hStack(.init([
                    .icon(.init("speaker.wave.3.fill")), .spacer(.init()), .text(.init(percentage))
                ]))
            ), reservesPercentageWidth: true)
        }
        for layout in layouts {
            XCTAssertEqual(layout, layouts[0])
            XCTAssertEqual(layout.leadingWidth, 28)
            XCTAssertEqual(layout.trailingWidth, measuredCaption("100%") + 12)
            XCTAssertLessThan(layout.leadingWidth + layout.trailingWidth, 96)
            XCTAssertFalse(layout.usesMinimalPresentation)
        }
    }

    func testBatteryRetainsFullGaugeAndPercentageWhileMeasuringTheActualTitle() {
        let charging = batteryLayout(title: "正在充电", percentage: "72%")
        let full = batteryLayout(title: "正在充电", percentage: "100%")
        let critical = batteryLayout(title: "电量严重不足", percentage: "8%")
        XCTAssertEqual(charging, full)
        XCTAssertEqual(charging.leadingWidth, measuredCaption("正在充电") + 12)
        XCTAssertEqual(charging.trailingWidth, measuredCaption("100%") + 4 + 47 + 12)
        XCTAssertGreaterThan(critical.leadingWidth, charging.leadingWidth)
        XCTAssertEqual(critical.trailingWidth, charging.trailingWidth)
        XCTAssertLessThan(charging.leadingWidth + charging.trailingWidth, 200)
        XCTAssertNil(charging.fallbackMinimalNode)
    }

    func testMusicKeepsThe26PointThumbnailAnd16PointWaveform() {
        let layout = IslandCompactLayout.activity(baseSize: base, presentation: .init(
            title: "Music", compact: .hStack(.init([
                .image(.init(source: .brokerResource(id: "artwork"), size: .thumbnail)),
                .spacer(.init()), .icon(.init("waveform"))
            ]))
        ))
        XCTAssertEqual(layout.leadingWidth, 38)
        XCTAssertEqual(layout.trailingWidth, 28)
        XCTAssertEqual(layout.centerOffset, -5)
        XCTAssertEqual(layout.size, CGSize(width: 245, height: 32))
    }

    func testMinimalUsesOnlyTheTrailingWingAndKeepsBothRendererInsets() {
        let layout = IslandCompactLayout.activity(baseSize: base, presentation: .init(
            title: "Status", minimal: .icon(.init("checkmark"))
        ))
        XCTAssertTrue(layout.usesMinimalPresentation)
        XCTAssertEqual(layout.leadingWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 36)
        XCTAssertEqual(layout.centerOffset, 18)
        XCTAssertGreaterThanOrEqual(
            IslandRenderer.contentSize(for: .minimal,
                                       shellSize: CGSize(width: layout.trailingWidth, height: 32)).width,
            20, "The 16 pt icon keeps clearance after both 8 pt renderer insets."
        )
    }

    func testUnseparatedCompactContentUsesItsSafeMinimalLeaf() {
        let layout = IslandCompactLayout.activity(baseSize: base, presentation: .init(
            title: "Full status", minimal: .icon(.init("checkmark")),
            compact: .text(.init("A centered compact line"))
        ))
        XCTAssertTrue(layout.usesMinimalPresentation)
        XCTAssertEqual(layout.leadingWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 36)
        XCTAssertNil(layout.fallbackMinimalNode)
    }

    func testVeryLongAcceptedTreesAndMinimalTextCannotExceedHostWidth() {
        let wide = String(repeating: "W", count: 96)
        let compact: IslandNode = .hStack(.init([
            .icon(.init("timer")), .spacer(.init()), .text(.init(wide))
        ]))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(compact, for: .compact))
        for presentation in [
            ActivityPresentation(title: String(repeating: "W", count: 40), compact: compact),
            ActivityPresentation(title: "Minimal", minimal: .text(.init(String(repeating: "W", count: 40))))
        ] {
            let layout = IslandCompactLayout.activity(baseSize: base, presentation: presentation)
            XCTAssertLessThanOrEqual(layout.size.width, IslandVisualStyle.expandedShellSize.width)
            XCTAssertTrue(layout.usesMinimalPresentation)
            XCTAssertEqual(layout.leadingWidth, 0)
            XCTAssertEqual(layout.trailingWidth, 36)
            XCTAssertEqual(layout.fallbackMinimalNode, .icon(.init("ellipsis")))
        }
    }

    func testWideCameraFallbackDoesNotShrinkOrMoveTheCameraGap() {
        let wideBase = CGSize(width: 400, height: 38)
        let layout = IslandCompactLayout.nativeTimer(baseSize: wideBase, textWidth: 58)
        XCTAssertLessThanOrEqual(layout.size.width, IslandVisualStyle.expandedShellSize.width)
        XCTAssertTrue(layout.usesMinimalPresentation)
        XCTAssertEqual(layout.fallbackMinimalNode, .icon(.init("ellipsis")))
        XCTAssertEqual(layout.size.width - layout.leadingWidth - layout.trailingWidth, wideBase.width)
    }

    func testLegalTwentyCharacterMinimalLeafCannotEscapeOneSideOfThePanel() {
        let node: IslandNode = .text(.init(String(repeating: "W", count: 20)))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: .minimal))
        XCTAssertLessThan(measuredCaption(String(repeating: "W", count: 20)) + 20,
                          IslandVisualStyle.expandedShellSize.width - base.width,
                          "This fixture fits the total width but overflows one side of the centered panel.")
        let layout = IslandCompactLayout.activity(baseSize: base,
                                                  presentation: .init(title: "Wide minimal", minimal: node))
        XCTAssertEqual(layout.fallbackMinimalNode, .icon(.init("ellipsis")))
        let shellMinimum = layout.centerOffset - layout.size.width / 2
        let shellMaximum = layout.centerOffset + layout.size.width / 2
        XCTAssertGreaterThanOrEqual(shellMinimum, -IslandPanelGeometry.expandedSize.width / 2)
        XCTAssertLessThanOrEqual(shellMaximum, IslandPanelGeometry.expandedSize.width / 2)
        XCTAssertEqual(layout.leadingWidth, 0)
    }

    func testCountdownWidthUsesEmittedValuesAndOnlyPublishesAtFormatTransitions() {
        let model = IslandViewModel.preview()
        let timer = model.timerTools
        var widths: [CGFloat] = []
        var parentChanges = 0
        let widthObservation = model.$compactTimerTextWidth.sink { widths.append($0) }
        let parentObservation = model.objectWillChange.sink { parentChanges += 1 }
        defer { widthObservation.cancel(); parentObservation.cancel() }
        timer.selectedMode = .countdown
        timer.adjustCountdownMinutes(by: 115)
        let start = Date()
        timer.startSelectedTimer(at: start)
        XCTAssertEqual(model.compactTimerTextWidth, 58)
        let unchangedParentCount = parentChanges
        for second in 1...9 { timer.refresh(at: start.addingTimeInterval(TimeInterval(second))) }
        XCTAssertEqual(widths, [0, 58])
        XCTAssertEqual(parentChanges, unchangedParentCount,
                       "Timer ticks must not redraw the parent while their text width is unchanged.")
        timer.refresh(at: start.addingTimeInterval(3601))
        XCTAssertEqual(timer.compactTimeText, "59:59")
        XCTAssertEqual(model.compactTimerTextWidth, measuredNative("59:59"))
        XCTAssertEqual(widths.count, 3, "A long-to-short transition publishes the delivered new width once.")
        let shortParentCount = parentChanges
        timer.refresh(at: start.addingTimeInterval(3602))
        XCTAssertEqual(parentChanges, shortParentCount)
        timer.pauseSelectedTimer(at: start.addingTimeInterval(3602))
        timer.resetSelectedTimer()
        XCTAssertEqual(model.compactTimerTextWidth, 0)
    }

    func testStopwatchFractionalTicksStayInOneNaturalWidthBucket() {
        let model = IslandViewModel.preview()
        let timer = model.timerTools
        var widths: [CGFloat] = []
        let observation = model.$compactTimerTextWidth.sink { widths.append($0) }
        defer { observation.cancel() }
        let start = Date()
        timer.startSelectedTimer(at: start)
        XCTAssertEqual(model.compactTimerTextWidth, measuredNative("00:00.0"))
        for tenth in 1...12 { timer.refresh(at: start.addingTimeInterval(Double(tenth) / 10)) }
        XCTAssertEqual(widths.count, 2)
        timer.refresh(at: start.addingTimeInterval(6000))
        XCTAssertEqual(timer.compactTimeText, "100:00.0")
        XCTAssertEqual(model.compactTimerTextWidth, 58)
        XCTAssertEqual(widths.count, 3)
        timer.pauseSelectedTimer(at: start.addingTimeInterval(6000))
    }

    private func batteryLayout(title: String, percentage: String) -> IslandCompactLayout {
        IslandCompactLayout.activity(baseSize: base, presentation: .init(
            title: title, compact: .hStack(.init([
                .text(.init(title)), .spacer(.init()), .text(.init(percentage)),
                .progress(.init(1, style: .battery))
            ]))
        ), reservesPercentageWidth: true)
    }

    private func measuredCaption(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption2, options: [:]).pointSize, weight: .medium
        )
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    private func measuredNative(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text,
                                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)])
            .size().width)
    }
}
