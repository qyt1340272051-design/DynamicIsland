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

    func testRuntimeScopesBrokerResourcesToOwningSource() {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        let artwork = IslandNode.ImageSource.brokerResource(id: MusicActivityProvider.artworkResourceID)

        XCTAssertNil(runtime.resolveImage(
            artwork,
            for: ActivitySource(kind: .builtIn, identifier: "another-provider")
        ))
        XCTAssertNil(runtime.resolveImage(
            .brokerResource(id: "another.resource"),
            for: MusicActivityProvider.source
        ))
    }
}
