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
