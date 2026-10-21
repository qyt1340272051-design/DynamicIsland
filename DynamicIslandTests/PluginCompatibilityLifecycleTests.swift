import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCompatibilityLifecycleTests: XCTestCase {
    func testDisabledPackageHasStaticUnrunProfileAndSuccessfulLayoutChangesOnlyCurrentReport() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: package))
        fixture.lifecycle.pluginDidLoad(package, isEnabled: false)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
        XCTAssertTrue(fixture.runtimes.isEmpty)

        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        let context = try XCTUnwrap(fixture.runtimes.last?.context)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.observation, .awaitingLayout)
        var changes = 0
        let observer = fixture.lifecycle.observeChanges { changes += 1 }
        defer { fixture.lifecycle.removeChangeObserver(observer) }
        try context.recordCompatibilityLayout([.hostButtonAppearance, .semanticColors])
        XCTAssertEqual(changes, 1)
        try context.recordCompatibilityLayout([.semanticColors, .hostButtonAppearance])
        XCTAssertEqual(changes, 1, "An identical accepted layout must not trigger another management refresh.")
        try context.recordCompatibilityLayout([.hostTextLineLimit])
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.layoutLimitations, [.hostTextLineLimit])
        try context.recordCompatibilityLayout([])
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.observation, .rendered)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.level, .limited)
        XCTAssertEqual(fixture.runtimes.count, 1)
    }

    func testDisableReenableClearsLayoutAndRejectsPreviousExecution() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let old = try XCTUnwrap(fixture.runtimes.last?.context)
        try old.recordCompatibilityLayout([.semanticColors])

        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
        assertInactive(old)
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.observation, .awaitingLayout)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.layoutLimitations, [])
        assertInactive(old)
        let current = try XCTUnwrap(fixture.runtimes.last?.context)
        try current.recordCompatibilityLayout([.hostIconAppearance])
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.layoutLimitations, [.hostIconAppearance])
    }

    func testSleepResumeAndExplicitStopCannotReuseOldLayoutOrContext() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let beforeSleep = try XCTUnwrap(fixture.runtimes.last?.context)
        try beforeSleep.recordCompatibilityLayout([.hostStackSpacing])

        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.observation, .notRun)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.layoutLimitations, [])
        assertInactive(beforeSleep)
        fixture.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package)?.observation, .awaitingLayout)
        assertInactive(beforeSleep)
        let resumed = try XCTUnwrap(fixture.runtimes.last?.context)
        try resumed.recordCompatibilityLayout([.hostStackAlignment])
        try fixture.lifecycle.stop(id: package.manifest.id)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
        assertInactive(resumed)
    }

    func testWakeAndLowBatteryRecoveryPublishNewExecutionSnapshotsToObservers() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let initial = try XCTUnwrap(fixture.runtimes.last?.context)
        try initial.recordCompatibilityLayout([.semanticColors])
        let lifecycle = fixture.lifecycle
        var observed: [PluginCompatibilitySnapshot?] = []
        let observer = lifecycle.observeChanges {
            observed.append(lifecycle.compatibilitySnapshot(for: package))
        }
        defer { lifecycle.removeChangeObserver(observer) }

        lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(observed.map { $0?.observation }, [.notRun, .awaitingLayout])
        XCTAssertTrue(observed.allSatisfy { $0?.layoutLimitations.isEmpty == true })
        assertInactive(initial)
        XCTAssertEqual(fixture.runtimes.count, 2)

        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(observed.count, 2, "Repeated healthy environment updates must not invent another execution or notification.")
        lifecycle.setEnvironment(isSleeping: false, isLowBattery: true)
        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        XCTAssertEqual(observed.map { $0?.observation }, [.notRun, .awaitingLayout, .notRun, .awaitingLayout])
        XCTAssertEqual(fixture.runtimes.count, 3)
    }

    func testRecoveryStoppedSynchronouslyDuringStartDoesNotPublishAStaleRunningSnapshot() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        fixture.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        let lifecycle = fixture.lifecycle
        fixture.onStart = { _ in
            lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        }
        var observations: [PluginCompatibilityObservation?] = []
        let observer = lifecycle.observeChanges {
            observations.append(lifecycle.compatibilitySnapshot(for: package)?.observation)
        }
        defer { lifecycle.removeChangeObserver(observer) }

        lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)

        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { $0 == .notRun })
        XCTAssertEqual(fixture.runtimes.count, 2)
        XCTAssertFalse(lifecycle.allowsExecution(id: package.manifest.id))
        XCTAssertEqual(lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
    }

    func testCompletePackageEqualityRejectsSameIDAndVersionWithChangedCodeOrLocation() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let first = try package(source: "first source")
        fixture.lifecycle.pluginDidLoad(first, isEnabled: true)
        let old = try XCTUnwrap(fixture.runtimes.last?.context)
        try old.recordCompatibilityLayout([.semanticColors])
        let replacement = try package(source: "changed code")
        XCTAssertEqual(first.manifest, replacement.manifest)
        XCTAssertEqual(first.canonicalRootURL, replacement.canonicalRootURL)
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: replacement))
        let moved = try package(source: "first source", root: "/different-installed-root")
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: moved))

        fixture.lifecycle.pluginDidLoad(replacement, isEnabled: true)
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: first))
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: replacement)?.observation, .awaitingLayout)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: replacement)?.layoutLimitations, [])
        assertInactive(old)
    }

    func testUnloadAndUninstallRemoveReportAndSameIDReinstallStartsUnrun() async throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let old = try XCTUnwrap(fixture.runtimes.last?.context)
        try old.recordCompatibilityLayout([.semanticColors])
        fixture.lifecycle.pluginWillUnload(id: package.manifest.id)
        await fixture.lifecycle.pluginDidUninstall(package)
        XCTAssertNil(fixture.lifecycle.compatibilitySnapshot(for: package))
        assertInactive(old)
        fixture.lifecycle.pluginDidLoad(package, isEnabled: false)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
        assertInactive(old)
    }

    func testNativeExecutionCannotWriteCompatibilityLayoutOrChangeItsProfile() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package(engine: .javaScriptCore)
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let context = try XCTUnwrap(fixture.runtimes.last?.context)
        let before = fixture.lifecycle.compatibilitySnapshot(for: package)
        XCTAssertEqual(before?.level, .native)
        XCTAssertEqual(before?.observation, .awaitingLayout)
        XCTAssertThrowsError(try context.recordCompatibilityLayout([.semanticColors])) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .unsupportedMethod)
        }
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), before)
    }

    func testStartFailureAndCleanupCallbacksCannotRetainLayout() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        var cleanupRejected = false
        fixture.onStart = { context in
            try context.recordCompatibilityLayout([.semanticColors])
            throw CompatibilityLifecycleTestError.expectedStartFailure
        }
        fixture.onStop = { context in
            XCTAssertThrowsError(try context?.recordCompatibilityLayout([.hostButtonAppearance])) {
                XCTAssertEqual($0 as? PluginExecutionError, .inactiveExecution)
                cleanupRejected = true
            }
        }
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        XCTAssertTrue(cleanupRejected)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: package.manifest.id)?.lastFailure, .startFailed)
        XCTAssertEqual(fixture.lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
    }

    func testObserverSynchronouslyDisablingExecutionCannotLeaveAReportBehind() throws {
        let fixture = CompatibilityLifecycleFixture()
        defer { fixture.lifecycle.shutdown() }
        let package = try package()
        fixture.lifecycle.pluginDidLoad(package, isEnabled: true)
        let context = try XCTUnwrap(fixture.runtimes.last?.context)
        let lifecycle = fixture.lifecycle
        var disabled = false
        let observer = lifecycle.observeChanges {
            guard !disabled else { return }
            disabled = true
            lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        }
        defer { lifecycle.removeChangeObserver(observer) }
        try context.recordCompatibilityLayout([.semanticColors])
        XCTAssertTrue(disabled)
        XCTAssertEqual(lifecycle.compatibilitySnapshot(for: package), .profile(for: .superIsland))
        assertInactive(context)
    }

    private func assertInactive(_ context: PluginExecutionContext,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try context.recordCompatibilityLayout([.semanticColors]), file: file, line: line) {
            XCTAssertEqual($0 as? PluginExecutionError, .inactiveExecution, file: file, line: line)
        }
    }

    private func package(source: String = "Host compatibility lifecycle fixture",
                         engine: PluginEngine = .superIsland,
                         root: String = "/compatibility-lifecycle-tests") throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: "com.example.compatibility-lifecycle", name: "Compatibility lifecycle fixture",
            version: SemanticVersion("1.0.0"), engine: engine, entry: "index.js",
            minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: [])
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: root), entryRelativePath: "index.js",
                     entrySource: Data(source.utf8), regularFileCount: 2, totalFileBytes: UInt64(source.utf8.count))
    }
}

@MainActor
private final class CompatibilityLifecycleFixture {
    var onStart: ((PluginExecutionContext) throws -> Void)?
    var onStop: ((PluginExecutionContext?) throws -> Void)?
    private(set) var runtimes: [CompatibilityLifecycleRuntime] = []
    let activities = ActivityManager(configuration: .immediate)
    lazy var router = ActionRouter(manager: activities)
    lazy var lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: router, runtimeFactory: { [unowned self] _ in
        let runtime = CompatibilityLifecycleRuntime(onStart: onStart, onStop: onStop)
        runtimes.append(runtime)
        return runtime
    })
}

@MainActor
private final class CompatibilityLifecycleRuntime: PluginLifecycleRuntime {
    private let startHook: ((PluginExecutionContext) throws -> Void)?
    private let stopHook: ((PluginExecutionContext?) throws -> Void)?
    private(set) var context: PluginExecutionContext?

    init(onStart: ((PluginExecutionContext) throws -> Void)?, onStop: ((PluginExecutionContext?) throws -> Void)?) {
        startHook = onStart
        stopHook = onStop
    }

    func onStart(context: PluginExecutionContext) throws {
        self.context = context
        try startHook?(context)
    }

    func onStop(reason: PluginStopReason) throws { try stopHook?(context) }
    func teardown() {}
}

private enum CompatibilityLifecycleTestError: Error { case expectedStartFailure }
