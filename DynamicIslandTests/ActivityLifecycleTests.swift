import XCTest
@testable import DynamicIsland

final class ActivityLifecycleTests: XCTestCase {
    func testTransientHintCanPresentThenExpire() throws {
        let queued = ActivityLifecycle(policy: .transient)
        let presented = try queued.applying(.present)
        let ended = try presented.applying(.expire)

        XCTAssertEqual(presented.state, .presented)
        XCTAssertEqual(ended.state, .ended)
        XCTAssertTrue(ended.isTerminal)
    }

    func testPersistentMusicCanBackgroundAndResume() throws {
        let queued = ActivityLifecycle(policy: .persistent)
        let presented = try queued.applying(.present)
        let background = try presented.applying(.moveToBackground)
        let resumed = try background.applying(.present)

        XCTAssertEqual(background.state, .background)
        XCTAssertEqual(resumed.state, .presented)
    }

    func testDismissOnlyHidesUntilSourceEnds() throws {
        let progress = ActivityLifecycle(policy: .progress)
        let dismissed = try progress.applying(.dismiss)
        let ended = try dismissed.applying(.sourceEnd)

        XCTAssertEqual(dismissed.state, .dismissed)
        XCTAssertFalse(dismissed.isTerminal)
        XCTAssertEqual(ended.state, .ended)
        XCTAssertThrowsError(try dismissed.applying(.present))
    }

    func testCriticalPolicyBlocksPeerInterruptionAndEndedIsTerminal() throws {
        let critical = ActivityLifecycle(policy: .critical)
        XCTAssertFalse(critical.policy.isInterruptible)
        XCTAssertTrue(ActivityLifecycle.Policy.progress.isInterruptible)

        let ended = try critical.applying(.sourceEnd)
        XCTAssertThrowsError(try ended.applying(.present)) { error in
            guard case .some(.invalid(state: .ended, event: .present)) = error as? ActivityLifecycle.TransitionError else {
                return XCTFail("Expected an invalid transition from ended to presented")
            }
        }
        XCTAssertThrowsError(try ended.applying(.sourceEnd))
    }
}
