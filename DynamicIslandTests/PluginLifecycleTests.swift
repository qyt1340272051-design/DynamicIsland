import Foundation
import XCTest
@testable import DynamicIsland

final class PluginLifecycleTests: XCTestCase {
    func testLifecycleRunsSuspendsResumesAndStopsBeforeReloading() throws {
        var lifecycle = PluginLifecycle()

        XCTAssertEqual(lifecycle.state, .installed)
        XCTAssertEqual(try lifecycle.transition(.load), .loaded)
        XCTAssertEqual(try lifecycle.transition(.start), .running)
        XCTAssertTrue(lifecycle.state.allowsExecution)
        XCTAssertEqual(try lifecycle.transition(.suspend), .suspended)
        XCTAssertFalse(lifecycle.state.allowsExecution)
        XCTAssertEqual(try lifecycle.transition(.resume), .running)
        XCTAssertEqual(try lifecycle.transition(.stop), .stopped)
        XCTAssertFalse(lifecycle.state.allowsExecution)
        XCTAssertEqual(try lifecycle.transition(.load), .loaded)
        XCTAssertEqual(try lifecycle.transition(.start), .running)
    }

    func testEveryStateAndEventPairMatchesAllowedTransitionTable() throws {
        let allowed: [PluginLifecycleState: [PluginLifecycleEvent: PluginLifecycleState]] = [
            .installed: [.load: .loaded, .disable: .disabled],
            .loaded: [.start: .running, .stop: .stopped, .disable: .disabled],
            .running: [.suspend: .suspended, .stop: .stopped, .disable: .disabled],
            .suspended: [.resume: .running, .stop: .stopped, .disable: .disabled],
            .stopped: [.load: .loaded, .disable: .disabled],
            .disabled: [.enable: .installed, .disable: .disabled]
        ]

        for state in PluginLifecycleState.allCases {
            for event in PluginLifecycleEvent.allCases {
                var lifecycle = PluginLifecycle(state: state)
                if let expected = allowed[state]?[event] {
                    XCTAssertEqual(try lifecycle.transition(event), expected, "\(state) + \(event)")
                    XCTAssertEqual(lifecycle.state, expected, "\(state) + \(event)")
                } else {
                    XCTAssertThrowsError(try lifecycle.transition(event), "\(state) + \(event)") { error in
                        XCTAssertEqual(
                            error as? PluginLifecycleError,
                            .invalidTransition(from: state, event: event)
                        )
                    }
                    XCTAssertEqual(lifecycle.state, state, "Rejected transition must preserve \(state)")
                }
            }
        }
    }

    func testOnlyRunningStateAllowsPluginExecution() {
        for state in PluginLifecycleState.allCases {
            XCTAssertEqual(state.allowsExecution, state == .running, "\(state)")
        }
    }

    func testDisablingRevokesExecutionFromEveryStateAndIsIdempotent() throws {
        for state in PluginLifecycleState.allCases {
            var lifecycle = PluginLifecycle(state: state)

            XCTAssertEqual(try lifecycle.transition(.disable), .disabled)
            XCTAssertFalse(lifecycle.state.allowsExecution)
            XCTAssertEqual(try lifecycle.transition(.disable), .disabled)
            XCTAssertFalse(lifecycle.state.allowsExecution)
            XCTAssertThrowsError(try lifecycle.transition(.start))
            XCTAssertThrowsError(try lifecycle.transition(.resume))
            XCTAssertThrowsError(try lifecycle.transition(.load))
            XCTAssertEqual(lifecycle.state, .disabled)
        }
    }

    func testEnablingRequiresLoadingAndStartingBeforeExecution() throws {
        var lifecycle = PluginLifecycle(state: .disabled)

        XCTAssertEqual(try lifecycle.transition(.enable), .installed)
        XCTAssertFalse(lifecycle.state.allowsExecution)
        XCTAssertThrowsError(try lifecycle.transition(.start))
        XCTAssertEqual(try lifecycle.transition(.load), .loaded)
        XCTAssertFalse(lifecycle.state.allowsExecution)
        XCTAssertEqual(try lifecycle.transition(.start), .running)
        XCTAssertTrue(lifecycle.state.allowsExecution)
    }

    func testInvalidTransitionHasStableDiagnosticAndPreservesState() {
        var lifecycle = PluginLifecycle(state: .suspended)

        XCTAssertThrowsError(try lifecycle.transition(.start)) { error in
            let lifecycleError = error as? PluginLifecycleError
            XCTAssertEqual(lifecycleError, .invalidTransition(from: .suspended, event: .start))
            XCTAssertEqual(lifecycleError?.code, "invalidLifecycleTransition")
            XCTAssertEqual(
                lifecycleError?.errorDescription,
                "Plugin lifecycle cannot apply \"start\" while \"suspended\"."
            )
        }
        XCTAssertEqual(lifecycle.state, .suspended)
        XCTAssertFalse(lifecycle.state.allowsExecution)
    }
}
