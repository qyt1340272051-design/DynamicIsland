import XCTest
@testable import DynamicIsland

final class PluginCompatibilitySnapshotTests: XCTestCase {
    func testValidatedEngineSelectsStaticProfileWithoutClaimingExecution() {
        let native = PluginCompatibilitySnapshot.profile(for: .javaScriptCore)
        XCTAssertEqual(native.engine, .javaScriptCore)
        XCTAssertEqual(native.level, .native)
        XCTAssertEqual(native.observation, .notRun)
        XCTAssertTrue(native.profileLimitations.isEmpty)
        XCTAssertTrue(native.layoutLimitations.isEmpty)

        let compatible = PluginCompatibilitySnapshot.profile(for: .superIsland)
        XCTAssertEqual(compatible.engine, .superIsland)
        XCTAssertEqual(compatible.level, .limited)
        XCTAssertEqual(compatible.observation, .notRun)
        XCTAssertEqual(compatible.profileLimitations, Set(PluginCompatibilityProfileLimitation.allCases))
        XCTAssertTrue(compatible.layoutLimitations.isEmpty)
        XCTAssertFalse(PluginEngine.allCases.map { PluginCompatibilitySnapshot.profile(for: $0).level }.contains(.compatible))
    }

    func testSuccessfulLayoutDoesNotRemoveProfileRestrictionsOrUpgradeLevel() {
        let profile = PluginCompatibilitySnapshot.profile(for: .superIsland)
        let rendered = profile.executionDidStart().recordingLayout([])

        XCTAssertEqual(rendered.observation, .rendered)
        XCTAssertEqual(rendered.level, .limited)
        XCTAssertEqual(rendered.profileLimitations, profile.profileLimitations)
        XCTAssertTrue(rendered.layoutLimitations.isEmpty)
    }

    func testLatestSuccessfulLayoutReplacesPriorReasonsAndNewExecutionStartsEmpty() {
        let profile = PluginCompatibilitySnapshot.profile(for: .superIsland)
        let first = profile.executionDidStart().recordingLayout([.hostButtonAppearance, .semanticColors])
        let next = first.recordingLayout([.hostIconAppearance])

        XCTAssertEqual(next.layoutLimitations, [.hostIconAppearance])
        XCTAssertEqual(first.layoutLimitations, [.hostButtonAppearance, .semanticColors])
        let restarted = next.executionDidStart()
        XCTAssertEqual(restarted.observation, .awaitingLayout)
        XCTAssertTrue(restarted.layoutLimitations.isEmpty)
        XCTAssertEqual(restarted.level, .limited)
    }

    func testFiniteReasonsHaveStableDisplayOrderAndHostChosenCopy() {
        let profile = PluginCompatibilitySnapshot.profile(for: .superIsland)
        let snapshot = profile.recordingLayout([.semanticColors, .hostTextTypography, .hostStackSpacing])
        XCTAssertEqual(snapshot.profileLimitationsInDisplayOrder, PluginCompatibilityProfileLimitation.allCases)
        XCTAssertEqual(snapshot.layoutLimitationsInDisplayOrder, [.hostTextTypography, .hostStackSpacing, .semanticColors])
        XCTAssertEqual(PluginCompatibilityLayoutLimitation.allCases.count, 8)
        XCTAssertNil(PluginCompatibilityLayoutLimitation(rawValue: "pluginProvidedCompatibility"))
        for reason in PluginCompatibilityProfileLimitation.allCases {
            XCTAssertFalse(reason.title.isEmpty)
            XCTAssertFalse(reason.description.isEmpty)
        }
        for reason in PluginCompatibilityLayoutLimitation.allCases {
            XCTAssertFalse(reason.title.isEmpty)
            XCTAssertFalse(reason.description.isEmpty)
        }
        XCTAssertEqual(PluginCompatibilityObservation.notRun.title, "当前未运行")
        XCTAssertEqual(PluginCompatibilityObservation.rendered.title, "最近成功布局")
    }
}
