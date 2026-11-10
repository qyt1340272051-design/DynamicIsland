import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandMusicLongMetadataTests: XCTestCase {
    private let reportedTitle = "I Really Want to Stay at Your House"

    func testExpandedMusicKeepsArtworkAndControlsWithLongMetadata() async throws {
        let red = redArtwork()
        let service = MusicActivityTestService(info: .empty)
        let model = makeMusicActivityTestModel(music: service)
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let examples: [(String, NowPlayingInfo, Bool)] = [
            ("reported-with-cover", track(title: reportedTitle, artwork: red.tiffRepresentation), false),
            ("reported-missing-cover", track(title: reportedTitle), false),
            ("unicode-subtitle", .init(isPlaying: true, title: "夜に駆ける — 音楽の旅",
                artist: String(repeating: "歌手", count: 10), album: String(repeating: "曲", count: 12),
                duration: 300, position: 85, trackIdentifier: "unicode", artworkData: red.tiffRepresentation), false),
            ("error-subtitle", track(title: reportedTitle, artwork: red.tiffRepresentation), true)
        ]

        for (name, info, fails) in examples {
            await service.setError(nil)
            await service.setInfo(info)
            await model.refreshNowPlaying()
            if fails {
                await service.setError(.temporarilyUnavailable)
                await model.refreshNowPlaying()
            }
            try provider.synchronize()
            let presentation = try XCTUnwrap(manager.activity(id: MusicActivityProvider.activityID)?.presentation)
            XCTAssertLessThanOrEqual(presentation.subtitle?.utf8.count ?? 0, 128)
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(try XCTUnwrap(presentation.expanded), for: .expanded),
                          "The reported case is valid content, not a schema-budget fallback.")
            for scale in [CGFloat(0.88), 1.75 * IslandVisualStyle.expandedDensity] {
                let size = contentSize(scale: scale)
                let hosting = NSHostingView(rootView: AnyView(IslandRenderer(
                    presentation: presentation, mode: .expanded, shellSize: shellSize(scale: scale),
                    imageResolver: provider.resolveImage
                ).environment(\.islandLayoutScale, scale).environment(\.colorScheme, .dark)))
                hosting.frame = CGRect(origin: .zero, size: size)
                let window = makeWindow(hosting)
                let bitmap = try await capture(hosting)
                assertFullMusic(hosting, bitmap: bitmap, presentation: presentation,
                                hasArtwork: info.artworkData != nil, scale: scale,
                                context: "\(name)-\(scale)")
                window.close()
            }
        }
    }

    func testSameHostingViewKeepsControlsAcrossShortLongShortTrackChanges() async throws {
        let artwork = redArtwork()
        let service = MusicActivityTestService(info: .empty)
        let model = makeMusicActivityTestModel(music: service)
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let scale: CGFloat = 1.75 * IslandVisualStyle.expandedDensity
        let state = LongMetadataRenderState()
        let hosting = NSHostingView(rootView: LongMetadataRenderer(state: state,
            shellSize: shellSize(scale: scale), scale: scale))
        hosting.frame = CGRect(origin: .zero, size: contentSize(scale: scale))
        let window = makeWindow(hosting)
        defer { window.close() }

        for (index, title) in ["Short", reportedTitle, "Short again"].enumerated() {
            await service.setInfo(track(title: title, artwork: artwork.tiffRepresentation,
                                       artist: index == 1 ? "Rosa Walton / Hallie Coggins" : "Artist",
                                       album: index == 1 ? "Cyberpunk 2077: Radio, Vol. 2 (Original Soundtrack)" : "Album"))
            await model.refreshNowPlaying()
            try provider.synchronize()
            state.image = provider.resolveImage(.brokerResource(id: MusicActivityProvider.artworkResourceID))
            state.presentation = try XCTUnwrap(manager.activity(id: MusicActivityProvider.activityID)?.presentation)
            // Allow the renderer's authored 200 ms presentation transition to
            // finish before checking the same persistent native hosting view.
            try await Task.sleep(nanoseconds: 250_000_000)
            let bitmap = try await capture(hosting)
            assertFullMusic(hosting, bitmap: bitmap, presentation: state.presentation,
                            hasArtwork: true, scale: scale, context: "transition-\(index)")
        }
    }

    private func track(title: String, artwork: Data? = nil,
                       artist: String = "Rosa Walton / Hallie Coggins",
                       album: String = "Cyberpunk 2077: Radio, Vol. 2 (Original Soundtrack)") -> NowPlayingInfo {
        .init(isPlaying: true, title: title, artist: artist, album: album,
              duration: 300, position: 85, trackIdentifier: title, artworkData: artwork)
    }

    private func shellSize(scale: CGFloat) -> CGSize {
        CGSize(width: IslandVisualStyle.expandedContentSize.width * scale,
               height: IslandVisualStyle.expandedMusicHeight * scale)
    }

    private func contentSize(scale: CGFloat) -> CGSize {
        IslandRenderer.contentSize(for: .expanded, shellSize: shellSize(scale: scale), layoutScale: scale)
    }

    private func redArtwork() -> NSImage {
        NSImage(size: CGSize(width: 112, height: 112), flipped: false) { rectangle in
            NSColor.red.setFill()
            NSBezierPath(rect: rectangle).fill()
            return true
        }
    }

    private func assertFullMusic<Content: View>(_ hosting: NSHostingView<Content>, bitmap: NSBitmapImageRep,
                                               presentation: ActivityPresentation, hasArtwork: Bool,
                                               scale: CGFloat, context: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let labels = accessibilityLabels(hosting)
        let expectedLabels: Set<String> = ["上一首", "暂停", "下一首", "播放进度", "音量", "减小音量", "增大音量"]
        // Some App-hosted XCTest runs do not initialize SwiftUI's local AX
        // proxies. Always verify rendered controls below; additionally enforce
        // the complete AX contract whenever that backend exposes controls.
        if !labels.isDisjoint(with: expectedLabels) {
            for label in expectedLabels {
                XCTAssertTrue(labels.contains(label), "\(context): music control \(label) disappeared; labels=\(labels.sorted())",
                              file: file, line: line)
            }
            XCTAssertTrue(labels.contains(presentation.title),
                          "\(context): visual truncation must keep the complete bounded title available to accessibility.",
                          file: file, line: line)
        }
        if let expanded = presentation.expanded {
            let contract = renderedContract(expanded)
            XCTAssertTrue(contract.text.contains(presentation.title), file: file, line: line)
            let actions: Set<String> = [MusicActivityProvider.previousActionID, MusicActivityProvider.playPauseActionID,
                MusicActivityProvider.nextActionID, MusicActivityProvider.seekActionID, MusicActivityProvider.volumeActionID,
                MusicActivityProvider.volumeDownActionID, MusicActivityProvider.volumeUpActionID]
            XCTAssertTrue(actions.isSubset(of: contract.actions), "\(context): the authored control contract is incomplete.",
                          file: file, line: line)
        }
        // In a real short-metadata baseline these bands contain the timeline
        // and transport buttons, then the volume buttons/slider. A centered
        // title fallback paints nothing in either band, even without artwork.
        let detailStart = Int(ceil((112 + 4) * scale))
        for (name, lower, upper) in [("timeline/transport", 0.20, 0.55), ("volume", 0.55, 1.0)] {
            var painted = 0
            var widestSpan = 0
            for y in Int(Double(bitmap.pixelsHigh) * lower)..<Int(Double(bitmap.pixelsHigh) * upper) {
                var first: Int?
                var last = 0
                for x in detailStart..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                        painted += 1
                        first = first ?? x
                        last = x
                    }
                }
                if let first { widestSpan = max(widestSpan, last - first + 1) }
            }
            XCTAssertGreaterThan(CGFloat(painted), 80 * scale * scale,
                                 "\(context): \(name) controls are not painted.", file: file, line: line)
            XCTAssertGreaterThan(CGFloat(widestSpan), CGFloat(bitmap.pixelsWide - detailStart) * 0.7,
                                 "\(context): \(name) row lost its full-width control footprint.", file: file, line: line)
        }
        if scale >= 1.4 {
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US", "zh-Hans"]
                request.usesLanguageCorrection = false
                request.customWords = ["1:25", "5:00"]
                if let image = bitmap.cgImage {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    XCTAssertTrue(recognized.contains("1:25") && recognized.contains("5:00"),
                                  "\(context): both timeline labels must remain visible; OCR=\(recognized)", file: file, line: line)
                } else { XCTFail("\(context): bitmap lacks CGImage", file: file, line: line) }
            } catch { XCTFail("\(context): timeline OCR failed: \(error)", file: file, line: line) }
        }
        if hasArtwork {
            let redPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                    return color.redComponent > 0.7 && color.greenComponent < 0.3
                        && color.blueComponent < 0.3 && color.alphaComponent > 0.5
                }.count
            }
            let side = IslandDesignTokens.imageSide(.artwork, mode: .expanded, scale: scale)
            XCTAssertGreaterThan(CGFloat(redPixels), side * side * 0.8,
                                 "\(context): a title-only summary must not replace the music artwork and controls.",
                                 file: file, line: line)
        }
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Music-long-metadata-\(context)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func accessibilityLabels(_ root: NSView) -> Set<String> {
        var labels = Set<String>()
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            let object = value as AnyObject
            guard seen.count < 4_096, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let element = value as? NSAccessibilityProtocol {
                if let label = element.accessibilityLabel() { labels.insert(label) }
                if let title = element.accessibilityTitle() { labels.insert(title) }
                if let text = element.accessibilityValue() as? String { labels.insert(text) }
                element.accessibilityChildren()?.forEach(visit)
            }
            (value as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return labels
    }

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func renderedContract(_ node: IslandNode) -> (text: Set<String>, actions: Set<String>) {
        switch node {
        case .text(let text): return ([text.content], [])
        case .button(let button): return ([], [button.actionID])
        case .slider(let slider): return ([], [slider.actionID])
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            return stack.children.map(renderedContract).reduce(into: (Set<String>(), Set<String>())) { result, child in
                result.0.formUnion(child.text)
                result.1.formUnion(child.actions)
            }
        default: return ([], [])
        }
    }

    private func capture<Content: View>(_ hosting: NSHostingView<Content>) async throws -> NSBitmapImageRep {
        try await Task.sleep(nanoseconds: 100_000_000)
        let size = hosting.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}

@MainActor
private final class LongMetadataRenderState: ObservableObject {
    @Published var presentation = ActivityPresentation(title: "Initial")
    @Published var image: NSImage?
}

private struct LongMetadataRenderer: View {
    @ObservedObject var state: LongMetadataRenderState
    let shellSize: CGSize
    let scale: CGFloat

    var body: some View {
        IslandRenderer(presentation: state.presentation, mode: .expanded,
                       shellSize: shellSize, imageResolver: { _ in state.image })
            .environment(\.islandLayoutScale, scale)
            .environment(\.colorScheme, .dark)
    }
}
