import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCrashWatchdogTests: XCTestCase {
    func testThirdAcceptedSeriousFailureCreatesOneQuarantine() throws {
        let clock = CrashWatchdogTestClock(0)
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        let package = try package()
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = 10
        XCTAssertNil(watchdog.recordFailure(kind: .actionException, package: package))
        clock.now = 20
        let incident = try XCTUnwrap(watchdog.recordFailure(kind: .actionRejection, package: package))
        XCTAssertEqual(incident.pluginID, package.manifest.id)
        XCTAssertEqual(incident.kind, .actionRejection)
        XCTAssertEqual(incident.packageFingerprint.count, 64)
        XCTAssertTrue(watchdog.isCurrent(incident: incident, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 3)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.quarantine, incident)
    }

    func testRollingWindowExpiresOldFailuresBeforeCountingNewOnes() throws {
        let clock = CrashWatchdogTestClock(0)
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        let package = try package()
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = 30
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = 60.001
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 2)
        clock.now = 70
        XCTAssertNotNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
    }

    func testExactlySixtySecondsRemainsInTheWindow() throws {
        let clock = CrashWatchdogTestClock(0)
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        let package = try package()
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = 30
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = 60
        XCTAssertNotNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
    }

    func testRepeatedSamePackageRegistrationDoesNotResetRestartBudget() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let package = try package()
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(try watchdog.register(package: package).recentFailureCount, 1)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(try watchdog.register(package: package).recentFailureCount, 2)
        let incident = try XCTUnwrap(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(try watchdog.register(package: package).quarantine, incident)
    }

    func testDeclarationReorderingAndRelocatedPackagePreserveTheBinding() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let original = try package(permissions: [.network, .localStorage], capabilities: [.scheduler, .localStorage])
        let relocated = try package(permissions: [.localStorage, .network], capabilities: [.localStorage, .scheduler],
                                    root: "/tmp/watchdog-relocated")
        try watchdog.register(package: original)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: original))
        XCTAssertEqual(try watchdog.register(package: relocated).recentFailureCount, 1)
        XCTAssertNil(watchdog.recordFailure(kind: .actionException, package: relocated))
        XCTAssertNotNil(watchdog.recordFailure(kind: .actionRejection, package: relocated))
    }

    func testMetadataReplacementResetsHistoryAndInvalidatesOldIncident() throws {
        for replacement in [try package(name: "Replacement"), try package(version: "1.0.1"),
                            try package(entry: "replacement.js"), try package(minimumHost: "0.6.1"),
                            try package(permissions: [.network]), try package(capabilities: [.scheduler])] {
            let watchdog = PluginCrashWatchdog(clock: { 100 })
            let original = try package()
            let incident = try quarantine(original, with: watchdog)
            let snapshot = try watchdog.register(package: replacement)
            XCTAssertEqual(snapshot.recentFailureCount, 0)
            XCTAssertNil(snapshot.quarantine)
            XCTAssertFalse(watchdog.isCurrent(incident: incident, package: original))
            XCTAssertFalse(watchdog.isCurrent(incident: incident, package: replacement))
            XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: original))
            XCTAssertEqual(watchdog.snapshot(id: replacement.manifest.id)?.recentFailureCount, 0)
        }
    }

    func testSameLengthEntryReplacementResetsBindingAndReturningCodeStartsFresh() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let first = try package(source: "const code = 1;")
        let next = try package(source: "const code = 2;")
        let incident = try quarantine(first, with: watchdog)
        XCTAssertNil(try watchdog.register(package: next).quarantine)
        XCTAssertFalse(watchdog.isCurrent(incident: incident, package: first))
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: first))
        XCTAssertNil(try watchdog.register(package: first).quarantine)
        XCTAssertEqual(watchdog.snapshot(id: first.manifest.id)?.recentFailureCount, 0)
    }

    func testExplicitClearKeepsHistoryAndNextFailureCreatesANewIncident() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let package = try package()
        let first = try quarantine(package, with: watchdog)
        XCTAssertTrue(watchdog.clearQuarantine(incident: first, package: package))
        XCTAssertFalse(watchdog.isCurrent(incident: first, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 3)
        let second = try XCTUnwrap(watchdog.recordFailure(kind: .actionException, package: package))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertFalse(watchdog.clearQuarantine(incident: first, package: package))
        XCTAssertTrue(watchdog.isCurrent(incident: second, package: package))
    }

    func testClearRejectsWrongIdentityAndReplacementPackage() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let first = try package()
        let second = try package(id: "com.example.watchdog.other")
        let firstIncident = try quarantine(first, with: watchdog)
        let secondIncident = try quarantine(second, with: watchdog)
        XCTAssertFalse(watchdog.clearQuarantine(incident: firstIncident, package: second))
        XCTAssertFalse(watchdog.clearQuarantine(incident: secondIncident, package: first))
        XCTAssertFalse(watchdog.clearQuarantine(incident: firstIncident, package: try package(source: "replacement")))
        XCTAssertTrue(watchdog.isCurrent(incident: firstIncident, package: first))
    }

    func testUnregisterForgetsHistoryAndMakesOldPersistenceCallbackStale() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let package = try package()
        let incident = try quarantine(package, with: watchdog)
        watchdog.unregister(pluginID: package.manifest.id)
        XCTAssertNil(watchdog.snapshot(id: package.manifest.id))
        XCTAssertEqual(watchdog.registrationCount, 0)
        XCTAssertFalse(watchdog.isCurrent(incident: incident, package: package))
        XCTAssertEqual(try watchdog.register(package: package).recentFailureCount, 0)
        XCTAssertFalse(watchdog.isCurrent(incident: incident, package: package))
    }

    func testIdentitiesHaveIndependentHistories() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let first = try package()
        let second = try package(id: "com.example.watchdog.other")
        try watchdog.register(package: first)
        try watchdog.register(package: second)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: first))
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: second))
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: first))
        XCTAssertNotNil(watchdog.recordFailure(kind: .runtimeStart, package: first))
        XCTAssertNil(watchdog.snapshot(id: second.manifest.id)?.quarantine)
        XCTAssertEqual(watchdog.snapshot(id: second.manifest.id)?.recentFailureCount, 1)
    }

    func testHostRegistrationQuotaAndRemovalAreBounded() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        for index in 0..<128 { try watchdog.register(package: package(id: "com.example.watchdog.p\(index)")) }
        XCTAssertEqual(watchdog.registrationCount, 128)
        try watchdog.register(package: package(id: "com.example.watchdog.p0", source: "changed"))
        XCTAssertEqual(watchdog.registrationCount, 128)
        XCTAssertThrowsError(try watchdog.register(package: package(id: "com.example.watchdog.extra"))) {
            XCTAssertEqual($0 as? PluginCrashWatchdogError, .quotaExceeded)
        }
        watchdog.unregister(pluginID: "com.example.watchdog.p0")
        try watchdog.register(package: package(id: "com.example.watchdog.extra"))
        XCTAssertEqual(watchdog.registrationCount, 128)
    }

    func testInvalidClockCannotAddAnIncidentAndBackwardClockCannotEraseFailures() throws {
        let clock = CrashWatchdogTestClock(100)
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        let package = try package()
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        clock.now = .nan
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 1)
        clock.now = 10
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertNotNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
    }

    func testQuarantineRemainsAfterFailureWindowExpiresUntilExplicitClear() throws {
        let clock = CrashWatchdogTestClock(100)
        let watchdog = PluginCrashWatchdog(clock: { clock.now })
        let package = try package()
        let incident = try quarantine(package, with: watchdog)
        clock.now = 161
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 0)
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.quarantine, incident)
        XCTAssertTrue(watchdog.clearQuarantine(incident: incident, package: package))
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertEqual(watchdog.snapshot(id: package.manifest.id)?.recentFailureCount, 1)
    }

    func testUnregisteredPackageDoesNotCreateImplicitHistory() throws {
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let package = try package()
        for _ in 0..<5 { XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package)) }
        XCTAssertNil(watchdog.snapshot(id: package.manifest.id))
        XCTAssertEqual(watchdog.registrationCount, 0)
    }

    private func quarantine(_ package: ValidatedPluginPackage,
                            with watchdog: PluginCrashWatchdog) throws -> PluginCrashIncident {
        try watchdog.register(package: package)
        XCTAssertNil(watchdog.recordFailure(kind: .runtimeStart, package: package))
        XCTAssertNil(watchdog.recordFailure(kind: .actionException, package: package))
        return try XCTUnwrap(watchdog.recordFailure(kind: .actionRejection, package: package))
    }

    private func package(id: String = "com.example.watchdog.plugin", name: String = "Watchdog Test",
                         version: String = "1.0.0", entry: String = "main.js", minimumHost: String = "0.6.0",
                         permissions: [PluginPermission] = [.localStorage],
                         capabilities: [PluginCapability] = [.publishActivity], source: String = "const code = 1;",
                         root: String = "/tmp/watchdog-original") throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: name, version: SemanticVersion(version), engine: .javaScriptCore,
                                          entry: entry, minimumHostVersion: SemanticVersion(minimumHost),
                                          permissions: permissions, capabilities: capabilities)
        return ValidatedPluginPackage(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: root),
                                      entryRelativePath: entry, entrySource: Data(source.utf8),
                                      regularFileCount: 2, totalFileBytes: UInt64(source.utf8.count))
    }
}

@MainActor
private final class CrashWatchdogTestClock {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}
