import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandShellShapeTests: XCTestCase {
    func testExpansionAndSurfaceResizeKeepEveryAnimationFrameAttachedToTop() {
        for scale: CGFloat in [0.875, 1, 1.15625, 1.75] {
            let compact = IslandShellShape(
                size: CGSize(width: 179 * scale, height: 32 * scale),
                topCornerRadius: 0, bottomCornerRadius: 16 * scale
            )
            let music = IslandShellShape(
                size: CGSize(width: 440 * scale, height: 184 * scale),
                topCornerRadius: 26 * scale, bottomCornerRadius: 26 * scale
            )
            let stopwatch = IslandShellShape(
                size: CGSize(width: 440 * scale, height: 136 * scale),
                topCornerRadius: 26 * scale, bottomCornerRadius: 26 * scale
            )
            let canvas = CGRect(x: 0, y: 0, width: 520 * scale, height: 240 * scale)
            for (start, end) in [(compact, music), (music, compact), (music, stopwatch), (stopwatch, music)] {
                for progress in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
                    var frame = start
                    var delta = end.animatableData - start.animatableData
                    delta.scale(by: progress)
                    frame.animatableData = start.animatableData + delta
                    let path = frame.path(in: canvas)
                    let bounds = path.boundingRect
                    let expectedWidth = start.size.width + (end.size.width - start.size.width) * CGFloat(progress)
                    let expectedHeight = start.size.height + (end.size.height - start.size.height) * CGFloat(progress)

                    XCTAssertEqual(bounds.minY, 0, accuracy: 0.000_001,
                                   "Scale \(scale), progress \(progress) must not open a gap below the screen top.")
                    // CGPath stores these interpolated bounds with float-level
                    // precision; the top-edge invariant above remains strict.
                    XCTAssertEqual(bounds.midX, canvas.midX, accuracy: 0.000_1)
                    XCTAssertEqual(bounds.width, expectedWidth, accuracy: 0.000_1)
                    XCTAssertEqual(bounds.height, expectedHeight, accuracy: 0.000_1)
                    XCTAssertTrue(path.contains(CGPoint(x: canvas.midX, y: 0.25 * scale)),
                                  "The shell's top center must stay painted while its height changes.")
                }
            }
        }
    }

    func testShellUsesContainerTopInsteadOfCenteringItsHeight() {
        let canvas = CGRect(x: 20, y: 40, width: 520, height: 240)
        let shell = IslandShellShape(size: CGSize(width: 440, height: 136),
                                     topCornerRadius: 26, bottomCornerRadius: 26)
        let bounds = shell.path(in: canvas).boundingRect

        XCTAssertEqual(bounds.minY, canvas.minY)
        XCTAssertEqual(bounds.midX, canvas.midX)
        XCTAssertEqual(bounds.maxY, canvas.minY + 136)
    }
}
