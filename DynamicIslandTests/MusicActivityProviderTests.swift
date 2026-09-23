import AppKit
import Foundation
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
        XCTAssertEqual(expandedArtwork.source, resource)
        XCTAssertEqual(expandedArtwork.size, .artwork)
        guard case .hStack(let compact) = try XCTUnwrap(presentation.compact),
              case .image(let compactArtwork) = compact.children[0] else {
            return XCTFail("Compact artwork should use the Host thumbnail token")
        }
        XCTAssertEqual(compactArtwork.size, .thumbnail)

        await service.setInfo(track(title: "封面过大", artwork: Data(repeating: 1, count: 4 * 1024 * 1024 + 1)))
        await model.refreshNowPlaying()
        try provider.synchronize()
        XCTAssertNil(provider.resolveImage(resource))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(
            try XCTUnwrap(manager.current?.presentation.expanded), for: .expanded
        ))
    }

    private func makeModel(music: MusicActivityTestService) -> IslandViewModel {
        IslandViewModel(
            volumeService: MusicActivityTestVolume(),
            fileTrayService: MusicActivityTestTray(),
            sharingService: MusicActivityTestSharing(),
            musicService: music,
            hapticFeedbackService: MusicActivityTestHaptic(),
            nowPlayingPollIntervalNanoseconds: 3_600_000_000_000
        )
    }

    private func track(title: String, playing: Bool = false, artwork: Data? = nil) -> NowPlayingInfo {
        NowPlayingInfo(isPlaying: playing, title: title, artist: "艺人", album: "专辑",
                       duration: 120, position: 10, trackIdentifier: title, artworkData: artwork)
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

private actor MusicActivityTestService: MusicControlService {
    var info: NowPlayingInfo
    private(set) var toggleCount = 0
    private(set) var previousCount = 0
    private(set) var nextCount = 0
    private(set) var lastSeek: TimeInterval?

    init(info: NowPlayingInfo) { self.info = info }

    func setInfo(_ info: NowPlayingInfo) { self.info = info }
    func togglePlayPause() async throws { toggleCount += 1 }
    func skipBackward() async throws { previousCount += 1 }
    func skipForward() async throws { nextCount += 1 }
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool {
        lastSeek = position
        return true
    }
    func nowPlaying() async throws -> NowPlayingInfo { info }
}

private struct MusicActivityTestVolume: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

private struct MusicActivityTestTray: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

private struct MusicActivityTestSharing: SharingService {
    func share(urls: [URL]) throws {}
}

private struct MusicActivityTestHaptic: HapticFeedbackService {
    func performExpansionFeedback() {}
}
