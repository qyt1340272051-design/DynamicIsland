import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

final class ScreenSnapshotMatrixTests: XCTestCase {
    func testMatrixCoversEveryProfileAndRequiredIslandState() {
        XCTAssertEqual(SimulatedScreenProfile.allCases.count, 8)
        XCTAssertEqual(ScreenSnapshotScenario.allCases.count, 8)
        XCTAssertEqual(
            SimulatedScreenProfile.allCases.count * ScreenSnapshotScenario.allCases.count,
            64
        )
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedMusic))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedFileTray))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedToolsStopwatch))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedToolsPomodoro))
        XCTAssertTrue(ScreenSnapshotScenario.allCases.contains(.expandedToolsCountdown))
    }

    func testGenerateSnapshotMatrix() async throws {
        guard ProcessInfo.processInfo.environment["SCREEN_MATRIX_GENERATE"] == "1" else {
            throw XCTSkip("Run Scripts/generate-screen-matrix.sh to generate the screenshot matrix.")
        }

        let outputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("artifacts/screen-matrix", isDirectory: true)
        print("Generating screen matrix at \(outputURL.path)")
        try await generateSnapshotMatrix(at: outputURL)
    }

    @MainActor
    private func generateSnapshotMatrix(at outputDirectory: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.removeItem(at: outputDirectory)
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var records: [ScreenSnapshotRecord] = []
        for profile in SimulatedScreenProfile.allCases {
            let configuration = profile.defaultConfiguration
            let environment = configuration.makeEnvironment()
            let profileDirectory = outputDirectory.appendingPathComponent(profile.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

            for scenario in ScreenSnapshotScenario.allCases {
                let viewModel = await makeViewModel(for: scenario, environment: environment)
                let canvas = ScreenSnapshotCanvas(environment: environment, viewModel: viewModel)
                    .environment(\.colorScheme, .dark)
                let rendered = try ScreenSnapshotRenderer.render(
                    canvas,
                    size: ScreenSnapshotCanvas.size,
                    scale: environment.backingScaleFactor
                )
                let relativePath = "\(profile.rawValue)/\(scenario.rawValue).png"
                try rendered.data.write(
                    to: outputDirectory.appendingPathComponent(relativePath),
                    options: .atomic
                )
                records.append(
                    ScreenSnapshotRecord(
                        profile: profile.rawValue,
                        profileName: profile.displayName,
                        scenario: scenario.rawValue,
                        scenarioName: scenario.displayName,
                        file: relativePath,
                        logicalScreenWidth: Int(environment.frame.width.rounded()),
                        logicalScreenHeight: Int(environment.frame.height.rounded()),
                        scaleFactor: environment.backingScaleFactor,
                        notchWidth: Int(configuration.simulatesNotch ? configuration.notchWidth.rounded() : 0),
                        notchHeight: Int(configuration.simulatesNotch ? configuration.notchHeight.rounded() : 0),
                        imageWidth: rendered.pixelWidth,
                        imageHeight: rendered.pixelHeight
                    )
                )
            }
        }

        XCTAssertEqual(records.count, 64)
        try writeManifest(records: records, to: outputDirectory)
        try writeIndex(records: records, to: outputDirectory)
    }

    @MainActor
    private func makeViewModel(
        for scenario: ScreenSnapshotScenario,
        environment: ScreenEnvironment
    ) async -> IslandViewModel {
        let musicInfo = scenario.usesPlayingTrack ? Self.sampleNowPlaying : .empty
        let viewModel = IslandViewModel(
            volumeService: ScreenMatrixVolumeService(),
            fileTrayService: ScreenMatrixFileTrayService(),
            sharingService: ScreenMatrixSharingService(),
            musicService: ScreenMatrixMusicService(nowPlayingInfo: musicInfo),
            hapticFeedbackService: ScreenMatrixHapticFeedbackService()
        )
        viewModel.setCompactPanelSize(IslandPanelGeometry.compactFrame(in: environment).size)

        if scenario.usesPlayingTrack {
            await viewModel.refreshNowPlaying(reportError: false)
        }
        if scenario.usesTrayItems {
            viewModel.importFiles(from: Self.sampleFileURLs)
        }

        switch scenario {
        case .compact, .compactPlaying:
            break
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
        case .expandedToolsPomodoro:
            viewModel.timerTools.selectedMode = .pomodoro
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.tools)
        case .expandedToolsCountdown:
            viewModel.timerTools.selectedMode = .countdown
            viewModel.setHovering(true)
            viewModel.selectExpandedSurface(.tools)
        }

        return viewModel
    }

    private func writeManifest(records: [ScreenSnapshotRecord], to outputDirectory: URL) throws {
        let manifest = ScreenSnapshotManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            profileCount: SimulatedScreenProfile.allCases.count,
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
        let sections = SimulatedScreenProfile.allCases.map { profile in
            let profileRecords = records.filter { $0.profile == profile.rawValue }
            let figures = profileRecords.map { record in
                """
                <figure>
                  <img src="\(record.file)" alt="\(record.profileName) - \(record.scenarioName)">
                  <figcaption>\(record.scenarioName)</figcaption>
                </figure>
                """
            }.joined(separator: "\n")
            return """
            <section>
              <h2>\(profile.displayName)</h2>
              <p>\(Int(profile.logicalSize.width)) x \(Int(profile.logicalSize.height)) pt, \(profile.defaultScaleFactor)x</p>
              <div class="grid">\(figures)</div>
            </section>
            """
        }.joined(separator: "\n")

        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Dynamic Island Screen Matrix</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; padding: 28px; background: #1c1c1e; color: #f5f5f7; }
            h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
            h2 { margin: 32px 0 4px; font-size: 18px; letter-spacing: 0; }
            p { margin: 0 0 12px; color: #a1a1a6; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 12px; }
            figure { margin: 0; overflow: hidden; border: 1px solid #3a3a3c; border-radius: 8px; background: #2c2c2e; }
            img { display: block; width: 100%; height: auto; background: #4a4a4f; }
            figcaption { padding: 8px 10px; font-size: 12px; color: #d1d1d6; }
          </style>
        </head>
        <body>
          <h1>Dynamic Island Screen Matrix</h1>
          <p>\(records.count) snapshots across \(SimulatedScreenProfile.allCases.count) profiles and \(ScreenSnapshotScenario.allCases.count) states.</p>
          \(sections)
        </body>
        </html>
        """
        try Data(html.utf8).write(
            to: outputDirectory.appendingPathComponent("index.html"),
            options: .atomic
        )
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
    case expandedMusic = "expanded-music"
    case expandedFileTray = "expanded-file-tray"
    case draggingFile = "dragging-file"
    case expandedToolsStopwatch = "expanded-tools-stopwatch"
    case expandedToolsPomodoro = "expanded-tools-pomodoro"
    case expandedToolsCountdown = "expanded-tools-countdown"

    var displayName: String {
        switch self {
        case .compact:
            return "收起"
        case .compactPlaying:
            return "收起 · 音乐播放"
        case .expandedMusic:
            return "展开 · 音乐"
        case .expandedFileTray:
            return "展开 · 文件拖盘"
        case .draggingFile:
            return "展开 · 文件拖入"
        case .expandedToolsStopwatch:
            return "展开 · 秒表"
        case .expandedToolsPomodoro:
            return "展开 · 番茄钟"
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
}

private struct ScreenSnapshotCanvas: View {
    static let size = CGSize(width: 800, height: 260)

    let environment: ScreenEnvironment
    @ObservedObject var viewModel: IslandViewModel

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.29, green: 0.29, blue: 0.31)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: min(topReservedHeight, 60))

            if environment.hasNotch {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: notchWidth, height: environment.safeAreaInsets.top)
            }

            IslandView(viewModel: viewModel)
                .frame(
                    width: IslandPanelGeometry.expandedSize.width,
                    height: IslandPanelGeometry.expandedSize.height,
                    alignment: .top
                )
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .clipped()
    }

    private var topReservedHeight: CGFloat {
        environment.frame.maxY - environment.visibleFrame.maxY
    }

    private var notchWidth: CGFloat {
        environment.auxiliaryTopRightArea.minX - environment.auxiliaryTopLeftArea.maxX
    }
}

private enum ScreenSnapshotRenderer {
    struct RenderedImage {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    @MainActor
    static func render<Content: View>(
        _ content: Content,
        size: CGSize,
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

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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
}

private struct ScreenSnapshotManifest: Encodable {
    let generatedAt: String
    let profileCount: Int
    let scenarioCount: Int
    let snapshotCount: Int
    let snapshots: [ScreenSnapshotRecord]
}

private struct ScreenSnapshotRecord: Encodable {
    let profile: String
    let profileName: String
    let scenario: String
    let scenarioName: String
    let file: String
    let logicalScreenWidth: Int
    let logicalScreenHeight: Int
    let scaleFactor: CGFloat
    let notchWidth: Int
    let notchHeight: Int
    let imageWidth: Int
    let imageHeight: Int
}

private enum ScreenSnapshotRenderingError: LocalizedError {
    case renderFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "无法渲染屏幕矩阵图像"
        case .pngEncodingFailed:
            return "无法编码屏幕矩阵 PNG"
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
}

private struct ScreenMatrixSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct ScreenMatrixMusicService: MusicControlService {
    let nowPlayingInfo: NowPlayingInfo

    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func nowPlaying() async throws -> NowPlayingInfo { nowPlayingInfo }
}

private final class ScreenMatrixHapticFeedbackService: HapticFeedbackService {
    func performExpansionFeedback() {}
}
