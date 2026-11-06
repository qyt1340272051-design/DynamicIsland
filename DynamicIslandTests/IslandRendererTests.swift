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
            mode: .expanded, shellSize: CGSize(width: 428, height: 184),
            imageResolver: { source in
                resolvedSources.append(source)
                return NSImage(size: CGSize(width: 20, height: 20))
            }
        )
        let bitmap = try render(renderer, size: CGSize(width: 412, height: 134))
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
        hostingView.frame = CGRect(x: 0, y: 0, width: 428, height: 184)
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
        for (shellHeight, expectedContentHeight) in [(136.0, 86.0), (174.0, 124.0), (184.0, 134.0)] {
            let shell = CGSize(width: 428, height: shellHeight)
            let content = IslandRenderer.contentSize(for: .expanded, shellSize: shell)
            XCTAssertEqual(content.width, 412)
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

    func testMinimalRegionUsesOnlyTheUnobstructedRightWing() {
        let shell = CGSize(width: 396, height: 32)
        XCTAssertEqual(IslandRenderer.collapsedRegionSize(
            for: .minimal, shellSize: shell, reservedCenterWidth: 270
        ), CGSize(width: 63, height: 32))
        XCTAssertEqual(IslandRenderer.collapsedRegionSize(
            for: .compact, shellSize: shell, reservedCenterWidth: 270
        ), shell)
        XCTAssertEqual(IslandRenderer.collapsedRegionSize(
            for: .minimal, shellSize: CGSize(width: 240, height: 32), reservedCenterWidth: 270
        ), CGSize(width: 0, height: 32), "Never paint a minimal leaf over a wider physical cutout.")
        XCTAssertEqual(IslandRenderer.collapsedRegionSize(
            for: .minimal, shellSize: shell, reservedCenterWidth: .nan
        ), .zero)
    }

    func testExpandedArtworkUsesHostSizeAndUntitledSliderStillRenders() throws {
        let artwork = NSImage(size: CGSize(width: 112, height: 112), flipped: false) { rect in
            NSColor.red.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let source = IslandNode.ImageSource.brokerResource(id: "music.artwork")
        let node: IslandNode = .image(.init(source: source, size: .artwork))
        let renderer = IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: node),
            mode: .expanded, shellSize: CGSize(width: 428, height: 184),
            imageResolver: { $0 == source ? artwork : nil }
        )
        let bitmap = try render(renderer, size: CGSize(width: 412, height: 134))
        let redPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
            count + (0..<bitmap.pixelsWide).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.alphaComponent > 0.5
            }.count
        }
        XCTAssertGreaterThan(redPixels, 12_000)
        XCTAssertLessThan(redPixels, 112 * 112 + 1)

        let untitled = IslandNode.slider(.init(title: "Seek", value: 0.5,
                                               actionID: "music.seek", showsTitle: false))
        let sliderBitmap = try render(IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: untitled),
            mode: .expanded, shellSize: CGSize(width: 428, height: 184)
        ), size: CGSize(width: 412, height: 134))
        XCTAssertGreaterThan(visiblePixelCount(sliderBitmap), 0)
    }

    func testMissingArtworkIsDarkCardWithSmallCenteredSymbol() throws {
        let node: IslandNode = .image(.init(
            source: .brokerResource(id: "music.artwork"), size: .artwork
        ))
        let bitmap = try render(IslandRenderer(
            presentation: ActivityPresentation(title: "Song", expanded: node),
            mode: .expanded, shellSize: CGSize(width: 428, height: 184)
        ), size: CGSize(width: 412, height: 134))

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
            mode: .expanded, shellSize: CGSize(width: 428, height: 184)
        ), size: CGSize(width: 412, height: 134))
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

    func testContentBudgetUnscalesActualShellBeforeApplyingHostChrome() {
        for scale in [CGFloat(0.875), 1, 1.75] {
            let expanded = IslandRenderer.contentSize(
                for: .expanded, shellSize: CGSize(width: 428 * scale, height: 184 * scale),
                layoutScale: scale
            )
            XCTAssertEqual(expanded.width, 412 * scale, accuracy: 0.000_001)
            XCTAssertEqual(expanded.height, 134 * scale, accuracy: 0.000_001)
            let compact = IslandRenderer.contentSize(
                for: .compact, shellSize: CGSize(width: 120 * scale, height: 32 * scale),
                layoutScale: scale
            )
            XCTAssertEqual(compact.width, 104 * scale, accuracy: 0.000_001)
            XCTAssertEqual(compact.height, 32 * scale, accuracy: 0.000_001)
        }
    }

    func testBatteryPaintAndFillResolveAtFinalDisplayPoints() throws {
        for scale in [CGFloat(0.875), 1.75] {
            let shell = CGSize(width: 120 * scale, height: 32 * scale)
            let size = IslandRenderer.contentSize(for: .compact, shellSize: shell, layoutScale: scale)
            let node: IslandNode = .progress(.init(0.5, style: .battery, color: .success))
            let bitmap = try render(IslandRenderer(
                presentation: .init(title: "Battery", compact: node), mode: .compact, shellSize: shell
            ).environment(\.islandLayoutScale, scale), size: size)
            let bounds = try XCTUnwrap(visibleBounds(bitmap))
            XCTAssertEqual(bounds.width / scale, 47, accuracy: 2)
            XCTAssertEqual(bounds.height / scale, 20, accuracy: 2)
            XCTAssertEqual(CGFloat(successRunWidth(bitmap, y: bitmap.pixelsHigh / 2)) / scale,
                           21, accuracy: 2)
        }
    }

    func testHighLogicalTextAndCountdownMatchNativeFinalFontPixels() throws {
        // This models the 2560×1664 / 56 pt camera strip at backing 1.
        // A native-font reference and an explicitly enlarged low-resolution
        // positive control distinguish crisp rendering from a matching bbox.
        let scale: CGFloat = 1.75
        let designSize = CGSize(width: 104, height: 40)
        let finalSize = CGSize(width: 182, height: 70)
        let preferredSize = NSFont.preferredFont(forTextStyle: .caption2, options: [:]).pointSize
        let clock = IslandCountdownDisplayClock()
        defer { clock.shutdown() }
        for isCountdown in [false, true] {
            let sample = isCountdown ? "24:00:00" : "H8 12:34"
            let node: IslandNode = isCountdown
                ? .countdown(.init(id: "probe", generation: "12345678-1234-1234-1234-123456789abc", style: .time))
                : .text(.init(sample))
            let actual = try render(IslandRenderer(
                presentation: .init(title: sample, compact: node), mode: .compact,
                shellSize: CGSize(width: 210, height: 70),
                countdownResolver: { _ in .init(text: sample, progress: 0.5, requiresTick: false) },
                displayClock: clock
            ).environment(\.islandLayoutScale, scale), size: finalSize)
            let native = try render(textProbe(sample, pointSize: preferredSize * scale,
                                               monospacedDigits: isCountdown, size: finalSize), size: finalSize)
            let lowResolution = try render(textProbe(sample, pointSize: preferredSize,
                                                     monospacedDigits: isCountdown, size: designSize), size: designSize)
            let enlargedImage = NSImage(cgImage: try XCTUnwrap(lowResolution.cgImage), size: designSize)
            let enlarged = try render(Image(nsImage: enlargedImage).resizable().interpolation(.high)
                .frame(width: finalSize.width, height: finalSize.height), size: finalSize)
            let nativeError = minimumAlphaDifference(actual, native)
            let enlargedError = minimumAlphaDifference(enlarged, native)
            XCTAssertLessThan(nativeError, 0.006, "Final font must match native pixels: \(sample)")
            XCTAssertGreaterThan(enlargedError, nativeError + 0.002,
                                 "Positive control must detect enlarging a low-resolution font bitmap.")
            for (name, bitmap) in [("actual", actual), ("native-reference", native), ("enlarged-control", enlarged)] {
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "High-logical-1x-\(isCountdown ? "countdown" : "text")-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(clock.consumerCount, 0, "Static raster probes must not start display polling.")
    }

    func testSemanticFontBaselinesMatchAppKitPreferredPointSizes() throws {
        let mappings: [(IslandTypographyToken, NSFont.TextStyle, Font.Weight, Font.Design)] = [
            (.caption, .caption2, .medium, .default),
            (.body, .caption1, .regular, .default),
            (.headline, .subheadline, .semibold, .default),
            (.title, .headline, .semibold, .default),
            (.metric, .title1, .semibold, .monospaced)
        ]
        let size = CGSize(width: 220, height: 64)
        for (token, style, weight, design) in mappings {
            let semantic = try render(fontBaselineProbe(IslandDesignTokens.font(for: token)), size: size)
            let preferredSize = NSFont.preferredFont(forTextStyle: style, options: [:]).pointSize
            let preferred = try render(fontBaselineProbe(.system(size: preferredSize, weight: weight, design: design)),
                                       size: size)
            let coverage = alphaCoverage(semantic)
            let preferredError = minimumAlphaDifference(semantic, preferred) / max(coverage, 0.000_001)
            var bestSize = preferredSize
            var bestError = preferredError
            var best = preferred
            if preferredError > 0.01 {
                for step in -12...12 where step != 0 {
                    let candidateSize = preferredSize + CGFloat(step) * 0.5
                    guard candidateSize > 0 else { continue }
                    let candidate = try render(fontBaselineProbe(.system(size: candidateSize, weight: weight, design: design)),
                                               size: size)
                    let error = minimumAlphaDifference(semantic, candidate) / max(coverage, 0.000_001)
                    if error < bestError { bestSize = candidateSize; bestError = error; best = candidate }
                }
            }
            for (name, bitmap) in [("semantic", semantic), ("appkit-preferred", preferred), ("best-native-match", best)] {
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "Font-baseline-\(token.rawValue)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let metrics = XCTAttachment(string:
                "token=\(token.rawValue) preferredSize=\(preferredSize) preferredError=\(preferredError) bestSize=\(bestSize) bestError=\(bestError)")
            metrics.name = "Font-baseline-metrics-\(token.rawValue)"
            metrics.lifetime = .keepAlways
            add(metrics)
            XCTAssertLessThan(preferredError, 0.01,
                              "Semantic \(token.rawValue): AppKit preferred \(preferredSize) pt differs; best native match \(bestSize) pt (error \(bestError)).")
        }
    }

    func testSemanticAndExplicitFontsHaveMatchingIntrinsicLineLayout() {
        let mappings: [(IslandTypographyToken, NSFont.TextStyle, Font.Weight, Font.Design)] = [
            (.caption, .caption2, .medium, .default),
            (.body, .caption1, .regular, .default),
            (.headline, .subheadline, .semibold, .default),
            (.title, .headline, .semibold, .default),
            (.metric, .title1, .semibold, .monospaced)
        ]
        for (token, style, weight, design) in mappings {
            let preferredSize = NSFont.preferredFont(forTextStyle: style, options: [:]).pointSize
            for lineCount in [1, 3] {
                let semantic = intrinsicTextSize(font: IslandDesignTokens.font(for: token), lineCount: lineCount)
                let explicit = intrinsicTextSize(font: .system(size: preferredSize, weight: weight, design: design),
                                                 lineCount: lineCount)
                let attachment = XCTAttachment(string:
                    "token=\(token.rawValue) lines=\(lineCount) preferredPointSize=\(preferredSize) semantic=\(semantic) explicit=\(explicit)")
                attachment.name = "Font-intrinsic-layout-\(token.rawValue)-\(lineCount)-lines"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(semantic.width, explicit.width, accuracy: 0.01, token.rawValue)
                XCTAssertEqual(semantic.height, explicit.height, accuracy: 0.01, token.rawValue)
            }
        }
    }

    func testNativeProgressAndSliderIntrinsicSizesUseDiscreteControlMetrics() {
        for scale in [CGFloat(0.875), 1, 1.15625, 1.75] {
            let progressSize: ControlSize = scale >= 1.5 ? .large : .regular
            let sliderSize: ControlSize = scale >= 1.5 ? .regular : scale > 1.05 ? .small : .mini
            let progress = NSHostingView(rootView: ProgressView(value: 0.5).progressViewStyle(.linear)
                .controlSize(progressSize).frame(width: 200 * scale).fixedSize(horizontal: false, vertical: true))
            let slider = NSHostingView(rootView: Slider(value: .constant(0.5), in: 0...1)
                .controlSize(sliderSize).frame(width: 200 * scale).fixedSize(horizontal: false, vertical: true))
            progress.layoutSubtreeIfNeeded()
            slider.layoutSubtreeIfNeeded()
            let progressMetrics = progress.fittingSize
            let sliderMetrics = slider.fittingSize
            let progressRow = NSHostingView(rootView: ProgressView(value: 0.5).progressViewStyle(.linear)
                .controlSize(progressSize).frame(width: 200 * scale, height: 20 * scale))
            let sliderRow = NSHostingView(rootView: Slider(value: .constant(0.5), in: 0...1)
                .controlSize(sliderSize).frame(width: 200 * scale, height: 12 * scale))
            progressRow.layoutSubtreeIfNeeded()
            sliderRow.layoutSubtreeIfNeeded()
            let attachment = XCTAttachment(string:
                "layoutScale=\(scale) progressControlSize=\(progressSize) progress=\(progressMetrics) progressDesignHeight=\(progressMetrics.height / scale) sliderControlSize=\(sliderSize) slider=\(sliderMetrics) sliderDesignHeight=\(sliderMetrics.height / scale)")
            attachment.name = "Native-control-intrinsic-layout-\(scale)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(progressMetrics.height, 0)
            XCTAssertGreaterThan(sliderMetrics.height, 0)
            // AppKit reports a whole-point fitting extent even though the
            // SwiftUI frame proposal can contain fractional display points.
            XCTAssertEqual(progressMetrics.width, ceil(200 * scale), accuracy: 0.01)
            XCTAssertEqual(sliderMetrics.width, ceil(200 * scale), accuracy: 0.01)
            XCTAssertEqual(progressRow.fittingSize.height, ceil(20 * scale), accuracy: 0.01,
                           "The Host progress row must reserve scaled design height independently of native intrinsic metrics.")
            XCTAssertEqual(sliderRow.fittingSize.height, ceil(12 * scale), accuracy: 0.01,
                           "The Host slider row must reserve scaled design height independently of native intrinsic metrics.")
        }
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

    private func textProbe(_ text: String, pointSize: CGFloat, monospacedDigits: Bool,
                           size: CGSize) -> some View {
        Group {
            if monospacedDigits { Text(text).monospacedDigit() }
            else { Text(text) }
        }
        .font(.system(size: pointSize, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: size.width, height: size.height)
    }

    private func minimumAlphaDifference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        // Integer-pixel registration tolerates harmless native origin rounding;
        // it cannot sharpen an enlarged bitmap or recreate its missing edges.
        var minimum = Double.infinity
        for offsetY in -1...1 {
            for offsetX in -1...1 {
                var difference = 0.0
                var count = 0
                for y in 1..<(lhs.pixelsHigh - 1) {
                    for x in 1..<(lhs.pixelsWide - 1) {
                        let a = lhs.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        let b = rhs.colorAt(x: x + offsetX, y: y + offsetY)?.alphaComponent ?? 0
                        difference += Double(abs(a - b))
                        count += 1
                    }
                }
                minimum = min(minimum, difference / Double(max(1, count)))
            }
        }
        return minimum
    }

    private func fontBaselineProbe(_ font: Font) -> some View {
        Text("HgMW 18:58")
            .font(font)
            .foregroundStyle(.white)
            .frame(width: 220, height: 64)
    }

    private func intrinsicTextSize(font: Font, lineCount: Int) -> CGSize {
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<lineCount, id: \.self) { _ in Text("HgMW 18:58") }
        }.font(font).fixedSize())
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    private func alphaCoverage(_ bitmap: NSBitmapImageRep) -> Double {
        var sum = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                sum += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return sum / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
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
                       shellSize: CGSize(width: 428, height: 184))
            .frame(width: 428, height: 184)
    }
}
