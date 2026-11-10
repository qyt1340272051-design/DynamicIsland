import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class MusicActivityProviderTests: XCTestCase {
    func testMusicPublishesOnePersistentActivityAndResumesAfterPreemption() async throws {
        let service = MusicActivityTestService(info: .empty)
        let model = makeModel(music: service)
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)

        let empty = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(empty.activity.id, MusicActivityProvider.activityID)
        XCTAssertEqual(empty.activity.priority, .background)
        XCTAssertEqual(empty.activity.lifecycle.policy, .persistent)
        XCTAssertFalse(provider.isPlaying)
        XCTAssertFalse(empty.activity.actions.contains(where: { $0.id == MusicActivityProvider.seekActionID }))

        await service.setInfo(track(title: "第一首", playing: true))
        await model.refreshNowPlaying()
        try provider.synchronize()
        let first = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(first.instanceToken, empty.instanceToken)
        XCTAssertEqual(first.activity.presentation.title, "第一首")
        XCTAssertTrue(provider.isPlaying)
        guard case .hStack(let compact) = try XCTUnwrap(first.activity.presentation.compact) else {
            return XCTFail("Compact music should be one row")
        }
        XCTAssertEqual(compact.children.count, 3)
        guard case .image(let compactArtwork) = compact.children[0],
              case .spacer = compact.children[1],
              case .icon(let indicator) = compact.children[2] else {
            return XCTFail("Compact music should show artwork and waveform without controls")
        }
        XCTAssertEqual(compactArtwork.size, .thumbnail)
        XCTAssertEqual(indicator.symbolName, "waveform")

        await service.setInfo(track(title: "第二首", playing: false))
        await model.refreshNowPlaying()
        try provider.synchronize()
        let second = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(second.instanceToken, first.instanceToken)
        XCTAssertEqual(second.activity.presentation.title, "第二首")
        XCTAssertFalse(provider.isPlaying)

        let interrupt = IslandActivity(
            id: "test.volume", source: ActivitySource(kind: .builtIn, identifier: "test-volume"),
            priority: .normal, lifecycle: .init(policy: .transient),
            presentation: .init(title: "音量"), createdAt: Date()
        )
        try manager.publish(interrupt)
        XCTAssertEqual(manager.current?.id, interrupt.id)
        XCTAssertEqual(manager.activity(id: MusicActivityProvider.activityID)?.lifecycle.state, .background)
        try manager.end(id: interrupt.id, source: interrupt.source)
        XCTAssertEqual(manager.current?.id, MusicActivityProvider.activityID)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, first.instanceToken)
        withExtendedLifetime(provider) {}
    }

    func testRouterUsesExistingPlaybackSeekAndVolumeControls() async throws {
        let service = MusicActivityTestService(info: track(title: "可控制曲目", playing: false))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let router = ActionRouter(manager: manager)
        let registration = provider.registerActions(with: router)
        defer { router.unregister(source: MusicActivityProvider.source, registration: registration) }

        let snapshot = try XCTUnwrap(manager.currentSnapshot)
        let declared = Set(snapshot.activity.actions.map(\.id))
        XCTAssertEqual(declared, Set([
            MusicActivityProvider.playPauseActionID, MusicActivityProvider.previousActionID,
            MusicActivityProvider.nextActionID, MusicActivityProvider.seekActionID,
            MusicActivityProvider.volumeActionID, MusicActivityProvider.muteActionID,
            MusicActivityProvider.volumeDownActionID, MusicActivityProvider.volumeUpActionID
        ]))
        let initialTexts = textContents(try XCTUnwrap(snapshot.activity.presentation.expanded))
        XCTAssertTrue(initialTexts.contains("0:10"))
        XCTAssertTrue(initialTexts.contains("2:00"))
        XCTAssertTrue(initialTexts.contains("50%"))

        func dispatch(_ id: String, _ value: IslandRenderActionValue = .none) -> ActionDispatchResult {
            router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
                            instanceToken: snapshot.instanceToken, action: .init(actionID: id, value: value))
        }

        XCTAssertEqual(dispatch(MusicActivityProvider.playPauseActionID), .handled)
        try await waitFor { await service.toggleCount == 1 }
        XCTAssertEqual(dispatch(MusicActivityProvider.previousActionID), .handled)
        XCTAssertEqual(dispatch(MusicActivityProvider.nextActionID), .handled)
        try await waitFor {
            let previous = await service.previousCount
            let next = await service.nextCount
            return previous == 1 && next == 1
        }

        XCTAssertEqual(dispatch(MusicActivityProvider.seekActionID, .slider(0.5)), .handled)
        XCTAssertEqual(model.nowPlaying.position, 60, accuracy: 0.001)
        try await waitFor { await service.lastSeek == 60 }
        XCTAssertEqual(dispatch(MusicActivityProvider.seekActionID, .sliderCommit(0.6)), .handled)
        XCTAssertEqual(model.nowPlaying.position, 72, accuracy: 0.001)
        try await waitFor { await service.lastSeek == 72 }
        XCTAssertEqual(dispatch(MusicActivityProvider.volumeActionID, .slider(0.75)), .handled)
        XCTAssertEqual(model.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(dispatch(MusicActivityProvider.volumeActionID, .sliderCommit(0.75)), .handled)
        try provider.synchronize()
        XCTAssertTrue(textContents(try XCTUnwrap(manager.current?.presentation.expanded)).contains("75%"))
        XCTAssertEqual(dispatch(MusicActivityProvider.volumeDownActionID), .handled)
        XCTAssertEqual(model.volume, 0.6875, accuracy: 0.001)
        XCTAssertEqual(dispatch(MusicActivityProvider.volumeUpActionID), .handled)
        XCTAssertEqual(model.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(dispatch(MusicActivityProvider.muteActionID), .handled)
        XCTAssertTrue(model.isMuted)
        try provider.synchronize()
        XCTAssertTrue(textContents(try XCTUnwrap(manager.current?.presentation.expanded)).contains("静音"))
        XCTAssertEqual(dispatch(MusicActivityProvider.muteActionID), .handled)
        XCTAssertFalse(model.isMuted)

        XCTAssertEqual(dispatch(MusicActivityProvider.seekActionID, .slider(.nan)), .invalidPayload)
        XCTAssertEqual(dispatch(MusicActivityProvider.seekActionID, .sliderCommit(.infinity)), .invalidPayload)
        XCTAssertFalse(provider.handle(actionID: MusicActivityProvider.volumeActionID, value: .none))
        XCTAssertFalse(provider.handle(actionID: MusicActivityProvider.seekActionID, value: .slider(-1)))
    }

    func testMusicTimelineSharesOneRowAndRetainsReadOnlyAndUnknownDurationStates() async throws {
        let service = MusicActivityTestService(info: track(title: "时间轴"))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)

        func timeline() throws -> [IslandNode] {
            guard case .hStack(let expanded) = try XCTUnwrap(manager.current?.presentation.expanded),
                  case .vStack(let details) = try XCTUnwrap(expanded.children.last),
                  details.children.count == 5,
                  case .hStack(let timeline) = details.children[2] else {
                XCTFail("Music must keep metadata, timeline, playback, and volume in five rows.")
                return []
            }
            return timeline.children
        }

        let seekTimeline = try timeline()
        XCTAssertEqual(seekTimeline, [
            .text(.init("0:10")),
            .slider(.init(title: "播放进度", value: 10.0 / 120,
                          actionID: MusicActivityProvider.seekActionID, showsTitle: false)),
            .text(.init("2:00"))
        ])

        await service.setInfo(NowPlayingInfo(isPlaying: false, title: "只读时间轴", artist: "艺人", album: "",
                                           duration: 120, position: 10))
        await model.refreshNowPlaying()
        try provider.synchronize()
        XCTAssertEqual(try timeline(), [
            .text(.init("0:10")), .progress(.init(10.0 / 120)), .text(.init("2:00"))
        ])
        XCTAssertFalse(try XCTUnwrap(manager.current).actions.contains { $0.id == MusicActivityProvider.seekActionID })

        await service.setInfo(.empty)
        await model.refreshNowPlaying()
        try provider.synchronize()
        XCTAssertEqual(try timeline(), [.text(.init("0:00")), .spacer(.init()), .text(.init("--:--"))])
    }

    func testArtworkUsesOnlyBoundedHostResourceAndLayoutsPassPolicy() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let artwork = try XCTUnwrap(image.tiffRepresentation)

        let service = MusicActivityTestService(info: track(title: "封面", artwork: artwork))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let resource = IslandNode.ImageSource.brokerResource(id: MusicActivityProvider.artworkResourceID)
        let firstImage = try XCTUnwrap(provider.resolveImage(resource))
        XCTAssertTrue(firstImage === provider.resolveImage(resource))
        XCTAssertNil(provider.resolveImage(.brokerResource(id: "other.resource")))

        let presentation = try XCTUnwrap(manager.current?.presentation)
        for mode in ActivityPresentation.Mode.allCases {
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(presentation.resolvedNode(for: mode), for: mode), "\(mode)")
        }
        guard case .hStack(let root) = try XCTUnwrap(presentation.expanded),
              case .image(let expandedArtwork) = root.children[0] else {
            return XCTFail("Expanded artwork should use the Host image token")
        }
        XCTAssertNotEqual(expandedArtwork.source, resource)
        XCTAssertTrue(firstImage === provider.resolveImage(expandedArtwork.source))
        XCTAssertEqual(expandedArtwork.size, .artwork)
        guard case .hStack(let compact) = try XCTUnwrap(presentation.compact),
              case .image(let compactArtwork) = compact.children[0] else {
            return XCTFail("Compact artwork should use the Host thumbnail token")
        }
        XCTAssertEqual(compactArtwork.size, .thumbnail)
        XCTAssertEqual(compactArtwork.source, expandedArtwork.source)
        guard let minimal = presentation.minimal, case .image(let minimalArtwork) = minimal else {
            return XCTFail("Minimal music artwork should share the current Host resource revision")
        }
        XCTAssertEqual(minimalArtwork.source, expandedArtwork.source)

        await service.setInfo(track(title: "封面过大", artwork: Data(repeating: 1, count: 4 * 1024 * 1024 + 1)))
        await model.refreshNowPlaying()
        try provider.synchronize()
        XCTAssertNil(provider.resolveImage(resource))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(
            try XCTUnwrap(manager.current?.presentation.expanded), for: .expanded
        ))
    }

    func testArtOnlyReplacementPublishesToManagerOnlyRendererWithoutModelObservation() async throws {
        func artwork(_ color: NSColor) throws -> Data {
            let image = NSImage(size: CGSize(width: 48, height: 48), flipped: false) { rectangle in
                color.setFill()
                NSBezierPath(rect: rectangle).fill()
                return true
            }
            return try XCTUnwrap(image.tiffRepresentation)
        }
        let red = try artwork(.red)
        let blue = try artwork(.blue)
        let service = MusicActivityTestService(info: track(title: "Unchanged metadata", artwork: red))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        try await waitFor { model.nowPlaying.title == "Unchanged metadata" && model.nowPlaying.artworkData == red }
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let first = try XCTUnwrap(manager.currentSnapshot)
        let firstSource = try artworkSource(first.activity.presentation)
        var publications = 0
        let observation = manager.$currentSnapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        // The renderer consumes the pure-data Manager API only. It deliberately
        // does not observe the legacy ViewModel to conceal resource-only gaps.
        let hosting = NSHostingView(rootView: ManagerOnlyMusicRenderer(manager: manager, provider: provider))
        hosting.frame = CGRect(x: 0, y: 0, width: 412, height: 134)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let initial = try resourceBitmap(hosting)
        XCTAssertGreaterThan(resourcePixels(initial, blue: false), 10_000)

        await service.setInfo(track(title: "Unchanged metadata", artwork: blue))
        await model.refreshNowPlaying()
        try await Task.sleep(nanoseconds: 250_000_000)
        let second = try XCTUnwrap(manager.currentSnapshot)
        let secondSource = try artworkSource(second.activity.presentation)
        XCTAssertGreaterThan(publications, 0, "New artwork must invalidate pure-data Manager subscribers.")
        XCTAssertNotEqual(secondSource, firstSource, "Stable broker IDs hide artwork-only resource replacement.")
        XCTAssertEqual(second.instanceToken, first.instanceToken)
        XCTAssertEqual(second.activity.actions, first.activity.actions)
        XCTAssertNil(provider.resolveImage(firstSource), "Stale versioned references must not resolve replacement bytes.")
        let currentImage = try XCTUnwrap(provider.resolveImage(secondSource))
        XCTAssertTrue(currentImage === provider.resolveImage(.brokerResource(id: MusicActivityProvider.artworkResourceID)),
                      "The legacy Host alias should still resolve the current image.")
        let replacement = try resourceBitmap(hosting)
        XCTAssertGreaterThan(resourcePixels(replacement, blue: true), 10_000)
        XCTAssertLessThan(resourcePixels(replacement, blue: false), 30)

        let stablePublications = publications
        await service.setInfo(track(title: "Unchanged metadata", artwork: blue))
        await model.refreshNowPlaying()
        XCTAssertEqual(publications, stablePublications, "Identical cached bytes must not publish another revision.")
        XCTAssertEqual(try artworkSource(try XCTUnwrap(manager.current?.presentation)), secondSource)

        await service.setInfo(track(title: "Unchanged metadata", artwork: nil))
        await model.refreshNowPlaying()
        let missingSource = try artworkSource(try XCTUnwrap(manager.current?.presentation))
        XCTAssertNotEqual(missingSource, secondSource)
        XCTAssertNil(provider.resolveImage(secondSource))
        XCTAssertNil(provider.resolveImage(missingSource))
    }

    func testRepeatedRejectedArtworkDoesNotCreateResourceRevisions() async throws {
        let image = NSImage(size: CGSize(width: 2, height: 2), flipped: false) { rectangle in
            NSColor.red.setFill()
            NSBezierPath(rect: rectangle).fill()
            return true
        }
        let service = MusicActivityTestService(info: track(title: "Rejected art", artwork: try XCTUnwrap(image.tiffRepresentation)))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        try await waitFor { model.nowPlaying.title == "Rejected art" }
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let valid = try artworkSource(try XCTUnwrap(manager.current?.presentation))
        var publications = 0
        let observation = manager.$currentSnapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let oversized = Data(repeating: 1, count: 4 * 1_024 * 1_024 + 1)
        await service.setInfo(track(title: "Rejected art", artwork: oversized))
        await model.refreshNowPlaying()
        let cleared = try artworkSource(try XCTUnwrap(manager.current?.presentation))
        XCTAssertNotEqual(cleared, valid)
        XCTAssertNil(provider.resolveImage(valid))
        XCTAssertNil(provider.resolveImage(cleared))
        let firstClearPublications = publications

        await service.setInfo(track(title: "Rejected art", artwork: oversized))
        await model.refreshNowPlaying()
        try provider.synchronize()
        XCTAssertEqual(try artworkSource(try XCTUnwrap(manager.current?.presentation)), cleared)
        XCTAssertEqual(publications, firstClearPublications)
        await service.setInfo(track(title: "Rejected art", artwork: nil))
        await model.refreshNowPlaying()
        XCTAssertEqual(try artworkSource(try XCTUnwrap(manager.current?.presentation)), cleared)
        XCTAssertEqual(publications, firstClearPublications)
    }

    func testMusicErrorAppearsInSubtitleAndRecoveryClearsIt() async throws {
        let service = MusicActivityTestService(info: track(title: "可恢复曲目"))
        let model = makeModel(music: service)
        await model.refreshNowPlaying()
        let manager = ActivityManager(configuration: .immediate)
        let provider = MusicActivityProvider(viewModel: model, manager: manager)

        await service.setError(.temporarilyUnavailable)
        await model.refreshNowPlaying()
        try provider.synchronize()

        XCTAssertEqual(model.musicErrorMessage, MusicActivityTestError.temporarilyUnavailable.localizedDescription)
        XCTAssertEqual(
            manager.currentSnapshot?.activity.presentation.subtitle,
            MusicActivityTestError.temporarilyUnavailable.localizedDescription
        )

        await service.setError(nil)
        await model.refreshNowPlaying()
        try provider.synchronize()

        XCTAssertNil(model.musicErrorMessage)
        XCTAssertEqual(manager.currentSnapshot?.activity.presentation.subtitle, "艺人 — 专辑")
    }

    private func makeModel(music: MusicActivityTestService) -> IslandViewModel {
        makeMusicActivityTestModel(music: music)
    }

    private func track(title: String, playing: Bool = false, artwork: Data? = nil) -> NowPlayingInfo {
        NowPlayingInfo(isPlaying: playing, title: title, artist: "艺人", album: "专辑",
                       duration: 120, position: 10, trackIdentifier: title, artworkData: artwork)
    }

    private func artworkSource(_ presentation: ActivityPresentation) throws -> IslandNode.ImageSource {
        guard case .hStack(let root) = try XCTUnwrap(presentation.expanded),
              let first = root.children.first, case .image(let image) = first else {
            throw MusicResourceTestError.missingImage
        }
        return image.source
    }

    private func resourceBitmap<Content: View>(_ hosting: NSHostingView<Content>) throws -> NSBitmapImageRep {
        let size = hosting.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func resourcePixels(_ bitmap: NSBitmapImageRep, blue: Bool) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      pixel.alphaComponent > 0.5, pixel.greenComponent < 0.3 else { continue }
                if blue && pixel.blueComponent > 0.7 && pixel.redComponent < 0.3 { count += 1 }
                if !blue && pixel.redComponent > 0.7 && pixel.blueComponent < 0.3 { count += 1 }
            }
        }
        return count
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Music command did not arrive")
    }

    private func textContents(_ node: IslandNode) -> [String] {
        switch node {
        case .text(let value): [value.content]
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            stack.children.flatMap(textContents)
        case .button(let value): textContents(value.label)
        default: []
        }
    }
}

@MainActor
private struct ManagerOnlyMusicRenderer: View {
    @ObservedObject var manager: ActivityManager
    let provider: MusicActivityProvider

    var body: some View {
        if let presentation = manager.currentSnapshot?.activity.presentation {
            IslandRenderer(presentation: presentation, mode: .expanded,
                shellSize: CGSize(width: 428, height: 184), imageResolver: provider.resolveImage)
                .environment(\.colorScheme, .dark)
        }
    }
}

private enum MusicResourceTestError: Error { case missingImage }

enum MusicActivityTestError: LocalizedError {
    case temporarilyUnavailable

    var errorDescription: String? { "音乐服务暂不可用" }
}

actor MusicActivityTestService: MusicControlService {
    var info: NowPlayingInfo
    private var error: MusicActivityTestError?
    private(set) var toggleCount = 0
    private(set) var previousCount = 0
    private(set) var nextCount = 0
    private(set) var lastSeek: TimeInterval?

    init(info: NowPlayingInfo) { self.info = info }

    func setInfo(_ info: NowPlayingInfo) { self.info = info }
    func setError(_ error: MusicActivityTestError?) { self.error = error }
    func togglePlayPause() async throws { toggleCount += 1 }
    func skipBackward() async throws { previousCount += 1 }
    func skipForward() async throws { nextCount += 1 }
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool {
        lastSeek = position
        return true
    }
    func nowPlaying() async throws -> NowPlayingInfo {
        if let error { throw error }
        return info
    }
}

struct MusicActivityTestVolume: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

struct MusicActivityTestTray: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

struct MusicActivityTestSharing: SharingService {
    func share(urls: [URL]) throws {}
}

struct MusicActivityTestHaptic: HapticFeedbackService {
    func performExpansionFeedback() {}
}

@MainActor
func makeMusicActivityTestModel(music: MusicActivityTestService) -> IslandViewModel {
    IslandViewModel(
        volumeService: MusicActivityTestVolume(),
        fileTrayService: MusicActivityTestTray(),
        sharingService: MusicActivityTestSharing(),
        musicService: music,
        hapticFeedbackService: MusicActivityTestHaptic(),
        nowPlayingPollIntervalNanoseconds: 3_600_000_000_000
    )
}
