import Foundation
import XCTest
@testable import DynamicIsland

final class ActivityPriorityTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 20_000)

    func testBuiltInDefaultsAreFiniteAndPredictable() {
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.music), .background)
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.batteryCharging), .normal)
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.download), .normal)
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.batteryLow), .important)
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.timerCompletion), .important)
        XCTAssertEqual(ActivityPriority.defaultForBuiltIn(.batteryCritical), .critical)
        XCTAssertEqual(ActivityPriority.allCases.count, 4)
    }

    func testOrderingUsesPriorityInterruptionCurrentDisplayTimeAndID() {
        let candidates = [
            activity("music", .background, .persistent, at: 0),
            activity("normal-old", .normal, .transient, at: 0),
            activity("normal-current", .normal, .transient, at: 2),
            activity("normal-new", .normal, .transient, at: 3),
            activity("critical-interruptible", .critical, .transient, at: 0),
            activity("critical-uninterruptible", .critical, .critical, at: 4),
            activity("normal-same-time-b", .normal, .transient, at: 5),
            activity("normal-same-time-a", .normal, .transient, at: 5)
        ]

        let ordered = candidates.sorted {
            ActivityPriority.precedes($0, $1, currentlyPresentedID: "normal-current")
        }

        XCTAssertEqual(ordered.map(\.id), [
            "critical-uninterruptible", "critical-interruptible", "normal-current",
            "normal-old", "normal-new", "normal-same-time-a",
            "normal-same-time-b", "music"
        ])
    }

    private func activity(
        _ id: String,
        _ priority: ActivityPriority,
        _ policy: ActivityLifecycle.Policy,
        at seconds: TimeInterval
    ) -> IslandActivity {
        IslandActivity(
            id: id,
            source: ActivitySource(kind: .builtIn, identifier: "test"),
            priority: priority,
            lifecycle: ActivityLifecycle(policy: policy),
            presentation: ActivityPresentation(title: id),
            createdAt: start.addingTimeInterval(seconds)
        )
    }
}
