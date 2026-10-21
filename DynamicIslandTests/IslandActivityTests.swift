import Foundation
import XCTest
@testable import DynamicIsland

final class IslandActivityTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 10_000)

    func testMusicBatteryAndDownloadAreDataOnlyAndCodable() throws {
        let music = IslandActivity(
            id: "builtin.music.now-playing",
            source: ActivitySource(kind: .builtIn, identifier: "music"),
            priority: .defaultForBuiltIn(.music),
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: ActivityPresentation(
                title: "Now Playing", subtitle: "Example Artist", symbolName: "music.note"
            ),
            createdAt: start,
            actions: [ActivityAction(id: "playPause", title: "Play or pause")]
        )
        let battery = IslandActivity(
            id: "system.battery.low",
            source: ActivitySource(kind: .external, identifier: "battery"),
            priority: .important,
            lifecycle: ActivityLifecycle(policy: .transient),
            presentation: ActivityPresentation(
                title: "Low Battery", subtitle: "15% remaining", symbolName: "battery.25percent"
            ),
            createdAt: start,
            expiresAt: start.addingTimeInterval(5)
        )
        let download = IslandActivity(
            id: "plugin.example.download.42",
            source: ActivitySource(kind: .plugin, identifier: "com.example.downloads"),
            priority: .normal,
            lifecycle: ActivityLifecycle(policy: .progress),
            presentation: ActivityPresentation(
                title: "Downloading", subtitle: "Archive.zip", progress: 0.25
            ),
            createdAt: start,
            actions: [ActivityAction(id: "cancel", title: "Cancel")]
        )

        let examples = [music, battery, download]
        let decoded = try JSONDecoder().decode(
            [IslandActivity].self, from: JSONEncoder().encode(examples)
        )

        XCTAssertEqual(decoded, examples)
        XCTAssertEqual(Set(examples.map(\.source.kind)), [.builtIn, .external, .plugin])
        XCTAssertEqual(download.presentation.progress, 0.25)
    }

    func testUpdatingOneEventRetainsIdentityAndCreationTime() {
        var activity = IslandActivity(
            id: "plugin.example.download.42",
            source: ActivitySource(kind: .plugin, identifier: "com.example.downloads"),
            priority: .normal,
            lifecycle: ActivityLifecycle(policy: .progress),
            presentation: ActivityPresentation(title: "Downloading", progress: 0.1),
            createdAt: start
        )
        activity.presentation.progress = 0.9

        XCTAssertEqual(activity.id, "plugin.example.download.42")
        XCTAssertEqual(activity.createdAt, start)
        XCTAssertEqual(activity.presentation.progress, 0.9)
    }

    func testExpirationUsesInclusiveBoundary() {
        let activity = IslandActivity(
            id: "airpods.connected",
            source: ActivitySource(kind: .external, identifier: "airPods"),
            priority: .normal,
            lifecycle: ActivityLifecycle(policy: .transient),
            presentation: ActivityPresentation(title: "AirPods Connected"),
            createdAt: start,
            expiresAt: start.addingTimeInterval(3)
        )

        XCTAssertFalse(activity.isExpired(at: start.addingTimeInterval(2.99)))
        XCTAssertTrue(activity.isExpired(at: start.addingTimeInterval(3)))
    }
}
