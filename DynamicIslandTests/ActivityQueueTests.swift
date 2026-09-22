import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityQueueTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 31_000)

    func testPersistentActivityRestoresAfterNestedPreemption() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let music = make("music", source: "music", priority: .background, policy: .persistent)
        let github = make("github", source: "github", priority: .normal, policy: .transient)
        let critical = make("battery", source: "battery", priority: .critical, policy: .critical)

        try manager.publish(music)
        try manager.publish(github)
        XCTAssertEqual(manager.current?.id, "github")
        XCTAssertEqual(manager.activity(id: "music")?.lifecycle.state, .background)
        try manager.publish(critical)
        XCTAssertEqual(manager.current?.id, "battery")
        try manager.end(id: "battery", source: critical.source)
        XCTAssertEqual(manager.current?.id, "github")
        try manager.end(id: "github", source: github.source)
        XCTAssertEqual(manager.current?.id, "music")
    }

    func testCurrentPeerStaysUntilEndThenQueuedPeerDisplays() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let github = make("github", source: "github", priority: .normal, policy: .transient)
        let airPods = make("airPods", source: "airPods", priority: .normal, policy: .transient)
        try manager.publish(github)
        try manager.publish(airPods)
        XCTAssertEqual(manager.current?.id, "github")
        try manager.end(id: "github", source: github.source)
        XCTAssertEqual(manager.current?.id, "airPods")
    }

    func testNonInterruptibleCurrentBlocksHigherRankUntilItEnds() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let current = make("guard", source: "guard", priority: .normal, policy: .critical)
        let higher = make("higher", source: "higher", priority: .critical, policy: .transient)
        try manager.publish(current)
        try manager.publish(higher)
        XCTAssertEqual(manager.current?.id, "guard")
        try manager.end(id: "guard", source: current.source)
        XCTAssertEqual(manager.current?.id, "higher")
    }

    func testMusicGitHubAirPodsCriticalCascadeRestoresMusic() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let music = make("music", source: "music", priority: .background, policy: .persistent)
        let github = make("github", source: "github", priority: .normal, policy: .transient)
        let airPods = make("airPods", source: "airPods", priority: .important, policy: .transient)
        let critical = make("critical", source: "battery", priority: .critical, policy: .critical)
        try manager.publish(music)
        XCTAssertEqual(manager.current?.id, "music")
        try manager.publish(github)
        XCTAssertEqual(manager.current?.id, "github")
        try manager.publish(airPods)
        XCTAssertEqual(manager.current?.id, "airPods")
        try manager.publish(critical)
        XCTAssertEqual(manager.current?.id, "critical")
        try manager.end(id: "critical", source: critical.source)
        XCTAssertEqual(manager.current?.id, "airPods")
        try manager.end(id: "airPods", source: airPods.source)
        XCTAssertEqual(manager.current?.id, "github")
        try manager.end(id: "github", source: github.source)
        XCTAssertEqual(manager.current?.id, "music")
    }

    func testNonInterruptibleNextReturnsUpdatedCurrentValue() throws {
        var current = make("critical", source: "battery", priority: .normal, policy: .critical)
        current.lifecycle = try current.lifecycle.applying(.present)
        var updated = current
        updated.presentation.title = "new title"
        let higher = make("higher", source: "other", priority: .critical, policy: .transient)
        let chosen = ActivityQueue.next([updated, higher], at: start, current: current)
        XCTAssertEqual(chosen?.id, "critical")
        XCTAssertEqual(chosen?.presentation.title, "new title")
    }

    private func make(_ id: String, source: String, priority: ActivityPriority, policy: ActivityLifecycle.Policy) -> IslandActivity {
        IslandActivity(id: id, source: ActivitySource(kind: .builtIn, identifier: source), priority: priority, lifecycle: ActivityLifecycle(policy: policy), presentation: ActivityPresentation(title: id), createdAt: start)
    }
}
