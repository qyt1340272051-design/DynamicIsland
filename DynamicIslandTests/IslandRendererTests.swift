import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandRendererTests: XCTestCase {
    func testAllTwelveNodeKindsRenderInOneAcceptedTree() throws {
        let tree: IslandNode = .vStack(.init([
            .hStack(.init([
                .text(.init("Now Playing")), .icon(.init("music.note")),
                .image(.init(source: .systemSymbol(name: "play.fill"))),
                .image(.init(source: .pluginAsset(id: "cover"))),
                .image(.init(source: .brokerResource(id: "artwork"))),
                .spacer(.init()), .divider(.init())
            ])),
            .zStack(.init([.progress(.init(0.5)), .text(.init("Halfway"))])),
            .hStack(.init([
                .button(.init(actionID: "music.pause", label: .text(.init("Pause")))),
                .toggle(.init(title: "Loop", isOn: true, actionID: "music.loop"))
            ])),
            .slider(.init(title: "Volume", value: 0.4, actionID: "music.volume"))
        ]))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(tree, for: .expanded))

        var resolvedSources: [IslandNode.ImageSource] = []
        let renderer = IslandRenderer(
            presentation: ActivityPresentation(title: "Music", expanded: tree),
            mode: .expanded, shellSize: CGSize(width: 480, height: 200),
            imageResolver: { source in
                resolvedSources.append(source)
                return NSImage(size: CGSize(width: 20, height: 20))
            }
        )
        let bitmap = try render(renderer, size: CGSize(width: 456, height: 140))
        XCTAssertGreaterThan(visiblePixelCount(bitmap), 0)
        XCTAssertTrue(resolvedSources.contains(.pluginAsset(id: "cover")))
        XCTAssertTrue(resolvedSources.contains(.brokerResource(id: "artwork")))
        XCTAssertFalse(resolvedSources.contains(.systemSymbol(name: "play.fill")))
    }

    func testInvalidTreeResolvesToSafeSummary() throws {
        let invalid: IslandNode = .text(.init(String(repeating: "x", count: 300)))
        let presentation = ActivityPresentation(title: "Safe activity", minimal: invalid)
        XCTAssertEqual(
            IslandRenderer.resolvedNode(in: presentation, for: .minimal),
            .text(.init("Safe activity"))
        )
        let bitmap = try render(
            IslandRenderer(presentation: presentation, mode: .minimal,
                           shellSize: CGSize(width: 150, height: 32)),
            size: CGSize(width: 134, height: 32)
        )
        XCTAssertGreaterThan(visiblePixelCount(bitmap), 0)
    }

    func testSameHostingViewChangesAllThreePresentations() async throws {
        let state = RenderState()
        let hostingView = NSHostingView(rootView: RendererDriver(state: state)
            .environment(\.colorScheme, .dark))
        hostingView.frame = CGRect(x: 0, y: 0, width: 480, height: 200)
        let window = makeWindow(hostingView)
        defer { window.close() }

        var images: [Data] = []
        for mode in ActivityPresentation.Mode.allCases {
            state.mode = mode
            try await Task.sleep(nanoseconds: 300_000_000)
            let bitmap = try capture(hostingView, size: hostingView.bounds.size)
            images.append(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        }
        XCTAssertEqual(Set(images).count, 3)
    }

    func testExpandedShellHeightsBoundRenderedContent() throws {
        for (shellHeight, expectedContentHeight) in [(152.0, 92.0), (190.0, 130.0), (200.0, 140.0)] {
            let shell = CGSize(width: 480, height: shellHeight)
            let content = IslandRenderer.contentSize(for: .expanded, shellSize: shell)
            XCTAssertEqual(content.width, 456)
            XCTAssertEqual(content.height, expectedContentHeight)

            let renderer = IslandRenderer(
                presentation: ActivityPresentation(title: "Timer", expanded: .vStack(.init([
                    .text(.init("Focus")), .progress(.init(0.25)),
                    .button(.init(actionID: "timer.pause", label: .text(.init("Pause")))),
                    .slider(.init(title: "Duration", value: 0.5, actionID: "timer.duration"))
                ]))),
                mode: .expanded, shellSize: shell
            )
            let bitmap = try render(renderer, size: content)
            XCTAssertEqual(bitmap.pixelsWide, Int(content.width))
            XCTAssertEqual(bitmap.pixelsHigh, Int(content.height))
            XCTAssertGreaterThan(visiblePixelCount(bitmap), 0)
        }
    }

    func testExpandedArtworkUsesHostSizeAndUntitledSliderStillRenders() throws {
        let artwork = NSImage(size: CGSize(width: 124, height: 124), flipped: false) { rect in
            NSColor.red.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let source = IslandNode.ImageSource.brokerResource(id: "music.artwork")
        let node: IslandNode = .image(.init(source: source, size: .artwork))
        let renderer = IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: node),
            mode: .expanded, shellSize: CGSize(width: 480, height: 200),
            imageResolver: { $0 == source ? artwork : nil }
        )
        let bitmap = try render(renderer, size: CGSize(width: 456, height: 140))
        let redPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.alphaComponent > 0.5
            }.count
        }
        XCTAssertGreaterThan(redPixels, 12_000)
        XCTAssertLessThan(redPixels, 124 * 124 + 1)

        let untitled = IslandNode.slider(.init(title: "Seek", value: 0.5,
                                               actionID: "music.seek", showsTitle: false))
        let sliderBitmap = try render(IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: untitled),
            mode: .expanded, shellSize: CGSize(width: 480, height: 200)
        ), size: CGSize(width: 456, height: 140))
        XCTAssertGreaterThan(visiblePixelCount(sliderBitmap), 0)
    }

    func testMissingArtworkIsDarkCardWithSmallCenteredSymbol() throws {
        let node: IslandNode = .image(.init(
            source: .brokerResource(id: "music.artwork"), size: .artwork
        ))
        let bitmap = try render(IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: node),
            mode: .expanded, shellSize: CGSize(width: 480, height: 200)
        ), size: CGSize(width: 456, height: 140))

        let cardPixel = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20))
        XCTAssertGreaterThan(cardPixel.alphaComponent, 0.03)
        XCTAssertLessThan(cardPixel.alphaComponent, 0.3)
        let brightPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let pixel = bitmap.colorAt(x: x, y: y) else { return false }
                return pixel.redComponent > 0.6 && pixel.greenComponent > 0.6
                    && pixel.blueComponent > 0.6 && pixel.alphaComponent > 0.5
            }.count
        }
        XCTAssertLessThan(brightPixels, 1_000)
    }

    func testIconButtonKeepsCircular28PointFootprint() throws {
        let button: IslandNode = .button(.init(
            actionID: "music.playPause", label: .icon(.init("pause.fill"))
        ))
        let bitmap = try render(IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: button),
            mode: .expanded, shellSize: CGSize(width: 480, height: 200)
        ), size: CGSize(width: 456, height: 140))
        let painted = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02
            }.count
        }
        XCTAssertGreaterThan(painted, 350)
        XCTAssertLessThan(painted, 750)
    }

    func testCompactBatteryProgressHasVisibleFootprintAndFillTracksLevel() throws {
        let levels = [0.0, 0.5, 0.73, 1.0]
        let shellSize = CGSize(width: 100, height: 24)
        let renderSize = IslandRenderer.contentSize(for: .compact, shellSize: shellSize)
        var fillCounts: [Int] = []
        var centerFillWidths: [Int] = []

        for level in levels {
            let node: IslandNode = .progress(.init(
                level,
                style: .battery,
                color: .success
            ))
            let bitmap = try render(IslandRenderer(
                presentation: ActivityPresentation(title: "Battery", compact: node),
                mode: .compact,
                shellSize: shellSize
            ), size: renderSize)

            fillCounts.append(successPixelCount(bitmap))
            centerFillWidths.append(successRunWidth(bitmap, y: bitmap.pixelsHigh / 2))
            let bounds = try XCTUnwrap(visibleBounds(bitmap), "Battery outline should be visible")
            XCTAssertGreaterThanOrEqual(bounds.width, 46, "compact battery width at \(level)")
            XCTAssertGreaterThanOrEqual(bounds.height, 19, "compact battery height at \(level)")
            XCTAssertLessThanOrEqual(neutralWhitePixelCount(bitmap), 1, "battery should not have a white outline")
        }

        XCTAssertEqual(fillCounts[0], 0)
        XCTAssertLessThan(fillCounts[0], fillCounts[1])
        XCTAssertLessThan(fillCounts[1], fillCounts[2])
        XCTAssertLessThan(fillCounts[2], fillCounts[3])
        XCTAssertEqual(centerFillWidths[0], 0)
        XCTAssertLessThanOrEqual(abs(centerFillWidths[1] - 21), 2)
        XCTAssertLessThanOrEqual(abs(centerFillWidths[2] - 31), 2)
        XCTAssertLessThanOrEqual(abs(centerFillWidths[3] - 42), 2)
    }

    func testSliderKeepsDragValueAcrossPresentationUpdatesAndCommitsFinalValue() {
        var interaction = IslandSliderInteractionState()
        interaction.beginEditing("music.seek")
        XCTAssertEqual(interaction.update("music.seek", value: 0.82, fallback: 0.1), 0.82)
        interaction.presentationDidChange()
        XCTAssertEqual(interaction.displayedValue(for: "music.seek", fallback: 0.12), 0.82)

        let committed = interaction.endEditing("music.seek", fallback: 0.12)
        XCTAssertEqual(IslandRenderActionValue.sliderCommit(committed), .sliderCommit(0.82))
        XCTAssertEqual(interaction.displayedValue(for: "music.seek", fallback: 0.12), 0.82)
        interaction.presentationDidChange()
        XCTAssertEqual(interaction.displayedValue(for: "music.seek", fallback: 0.83), 0.83)

        XCTAssertEqual(interaction.update("music.volume", value: 1.5, fallback: 0.5), 1)
        XCTAssertEqual(interaction.update("music.volume", value: .nan, fallback: 0.5), 0.5)
    }

    private func render<Content: View>(_ content: Content, size: CGSize) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = makeWindow(hostingView)
        defer { window.close() }
        return try capture(hostingView, size: size)
    }

    private func makeWindow<Content: View>(_ hostingView: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hostingView
        return window
    }

    private func capture<Content: View>(_ hostingView: NSHostingView<Content>, size: CGSize) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw RenderError.bitmapCreationFailed }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func visiblePixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
            }.count
        }
    }

    private func successPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return color.alphaComponent > 0.8
                    && color.greenComponent > color.redComponent + 0.15
                    && color.greenComponent > color.blueComponent + 0.10
            }.count
        }
    }

    private func successRunWidth(_ bitmap: NSBitmapImageRep, y: Int) -> Int {
        let matching = (0..<bitmap.pixelsWide).filter { x in
            guard let color = bitmap.colorAt(x: x, y: y) else { return false }
            return color.alphaComponent > 0.8
                && color.greenComponent > color.redComponent + 0.15
                && color.greenComponent > color.blueComponent + 0.10
        }
        guard let first = matching.first, let last = matching.last else { return 0 }
        return last - first + 1
    }

    private func neutralWhitePixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return color.alphaComponent > 0.2
                    && color.redComponent > 0.65
                    && abs(color.redComponent - color.greenComponent) < 0.05
                    && abs(color.greenComponent - color.blueComponent) < 0.05
            }.count
        }
    }

    private func visibleBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var minimumX = bitmap.pixelsWide
        var maximumX = -1
        var minimumY = bitmap.pixelsHigh
        var maximumY = -1

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
            where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    private enum RenderError: Error { case bitmapCreationFailed }
}

@MainActor
private final class RenderState: ObservableObject {
    @Published var mode: ActivityPresentation.Mode = .minimal
    let presentation = ActivityPresentation(
        title: "Activity",
        minimal: .icon(.init("clock")),
        compact: .hStack(.init([.icon(.init("clock")), .text(.init("Compact"))])),
        expanded: .vStack(.init([.text(.init("Expanded")), .progress(.init(0.5))]))
    )
}

private struct RendererDriver: View {
    @ObservedObject var state: RenderState

    var body: some View {
        IslandRenderer(presentation: state.presentation, mode: state.mode,
                       shellSize: CGSize(width: 480, height: 200))
            .frame(width: 480, height: 200)
    }
}
