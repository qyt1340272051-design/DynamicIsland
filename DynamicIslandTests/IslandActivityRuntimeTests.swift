import AppKit
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandActivityRuntimeTests: XCTestCase {
    func testProductionRuntimeSharesMusicActivityAndActionRouter() throws {
        let viewModel = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: viewModel)
        let snapshot = try XCTUnwrap(runtime.manager.currentSnapshot)

        XCTAssertEqual(snapshot.activity.id, MusicActivityProvider.activityID)
        XCTAssertEqual(snapshot.activity.source, MusicActivityProvider.source)
        XCTAssertEqual(snapshot.activity.lifecycle.policy, .persistent)
        XCTAssertFalse(runtime.isCompactActivityVisible)

        let result = runtime.router.dispatch(
            id: snapshot.activity.id,
            source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken,
            action: .init(actionID: MusicActivityProvider.volumeActionID, value: .sliderCommit(0.75))
        )

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(viewModel.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
    }

    func testRuntimeUsesCurrentPresentationForCompactVisibility() throws {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        let source = ActivitySource(kind: .builtIn, identifier: "test")
        try runtime.manager.publish(IslandActivity(
            id: "test.hidden",
            source: source,
            priority: .critical,
            lifecycle: .init(policy: .critical),
            presentation: .init(title: "Hidden", showsCompact: false),
            createdAt: Date()
        ))

        XCTAssertEqual(runtime.manager.current?.id, "test.hidden")
        XCTAssertFalse(runtime.isCompactActivityVisible)
        try runtime.manager.end(id: "test.hidden", source: source)

        try runtime.manager.publish(IslandActivity(
            id: "test.visible",
            source: source,
            priority: .critical,
            lifecycle: .init(policy: .critical),
            presentation: .init(title: "Visible", showsCompact: true),
            createdAt: Date()
        ))

        XCTAssertEqual(runtime.manager.current?.id, "test.visible")
        XCTAssertTrue(runtime.isCompactActivityVisible)
    }

    func testRuntimeForwardsOwnedArtworkToMusicProviderAndScopesOtherResources() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let artworkData = try XCTUnwrap(image.tiffRepresentation)
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: true,
            title: "Resolver",
            artist: "Artist",
            album: "Album",
            trackIdentifier: "resolver-track",
            artworkData: artworkData
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)
        let artwork = IslandNode.ImageSource.brokerResource(id: MusicActivityProvider.artworkResourceID)

        XCTAssertNotNil(runtime.resolveImage(artwork, for: MusicActivityProvider.source))
        XCTAssertNil(runtime.resolveImage(
            artwork,
            for: ActivitySource(kind: .builtIn, identifier: "another-provider")
        ))
        XCTAssertNil(runtime.resolveImage(
            .brokerResource(id: "another.resource"),
            for: MusicActivityProvider.source
        ))
    }

    func testMusicPlayingAndPausedUpdatesDriveRuntimeCompactVisibility() async throws {
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: true,
            title: "正在播放",
            artist: "艺人",
            album: "专辑",
            trackIdentifier: "visibility-track"
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)

        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.presentation.title, "正在播放")
        XCTAssertTrue(runtime.isCompactActivityVisible)

        await service.setInfo(NowPlayingInfo(
            isPlaying: false,
            title: "已暂停",
            artist: "艺人",
            album: "专辑",
            trackIdentifier: "visibility-track"
        ))
        await model.refreshNowPlaying()

        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.presentation.title, "已暂停")
        XCTAssertFalse(runtime.isCompactActivityVisible)
    }
}
