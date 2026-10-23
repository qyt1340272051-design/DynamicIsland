import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

final class ScreenSnapshotMatrixTests: XCTestCase {
    func testMatrixCoversEveryProfileAndRequiredIslandState() {
        XCTAssertEqual(SimulatedScreenProfile.allCases.count, 8)
        XCTAssertEqual(ScreenSnapshotScenario.allCases.count, 12)
        XCTAssertEqual(
            SimulatedScreenProfile.allCases.count * ScreenSnapshotScenario.allCases.count,
            96
        )
        XCTAssertEqual(ResolutionSnapshotFixture.allCases.count, 4)
        XCTAssertEqual((SimulatedScreenProfile.allCases.count + ResolutionSnapshotFixture.allCases.count)
                       * ScreenSnapshotScenario.allCases.count, 144)
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.compactVolume))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedVolume))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.compactBatteryCharging))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedBatteryLow))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedBatteryCritical))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedMusic))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedFileTray))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedToolsStopwatch))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedToolsCountdown))
    }

    @MainActor
    func testCompactBatteryContentRemainsVisibleOutsidePhysicalNotch() async throws {
        for environment in collapsedEnvironments {
            let context = try await makeContext(for: .compactBatteryCharging, environment: environment,
                                               usesWideContent: true)
            try assertCollapsedWings(context, environment: environment,
                                     minimumLeftWidth: 35, minimumRightWidth: 67.5)
        }
    }

    @MainActor
    func testCompactVolumeContentRemainsVisibleOutsidePhysicalNotch() async throws {
        for environment in collapsedEnvironments {
            let context = try await makeContext(for: .compactVolume, environment: environment)
            try assertCollapsedWings(context, environment: environment,
                                     minimumLeftWidth: 14, minimumRightWidth: 23)
        }
    }

    @MainActor
    func testScaledNativeTwoHourCountdownKeepsBothWingsOutsideCamera() async throws {
        for fixture in ResolutionSnapshotFixture.allCases {
            let environment = fixture.environment
            let context = try await makeContext(for: .compact, environment: environment)
            let timer = context.viewModel.timerTools
            timer.selectedMode = .countdown
            timer.adjustCountdownMinutes(by: 115)
            let start = Date()
            timer.startSelectedTimer(at: start)
            timer.pauseSelectedTimer(at: start)
            XCTAssertEqual(timer.compactTimeText, "02:00:00")
            try assertCollapsedWings(context, environment: environment,
                                     minimumLeftWidth: 5, minimumRightWidth: 35)
        }
    }

    @MainActor
    func testCameraGlyphProbeDetectsCenteredContentBeforeOverlayHidesIt() throws {
        let environment = ResolutionSnapshotFixture.allCases[0].environment
        let backing = environment.backingScaleFactor
        let compact = IslandPanelGeometry.compactFrame(in: environment).size
        let center = ScreenSnapshotCanvas.size.width * backing / 2
        let xRange = Int(ceil(center - compact.width * backing / 2))..<Int(floor(center + compact.width * backing / 2))
        let yRange = 0..<Int(compact.height * backing)

        func probe(overlaysNotch: Bool) throws -> NSBitmapImageRep {
            // Deliberately bypass Runtime's safe compact-to-minimal placement.
            // This positive control must be able to draw an unsafe centered
            // glyph, otherwise the camera-clearance pixel probe is untested.
            let canvas = ZStack(alignment: .top) {
                Color(red: 0.29, green: 0.29, blue: 0.31)
                IslandRenderer(presentation: .init(title: "CENTER", compact: .text(.init("CENTER"))),
                               mode: .compact, shellSize: compact)
                if overlaysNotch {
                    Rectangle().fill(Color.black).frame(width: compact.width, height: compact.height)
                }
            }
            .frame(width: ScreenSnapshotCanvas.size.width, height: ScreenSnapshotCanvas.size.height)
            .environment(\.colorScheme, .dark)
            let renderer = ScreenSnapshotRenderer(size: ScreenSnapshotCanvas.size)
            defer { renderer.close() }
            return try XCTUnwrap(NSBitmapImageRep(data: renderer.render(canvas, scale: backing).data))
        }

        let unmasked = try probe(overlaysNotch: false)
        XCTAssertNotNil(glyphBounds(in: unmasked, xRange: xRange, yRange: yRange),
                        "Positive control must detect incorrectly centered content.")
        let masked = try probe(overlaysNotch: true)
        XCTAssertNil(glyphBounds(in: masked, xRange: xRange, yRange: yRange),
                     "The simulated cutout conceals the error; geometry probes must use unmasked output.")
    }

    @MainActor
    func testExpandedPagesScaleTheirRenderedContentAcrossResolutionFixtures() async throws {
        let scenarios: [ScreenSnapshotScenario] = [
            .expandedMusic, .expandedFileTray, .expandedToolsStopwatch,
            .expandedToolsCountdown, .expandedBatteryLow, .expandedVolume
        ]
        for scenario in scenarios {
            var reference: CGRect?
            for fixture in ResolutionSnapshotFixture.allCases {
                let environment = fixture.environment
                let context = try await makeContext(for: scenario, environment: environment,
                                                   usesWideContent: true)
                let rendered = try renderedSnapshot(context, environment: environment, overlaysNotch: false)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: rendered.data))
                let glyphs = try XCTUnwrap(glyphBounds(in: bitmap), "\(fixture.id)/\(scenario.rawValue)")
                let layoutScale = context.viewModel.displayLayout.scale
                let pixelsPerDesignPoint = environment.backingScaleFactor * layoutScale
                let normalized = CGRect(
                    x: (glyphs.minX / environment.backingScaleFactor - ScreenSnapshotCanvas.size.width / 2)
                        / layoutScale,
                    y: glyphs.minY / pixelsPerDesignPoint,
                    width: glyphs.width / pixelsPerDesignPoint,
                    height: glyphs.height / pixelsPerDesignPoint
                )
                let imageAttachment = XCTAttachment(data: rendered.data, uniformTypeIdentifier: "public.png")
                imageAttachment.name = "Expanded-native-\(scenario.rawValue)-\(fixture.id)"
                imageAttachment.lifetime = .keepAlways
                add(imageAttachment)
                let metrics = XCTAttachment(string:
                    "fixture=\(fixture.id) scenario=\(scenario.rawValue) backing=\(environment.backingScaleFactor) layout=\(layoutScale) glyphs=\(glyphs) normalized=\(normalized) designShell=\(context.activityRuntime.expandedShellSize) chrome=\(ActivityPresentation.HostPolicy.expandedChromeHeight)")
                metrics.name = "Expanded-native-metrics-\(scenario.rawValue)-\(fixture.id)"
                metrics.lifetime = .keepAlways
                add(metrics)
                // A visible switcher alone is not sufficient: each actual page
                // must paint its body below the chrome, inside the scaled shell.
                XCTAssertGreaterThan(normalized.maxY, 75, scenario.rawValue)
                XCTAssertGreaterThan(normalized.width, 100, scenario.rawValue)
                XCTAssertGreaterThanOrEqual(normalized.minX, -IslandVisualStyle.expandedShellSize.width / 2,
                                            scenario.rawValue)
                XCTAssertLessThanOrEqual(normalized.maxX, IslandVisualStyle.expandedShellSize.width / 2,
                                         scenario.rawValue)
                XCTAssertLessThanOrEqual(normalized.maxY, IslandVisualStyle.expandedShellSize.height + 1,
                                         scenario.rawValue)
                if let reference {
                    XCTAssertEqual(normalized.minX, reference.minX, accuracy: 3, scenario.rawValue)
                    XCTAssertEqual(normalized.minY, reference.minY, accuracy: 3, scenario.rawValue)
                    XCTAssertEqual(normalized.width, reference.width, accuracy: 4, scenario.rawValue)
                    XCTAssertEqual(normalized.height, reference.height, accuracy: 4, scenario.rawValue)
                } else {
                    reference = normalized
                }
            }
        }
    }

    @MainActor
    func testBackingScaleChangesPixelsWithoutChangingPointLayout() async throws {
        let fixture = ResolutionSnapshotFixture.allCases[0]
        var reference: CGRect?
        for backingScale in [CGFloat(1), CGFloat(2)] {
            let environment = fixture.makeEnvironment(backingScale: backingScale)
            let context = try await makeContext(for: .expandedMusic, environment: environment)
            let image = try renderedSnapshot(context, environment: environment, overlaysNotch: false)
            XCTAssertEqual(image.pixelWidth, Int(ScreenSnapshotCanvas.size.width * backingScale))
            XCTAssertEqual(image.pixelHeight, Int(ScreenSnapshotCanvas.size.height * backingScale))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.data))
            let bounds = try XCTUnwrap(glyphBounds(in: bitmap))
            let points = CGRect(x: bounds.minX / backingScale, y: bounds.minY / backingScale,
                                width: bounds.width / backingScale, height: bounds.height / backingScale)
            if let reference {
                XCTAssertEqual(points.minX, reference.minX, accuracy: 2)
                XCTAssertEqual(points.minY, reference.minY, accuracy: 2)
                XCTAssertEqual(points.width, reference.width, accuracy: 3)
                XCTAssertEqual(points.height, reference.height, accuracy: 3)
            } else { reference = points }
        }
    }

    @MainActor
    func testHighLogicalResolutionFixtureUsesBackingOneWithoutChangingItsLayoutScale() {
        let fixture = ResolutionSnapshotFixture.allCases.last!
        XCTAssertEqual(fixture.id, "resolution-2560-backing1-synthetic")
        let environment = fixture.environment
        XCTAssertEqual(environment.frame.size, CGSize(width: 2560, height: 1664))
        XCTAssertEqual(environment.backingScaleFactor, 1)
        XCTAssertEqual(environment.auxiliaryTopLeftArea.height, 56)
        XCTAssertTrue(fixture.source.hasPrefix("SYNTHETIC:"))
        let layout = IslandDisplayLayout(environment: environment)
        XCTAssertEqual(layout.scale, 1.75, accuracy: 0.000_001)
        XCTAssertEqual(layout.compactSize, CGSize(width: 312, height: 56))
        XCTAssertEqual(layout.panelSize, CGSize(width: 910, height: 420))
    }

    func testGenerateSnapshotMatrix() async throws {
        guard ProcessInfo.processInfo.environment["SCREEN_MATRIX_GENERATE"] == "1" else {
            throw XCTSkip("Run Scripts/generate-screen-matrix.sh to generate the screenshot matrix.")
        }
        let variables = ProcessInfo.processInfo.environment
        let outputURL: URL
        if let path = variables["SCREEN_MATRIX_OUTPUT_DIR"] ?? variables["TEST_RUNNER_SCREEN_MATRIX_OUTPUT_DIR"] {
            guard path.hasPrefix("/") else { throw ScreenSnapshotRenderingError.invalidOutputDirectory }
            outputURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            outputURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("artifacts/screen-matrix", isDirectory: true)
                .appendingPathComponent("\(formatter.string(from: Date()))-\(UUID().uuidString)", isDirectory: true)
        }
        print("Generating screen matrix at \(outputURL.path)")
        try await generateSnapshotMatrix(at: outputURL)
    }

    @MainActor
    private func generateSnapshotMatrix(at outputDirectory: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectory.path),
           !(try fileManager.contentsOfDirectory(atPath: outputDirectory.path)).isEmpty {
            throw ScreenSnapshotRenderingError.outputDirectoryNotEmpty
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var records: [ScreenSnapshotRecord] = []
        let cases = SimulatedScreenProfile.allCases.map { profile in
            ScreenSnapshotCase(id: profile.rawValue, name: profile.displayName,
                               source: "Synthetic device profile; not physical-device evidence",
                               environment: profile.defaultConfiguration.makeEnvironment(),
                               isResolutionComparison: false)
        } + ResolutionSnapshotFixture.allCases.map { fixture in
            ScreenSnapshotCase(id: fixture.id, name: fixture.name, source: fixture.source,
                               environment: fixture.environment, isResolutionComparison: true)
        }
        for item in cases {
            let environment = item.environment
            let directory = outputDirectory.appendingPathComponent(item.id, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let canvasSize = item.isResolutionComparison
                ? CGSize(width: environment.frame.width,
                         height: max(ScreenSnapshotCanvas.size.height,
                                     IslandDisplayLayout(environment: environment).panelSize.height))
                : ScreenSnapshotCanvas.size
            for scenario in ScreenSnapshotScenario.allCases {
                let context = try await makeContext(for: scenario, environment: environment,
                                                   usesWideContent: item.isResolutionComparison)
                let rendered = try renderedSnapshot(context, environment: environment,
                                                    overlaysNotch: true, size: canvasSize)
                let relativePath = "\(item.id)/\(scenario.rawValue).png"
                try rendered.data.write(to: outputDirectory.appendingPathComponent(relativePath), options: .atomic)
                let compact = IslandPanelGeometry.compactFrame(in: environment).size
                let layout = context.viewModel.displayLayout
                records.append(ScreenSnapshotRecord(
                    profile: item.id, profileName: item.name, source: item.source,
                    isResolutionComparison: item.isResolutionComparison,
                    scenario: scenario.rawValue, scenarioName: scenario.displayName, file: relativePath,
                    logicalScreenWidth: Int(environment.frame.width.rounded()),
                    logicalScreenHeight: Int(environment.frame.height.rounded()),
                    scaleFactor: environment.backingScaleFactor, layoutScale: layout.scale,
                    notchWidth: compact.width, notchHeight: environment.hasNotch ? compact.height : 0,
                    canvasWidth: canvasSize.width, canvasHeight: canvasSize.height,
                    panelWidth: layout.panelSize.width, panelHeight: layout.panelSize.height,
                    imageWidth: rendered.pixelWidth, imageHeight: rendered.pixelHeight
                ))
            }
        }
        XCTAssertEqual(records.count, 144)
        try writeManifest(records: records, to: outputDirectory)
        try writeIndex(records: records, to: outputDirectory)
    }

    @MainActor
    private var collapsedEnvironments: [ScreenEnvironment] {
        [SimulatedScreenProfile.macBookAir13.defaultConfiguration.makeEnvironment()]
            + ResolutionSnapshotFixture.allCases.map(\.environment)
    }

    @MainActor
    private func renderedSnapshot(_ context: ScreenSnapshotContext, environment: ScreenEnvironment,
                                  overlaysNotch: Bool,
                                  size requestedSize: CGSize? = nil) throws -> ScreenSnapshotRenderer.RenderedImage {
        let size = requestedSize ?? CGSize(width: ScreenSnapshotCanvas.size.width,
                                          height: max(ScreenSnapshotCanvas.size.height,
                                                      context.viewModel.displayLayout.panelSize.height))
        let canvas = ScreenSnapshotCanvas(environment: environment, viewModel: context.viewModel,
                                          activityRuntime: context.activityRuntime,
                                          overlaysNotch: overlaysNotch, canvasSize: size)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let renderer = ScreenSnapshotRenderer(size: size)
        defer { renderer.close() }
        return try renderer.render(canvas, scale: environment.backingScaleFactor)
    }

    @MainActor
    private func snapshot(_ context: ScreenSnapshotContext, environment: ScreenEnvironment,
                          overlaysNotch: Bool) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: renderedSnapshot(context, environment: environment,
                                                            overlaysNotch: overlaysNotch).data))
    }

    @MainActor
    private func assertCollapsedWings(_ context: ScreenSnapshotContext, environment: ScreenEnvironment,
                                      minimumLeftWidth: CGFloat, minimumRightWidth: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        // Inspect before adding the simulated black cutout. Otherwise drawing
        // the cutout could conceal an actual centered-text regression.
        let bitmap = try snapshot(context, environment: environment, overlaysNotch: false)
        let backing = environment.backingScaleFactor
        let layoutScale = context.viewModel.displayLayout.scale
        let compact = IslandPanelGeometry.compactFrame(in: environment).size
        let center = ScreenSnapshotCanvas.size.width * backing / 2
        let notchMinimum = center - compact.width * backing / 2
        let notchMaximum = center + compact.width * backing / 2
        let bandHeight = min(bitmap.pixelsHigh, Int((compact.height * backing).rounded()))
        let left = try XCTUnwrap(glyphBounds(in: bitmap, xRange: 0..<Int(notchMinimum),
                                            yRange: 0..<bandHeight), file: file, line: line)
        let right = try XCTUnwrap(glyphBounds(in: bitmap, xRange: Int(ceil(notchMaximum))..<bitmap.pixelsWide,
                                             yRange: 0..<bandHeight), file: file, line: line)
        let centerGlyphs = glyphBounds(in: bitmap,
                                      xRange: Int(ceil(notchMinimum))..<Int(floor(notchMaximum)),
                                      yRange: 0..<bandHeight)
        XCTAssertNil(centerGlyphs, "Visible glyphs must not cross the physical camera cutout.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(left.width / (backing * layoutScale), minimumLeftWidth, file: file, line: line)
        XCTAssertGreaterThanOrEqual(right.width / (backing * layoutScale), minimumRightWidth, file: file, line: line)
        XCTAssertGreaterThanOrEqual((notchMinimum - left.maxX) / (backing * layoutScale), 3, file: file, line: line)
        XCTAssertGreaterThanOrEqual((right.minX - notchMaximum) / (backing * layoutScale), 3, file: file, line: line)
    }

    private func glyphBounds(in bitmap: NSBitmapImageRep, xRange: Range<Int>? = nil,
                             yRange: Range<Int>? = nil) -> CGRect? {
        var minimumX = bitmap.pixelsWide, minimumY = bitmap.pixelsHigh
        var maximumX = -1, maximumY = -1
        for y in (yRange ?? (0..<bitmap.pixelsHigh)) {
            for x in (xRange ?? (0..<bitmap.pixelsWide)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.8,
                      max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.68 else { continue }
                minimumX = min(minimumX, x); minimumY = min(minimumY, y)
                maximumX = max(maximumX, x); maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(x: CGFloat(minimumX), y: CGFloat(minimumY),
                      width: CGFloat(maximumX - minimumX + 1), height: CGFloat(maximumY - minimumY + 1))
    }

    @MainActor
    private func makeContext(
        for scenario: ScreenSnapshotScenario,
        environment: ScreenEnvironment,
        usesWideContent: Bool = false
    ) async throws -> ScreenSnapshotContext {
        let musicInfo = scenario.usesPlayingTrack ? Self.sampleNowPlaying : .empty
        let viewModel = IslandViewModel(
            volumeService: ScreenMatrixVolumeService(),
            fileTrayService: ScreenMatrixFileTrayService(),
            sharingService: ScreenMatrixSharingService(),
            musicService: ScreenMatrixMusicService(nowPlayingInfo: musicInfo),
            hapticFeedbackService: ScreenMatrixHapticFeedbackService()
        )
        viewModel.setScreenEnvironment(environment)

        if scenario.usesPlayingTrack {
            await viewModel.refreshNowPlaying(reportError: false)
        }
        if scenario.usesTrayItems {
            viewModel.importFiles(from: Self.sampleFileURLs)
        }

        switch scenario {
        case .compact, .compactPlaying, .compactVolume, .compactBatteryCharging:
            break
        case .expandedVolume, .expandedBatteryLow, .expandedBatteryCritical:
            viewModel.setHovering(true)
        case .expandedMusic:
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.music)
        case .expandedFileTray:
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.fileTray)
        case .draggingFile:
            viewModel.setDragging(true)
        case .expandedToolsStopwatch:
            viewModel.timerTools.selectedMode = .stopwatch
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.tools)
        case .expandedToolsCountdown:
            viewModel.timerTools.selectedMode = .countdown
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.tools)
        }

        let activityRuntime = IslandActivityRuntime(viewModel: viewModel)
        if scenario.usesVolumeActivity {
            try activityRuntime.manager.publish(VolumeActivityProvider.makeActivity(
                for: VolumeActivityEvent(volume: 1, isMuted: false),
                createdAt: Date()
            ))
            try activityRuntime.manager.end(
                id: MusicActivityProvider.activityID,
                source: MusicActivityProvider.source
            )
        }
        if let batteryScenario = scenario.batteryScenario {
            try activityRuntime.manager.publish(BatteryActivityProvider.makeActivity(
                for: usesWideContent && scenario == .compactBatteryCharging
                    ? BatteryState(level: 1, powerSource: .ac, isCharging: true, isCharged: false)
                    : batteryScenario.state,
                classification: batteryScenario.classification,
                createdAt: Date()
            ))
            try activityRuntime.manager.end(
                id: MusicActivityProvider.activityID,
                source: MusicActivityProvider.source
            )
        }

        return ScreenSnapshotContext(
            viewModel: viewModel,
            activityRuntime: activityRuntime
        )
    }

    private func writeManifest(records: [ScreenSnapshotRecord], to outputDirectory: URL) throws {
        let manifest = ScreenSnapshotManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            profileCount: SimulatedScreenProfile.allCases.count,
            resolutionFixtureCount: ResolutionSnapshotFixture.allCases.count,
            scenarioCount: ScreenSnapshotScenario.allCases.count,
            snapshotCount: records.count,
            snapshots: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: outputDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func writeIndex(records: [ScreenSnapshotRecord], to outputDirectory: URL) throws {
        let identifiers = records.reduce(into: [String]()) { result, record in
            if !result.contains(record.profile) { result.append(record.profile) }
        }
        let sections = identifiers.map { identifier in
            let group = records.filter { $0.profile == identifier }
            guard let first = group.first else { return "" }
            let figures = group.map { record in
                let offset = max(0, (record.canvasWidth - 800) / 2)
                return """
                <figure>
                  <div class="crop"><img style="width:\(record.canvasWidth)px;margin-left:-\(offset)px" src="\(record.file)" alt="\(record.profileName) - \(record.scenarioName)"></div>
                  <figcaption>\(record.scenarioName) · \(record.panelWidth)×\(record.panelHeight) pt panel</figcaption>
                  <details><summary>完整逻辑宽度 / 原始 PNG</summary><div class="full"><img style="width:\(record.canvasWidth)px" src="\(record.file)" alt="Full logical-width view"></div></details>
                </figure>
                """
            }.joined(separator: "\n")
            return """
            <section><h2>\(first.profileName)</h2>
              <p>\(first.logicalScreenWidth)×\(first.logicalScreenHeight) pt · backing \(first.scaleFactor)x · layout \(first.layoutScale)x<br>\(first.source)</p>
              <div class="grid">\(figures)</div>
            </section>
            """
        }.joined(separator: "\n")
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Dynamic Island Screen Matrix</title>
        <style>
        :root { color-scheme:dark; font-family:-apple-system,BlinkMacSystemFont,sans-serif; }
        body { margin:0; padding:28px; background:#1c1c1e; color:#f5f5f7; }
        h2 { margin:32px 0 4px; } p { color:#a1a1a6; } .grid { display:grid; gap:12px; }
        figure { width:800px; margin:0; border:1px solid #3a3a3c; background:#2c2c2e; }
        .crop { width:800px; overflow:hidden; } img { display:block; max-width:none; height:auto; }
        .full { overflow:auto; } figcaption,summary { padding:8px 10px; }
        </style></head><body><h1>Dynamic Island Screen Matrix</h1>
        <p>\(records.count) PNGs: 8 synthetic device profiles + 4 resolution fixtures, 12 states each.
        Every preview uses the same 800-point crop at 1 CSS px per logical point; browser zoom must be 100%.
        Full-width images preserve screen-relative proportions. Synthetic 1710 and 2560 geometries are not measured device results.</p>
        \(sections)</body></html>
        """
        try Data(html.utf8).write(to: outputDirectory.appendingPathComponent("index.html"), options: .atomic)
    }

    private static let sampleNowPlaying = NowPlayingInfo(
        isPlaying: true,
        title: "Midnight Geometry",
        artist: "Dynamic Island",
        album: "Screen Matrix",
        duration: 245,
        position: 92,
        trackIdentifier: "screen-matrix-track"
    )

    private static let sampleFileURLs = [
        URL(fileURLWithPath: "/tmp/Dynamic Island Design.pdf"),
        URL(fileURLWithPath: "/tmp/Screen Matrix.zip"),
        URL(fileURLWithPath: "/tmp/Island Notes.txt")
    ]
}

private enum ScreenSnapshotScenario: String, CaseIterable {
    case compact
    case compactPlaying = "compact-playing"
    case compactVolume = "compact-volume"
    case expandedVolume = "expanded-volume"
    case compactBatteryCharging = "compact-battery-charging"
    case expandedBatteryLow = "expanded-battery-low"
    case expandedBatteryCritical = "expanded-battery-critical"
    case expandedMusic = "expanded-music"
    case expandedFileTray = "expanded-file-tray"
    case draggingFile = "dragging-file"
    case expandedToolsStopwatch = "expanded-tools-stopwatch"
    case expandedToolsCountdown = "expanded-tools-countdown"

    var displayName: String {
        switch self {
        case .compact:
            return "收起"
        case .compactPlaying:
            return "收起 · 音乐播放"
        case .compactVolume:
            return "收起 · 系统音量"
        case .expandedVolume:
            return "展开 · 系统音量"
        case .compactBatteryCharging:
            return "收起 · 电池充电"
        case .expandedBatteryLow:
            return "展开 · 低电量"
        case .expandedBatteryCritical:
            return "展开 · 严重低电量"
        case .expandedMusic:
            return "展开 · 音乐"
        case .expandedFileTray:
            return "展开 · 文件拖盘"
        case .draggingFile:
            return "展开 · 文件拖入"
        case .expandedToolsStopwatch:
            return "展开 · 秒表"
        case .expandedToolsCountdown:
            return "展开 · 倒计时"
        }
    }

    var usesPlayingTrack: Bool {
        self == .compactPlaying || self == .expandedMusic
    }

    var usesTrayItems: Bool {
        self == .expandedFileTray || self == .draggingFile
    }

    var usesVolumeActivity: Bool {
        self == .compactVolume || self == .expandedVolume
    }

    var batteryScenario: ScreenMatrixBatteryScenario? {
        switch self {
        case .compactBatteryCharging:
            return ScreenMatrixBatteryScenario(
                state: BatteryState(
                    level: 0.72,
                    powerSource: .ac,
                    isCharging: true,
                    isCharged: false
                ),
                classification: .charging
            )
        case .expandedBatteryLow:
            return ScreenMatrixBatteryScenario(
                state: BatteryState(
                    level: 0.18,
                    powerSource: .battery,
                    isCharging: false,
                    isCharged: false
                ),
                classification: .low
            )
        case .expandedBatteryCritical:
            return ScreenMatrixBatteryScenario(
                state: BatteryState(
                    level: 0.08,
                    powerSource: .battery,
                    isCharging: false,
                    isCharged: false
                ),
                classification: .critical
            )
        default:
            return nil
        }
    }
}

private struct ScreenMatrixBatteryScenario {
    let state: BatteryState
    let classification: BatteryActivityProvider.Classification
}

private struct ScreenSnapshotCase {
    let id: String
    let name: String
    let source: String
    let environment: ScreenEnvironment
    let isResolutionComparison: Bool
}

/// Only the first two geometries were observed on the same physical Mac.
/// The larger two are explicit synthetic extrapolations for scale regression.
private struct ResolutionSnapshotFixture {
    let id: String
    let name: String
    let source: String
    let size: CGSize
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let backingScaleFactor: CGFloat

    init(id: String, name: String, source: String, size: CGSize,
         notchWidth: CGFloat, notchHeight: CGFloat, backingScaleFactor: CGFloat = 2) {
        self.id = id
        self.name = name
        self.source = source
        self.size = size
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.backingScaleFactor = backingScaleFactor
    }

    static let allCases: [Self] = [
        .init(id: "resolution-1470-measured", name: "同机 1470 · 已知几何",
              source: "Measured geometry: 1470×956, auxiliary gap 179×32 pt; simulated rendering",
              size: CGSize(width: 1470, height: 956), notchWidth: 179, notchHeight: 32),
        .init(id: "resolution-1280-measured", name: "同机 1280 · 已知几何",
              source: "Measured geometry: 1280×832, auxiliary gap 156×28 pt; simulated rendering",
              size: CGSize(width: 1280, height: 832), notchWidth: 156, notchHeight: 28),
        .init(id: "resolution-1710-synthetic", name: "1710 · 合成几何（非实测）",
              source: "SYNTHETIC: 1710×1112, auxiliary gap 207×37 pt; not physical-device evidence",
              size: CGSize(width: 1710, height: 1112), notchWidth: 207, notchHeight: 37),
        .init(id: "resolution-2560-backing1-synthetic", name: "2560 · backing 1 · 合成几何（非实测）",
              source: "SYNTHETIC: 2560×1664, auxiliary gap 312×56 pt, backing 1; not physical-device evidence",
              size: CGSize(width: 2560, height: 1664), notchWidth: 312, notchHeight: 56,
              backingScaleFactor: 1)
    ]

    var environment: ScreenEnvironment { makeEnvironment(backingScale: backingScaleFactor) }

    func makeEnvironment(backingScale: CGFloat) -> ScreenEnvironment {
        let frame = CGRect(origin: .zero, size: size)
        let sideWidth = (size.width - notchWidth) / 2
        let auxiliaryY = size.height - notchHeight
        return ScreenEnvironment(
            displayID: 0xFFFF_1001, name: name, frame: frame,
            visibleFrame: CGRect(x: 0, y: 0, width: size.width, height: auxiliaryY),
            safeAreaInsets: ScreenEdgeInsets(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: auxiliaryY, width: sideWidth, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: sideWidth + notchWidth, y: auxiliaryY,
                                          width: sideWidth, height: notchHeight),
            backingScaleFactor: backingScale, isBuiltIn: true
        )
    }
}

@MainActor
private struct ScreenSnapshotContext {
    let viewModel: IslandViewModel
    let activityRuntime: IslandActivityRuntime
}

private struct ScreenSnapshotCanvas: View {
    static let size = CGSize(width: 800, height: 320)

    let environment: ScreenEnvironment
    @ObservedObject var viewModel: IslandViewModel
    let activityRuntime: IslandActivityRuntime
    var overlaysNotch = true
    var canvasSize = ScreenSnapshotCanvas.size

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.29, green: 0.29, blue: 0.31)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: min(topReservedHeight, 60))

            IslandView(viewModel: viewModel, activityRuntime: activityRuntime)
                .frame(
                    width: viewModel.displayLayout.panelSize.width,
                    height: viewModel.displayLayout.panelSize.height,
                    alignment: .top
                )

            if overlaysNotch && environment.hasNotch {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: notchWidth, height: environment.safeAreaInsets.top)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
        .clipped()
    }

    private var topReservedHeight: CGFloat {
        environment.frame.maxY - environment.visibleFrame.maxY
    }

    private var notchWidth: CGFloat {
        environment.auxiliaryTopRightArea.minX - environment.auxiliaryTopLeftArea.maxX
    }
}

@MainActor
private final class ScreenSnapshotRenderer {
    struct RenderedImage {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private let size: CGSize
    private let window: NSWindow

    init(size: CGSize) {
        self.size = size
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
    }

    func render<Content: View>(
        _ content: Content,
        scale: CGFloat
    ) throws -> RenderedImage {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ScreenSnapshotRenderingError.renderFailed
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)

        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenSnapshotRenderingError.pngEncodingFailed
        }

        return RenderedImage(
            data: data,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

private struct ScreenSnapshotManifest: Encodable {
    let generatedAt: String
    let profileCount: Int
    let resolutionFixtureCount: Int
    let scenarioCount: Int
    let snapshotCount: Int
    let snapshots: [ScreenSnapshotRecord]
}

private struct ScreenSnapshotRecord: Encodable {
    let profile: String
    let profileName: String
    let source: String
    let isResolutionComparison: Bool
    let scenario: String
    let scenarioName: String
    let file: String
    let logicalScreenWidth: Int
    let logicalScreenHeight: Int
    let scaleFactor: CGFloat
    let layoutScale: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let imageWidth: Int
    let imageHeight: Int
}

private enum ScreenSnapshotRenderingError: LocalizedError {
    case renderFailed
    case pngEncodingFailed
    case invalidOutputDirectory
    case outputDirectoryNotEmpty

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "无法渲染屏幕矩阵图像"
        case .pngEncodingFailed:
            return "无法编码屏幕矩阵 PNG"
        case .invalidOutputDirectory:
            return "SCREEN_MATRIX_OUTPUT_DIR 必须是绝对路径"
        case .outputDirectoryNotEmpty:
            return "截图输出目录已有内容；请选择新目录以保留旧基线"
        }
    }
}

private struct ScreenMatrixVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.62 }
    func setVolume(_ volume: Float) throws {}
}

private struct ScreenMatrixFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] {
        urls.enumerated().map { index, url in
            TrayFileItem(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)") ?? UUID(),
                url: url,
                originalURL: url,
                byteCount: Int64((index + 1) * 1_048_576)
            )
        }
    }

    func clear() throws {}
    func remove(_ item: TrayFileItem) throws {}
}

private struct ScreenMatrixSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct ScreenMatrixMusicService: MusicControlService {
    let nowPlayingInfo: NowPlayingInfo

    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool { true }
    func nowPlaying() async throws -> NowPlayingInfo { nowPlayingInfo }
}

private final class ScreenMatrixHapticFeedbackService: HapticFeedbackService {
    func performExpansionFeedback() {}
}
