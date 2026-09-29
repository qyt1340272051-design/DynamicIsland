import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityStressTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 97_000)

    func testHundredActivitiesCompletePublishUpdateAndEndCycle() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let music = makeActivity(
            id: "stress.music",
            source: .init(kind: .builtIn, identifier: "stress.music"),
            priority: .background,
            policy: .persistent,
            title: "Music"
        )
        try manager.publish(music)
        let musicToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)

        let entries = (0..<100).map { index in
            let id = String(format: "stress-%03d", index)
            let source = ActivitySource(
                kind: .plugin,
                identifier: String(format: "stress.source.%02d", index % 20)
            )
            return (id: id, source: source, index: index)
        }

        for entry in entries.reversed() {
            try manager.publish(makeActivity(
                id: entry.id,
                source: entry.source,
                priority: .normal,
                policy: .progress,
                title: "Initial \(entry.index)",
                progress: Double(entry.index) / 99
            ))
        }

        XCTAssertEqual(manager.current?.id, "stress-099")
        let firstToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)
        XCTAssertEqual(entries.compactMap { manager.activity(id: $0.id) }.count, 100)
        XCTAssertTrue(entries.allSatisfy { manager.activity(id: $0.id)?.createdAt == start })
        assertManagerInvariants(manager, knownIDs: [music.id] + entries.map(\.id))

        for entry in entries {
            try manager.update(makeActivity(
                id: entry.id,
                source: entry.source,
                priority: .normal,
                policy: .progress,
                title: "Updated \(entry.index)",
                progress: Double(99 - entry.index) / 99
            ))
        }

        XCTAssertEqual(manager.currentSnapshot?.instanceToken, firstToken)
        for entry in entries {
            let activity = try XCTUnwrap(manager.activity(id: entry.id))
            XCTAssertEqual(activity.presentation.title, "Updated \(entry.index)")
            XCTAssertEqual(
                activity.presentation.progress ?? -1,
                Double(99 - entry.index) / 99,
                accuracy: 0.000_1
            )
        }
        assertManagerInvariants(manager, knownIDs: [music.id] + entries.map(\.id))

        let endOrder = [entries[99]] + Array(entries[0..<99])
        for (offset, entry) in endOrder.enumerated() {
            XCTAssertEqual(manager.current?.id, entry.id)
            try manager.end(id: entry.id, source: entry.source)
            XCTAssertNil(manager.activity(id: entry.id))
            if offset + 1 < endOrder.count {
                XCTAssertEqual(manager.current?.id, endOrder[offset + 1].id)
            }
        }

        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, musicToken)
        XCTAssertTrue(entries.allSatisfy { manager.activity(id: $0.id) == nil })
        assertManagerInvariants(manager, knownIDs: [music.id] + entries.map(\.id))

        try manager.end(id: music.id, source: music.source)
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
    }

    func testHundredSameIDUpdatesKeepOneInstanceAndOriginalDeadline() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            transientDuration: 3,
            ordinaryDebounce: 0,
            minimumDwell: 0
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let music = makeActivity(
            id: "update.music",
            source: .init(kind: .builtIn, identifier: "update.music"),
            priority: .background,
            policy: .persistent,
            title: "Music"
        )
        try manager.publish(music)
        let musicToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)

        let source = ActivitySource(kind: .plugin, identifier: "stress.same-id")
        try manager.publish(makeActivity(
            id: "stress.same-id",
            source: source,
            priority: .normal,
            policy: .transient,
            title: "Revision 0"
        ))
        let first = try XCTUnwrap(manager.currentSnapshot)

        for revision in 1...100 {
            try manager.update(makeActivity(
                id: "stress.same-id",
                source: source,
                priority: .normal,
                policy: .transient,
                title: "Revision \(revision)",
                progress: Double(revision) / 100
            ))
        }

        let updated = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(updated.instanceToken, first.instanceToken)
        XCTAssertEqual(updated.activity.createdAt, start)
        XCTAssertEqual(updated.activity.presentation.title, "Revision 100")
        XCTAssertEqual(updated.activity.presentation.progress ?? -1, 1, accuracy: 0.000_1)

        clock.advance(by: 2.9)
        try manager.update(makeActivity(
            id: "stress.same-id",
            source: source,
            priority: .normal,
            policy: .transient,
            title: "Last update"
        ))
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, first.instanceToken)

        clock.advance(by: 0.2)
        manager.processDeadlines()
        XCTAssertNil(manager.activity(id: "stress.same-id"))
        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, musicToken)
        XCTAssertThrowsError(try manager.end(id: "stress.same-id", source: source)) {
            XCTAssertEqual($0 as? ActivityManagerError, .notFound)
        }
    }

    func testThirtyTwoSameSecondSourcesPreemptAndRestoreDeterministically() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            transientDuration: 30,
            criticalMaximumDuration: 30,
            ordinaryDebounce: 0,
            minimumDwell: 0,
            maximumQueuedAge: 60,
            maximumQueuedNormal: 64
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let music = makeActivity(
            id: "same-second.music",
            source: .init(kind: .builtIn, identifier: "same-second.music"),
            priority: .background,
            policy: .persistent,
            title: "Music"
        )
        try manager.publish(music)
        let musicToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)

        let normals = makeEntries(prefix: "normal", count: 26, priority: .normal, policy: .transient)
        let importants = makeEntries(prefix: "important", count: 4, priority: .important, policy: .transient)
        let criticals = makeEntries(prefix: "critical", count: 2, priority: .critical, policy: .critical)

        for entry in normals {
            try manager.publish(entry.activity)
        }
        XCTAssertEqual(manager.current?.id, normals[0].activity.id)
        let normalToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)

        for entry in importants {
            try manager.publish(entry.activity)
        }
        XCTAssertEqual(manager.current?.id, importants[0].activity.id)
        let importantToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)

        for entry in criticals {
            try manager.publish(entry.activity)
        }
        XCTAssertEqual(manager.current?.id, criticals[0].activity.id)

        let allEntries = normals + importants + criticals
        XCTAssertEqual(allEntries.count, 32)
        XCTAssertTrue(allEntries.allSatisfy {
            manager.activity(id: $0.activity.id)?.createdAt == start
        })
        XCTAssertEqual(Set(allEntries.map { $0.activity.source }).count, 32)

        var updatedNormal = normals[0].activity
        updatedNormal.presentation.title = "Updated normal"
        try manager.update(updatedNormal)
        var updatedImportant = importants[0].activity
        updatedImportant.presentation.title = "Updated important"
        try manager.update(updatedImportant)

        try manager.end(id: criticals[0].activity.id, source: criticals[0].activity.source)
        XCTAssertEqual(manager.current?.id, criticals[1].activity.id)
        try manager.end(id: criticals[1].activity.id, source: criticals[1].activity.source)
        XCTAssertEqual(manager.current?.id, importants[0].activity.id)
        XCTAssertEqual(manager.current?.presentation.title, "Updated important")
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, importantToken)

        for (index, entry) in importants.enumerated() {
            XCTAssertEqual(manager.current?.id, entry.activity.id)
            try manager.end(id: entry.activity.id, source: entry.activity.source)
            if index + 1 < importants.count {
                XCTAssertEqual(manager.current?.id, importants[index + 1].activity.id)
            }
        }

        XCTAssertEqual(manager.current?.id, normals[0].activity.id)
        XCTAssertEqual(manager.current?.presentation.title, "Updated normal")
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, normalToken)
        for (index, entry) in normals.enumerated() {
            XCTAssertEqual(manager.current?.id, entry.activity.id)
            try manager.end(id: entry.activity.id, source: entry.activity.source)
            if index + 1 < normals.count {
                XCTAssertEqual(manager.current?.id, normals[index + 1].activity.id)
            }
        }

        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, musicToken)
        assertManagerInvariants(
            manager,
            knownIDs: [music.id] + allEntries.map { $0.activity.id }
        )
    }

    func testDefaultCapacityBoundsHundredQueuedNormalsThenDeadlineAndAgeRemoveThem() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            criticalMaximumDuration: 1_000,
            ordinaryDebounce: 0,
            minimumDwell: 0
        )
        XCTAssertEqual(configuration.maximumQueuedNormal, 8)
        XCTAssertEqual(configuration.maximumQueuedAge, 8)
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let guardSource = ActivitySource(kind: .builtIn, identifier: "stress.guard")
        try manager.publish(makeActivity(
            id: "stress.guard",
            source: guardSource,
            priority: .critical,
            policy: .critical,
            title: "Guard"
        ))

        let entries = (0..<100).map { index -> (id: String, source: ActivitySource) in
            (
                id: String(format: "queue-%03d", index),
                source: ActivitySource(
                    kind: .plugin,
                    identifier: String(format: "queue.source.%02d", index % 10)
                )
            )
        }
        for (index, entry) in entries.enumerated() {
            let expiresAt = index >= 96 ? start.addingTimeInterval(2) : nil
            try manager.publish(makeActivity(
                id: entry.id,
                source: entry.source,
                priority: .normal,
                policy: .transient,
                title: entry.id,
                expiresAt: expiresAt
            ))
        }

        let initiallyRetained = entries.compactMap {
            manager.activity(id: $0.id) == nil ? nil : $0.id
        }
        XCTAssertEqual(initiallyRetained, (92..<100).map { String(format: "queue-%03d", $0) })
        XCTAssertTrue(initiallyRetained.allSatisfy {
            manager.activity(id: $0)?.lifecycle.state == .queued
        })
        XCTAssertEqual(manager.current?.id, "stress.guard")

        clock.advance(by: 2.1)
        manager.processDeadlines()
        let afterAbsoluteDeadline = entries.compactMap {
            manager.activity(id: $0.id) == nil ? nil : $0.id
        }
        XCTAssertEqual(afterAbsoluteDeadline, (92..<96).map { String(format: "queue-%03d", $0) })

        clock.advance(by: 6)
        manager.processDeadlines()
        XCTAssertTrue(entries.allSatisfy { manager.activity(id: $0.id) == nil })
        XCTAssertEqual(manager.current?.id, "stress.guard")

        try manager.end(id: "stress.guard", source: guardSource)
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
    }

    func testSchedulerKeepsOneStableSleepAndCancelsItOnTeardown() async throws {
        let clock = TrackedActivityClock(start)
        let source = ActivitySource(kind: .plugin, identifier: "stress.scheduler")
        weak var weakManager: ActivityManager?
        var manager: ActivityManager? = ActivityManager(clock: clock, configuration: .immediate)
        weakManager = manager

        var activity = makeActivity(
            id: "stress.scheduler",
            source: source,
            priority: .normal,
            policy: .progress,
            title: "Revision 0",
            expiresAt: start.addingTimeInterval(300)
        )
        try manager?.publish(activity)

        for revision in 1...100 {
            activity.presentation.title = "Revision \(revision)"
            activity.expiresAt = start.addingTimeInterval(300 - Double(revision))
            try manager?.update(activity)
            if revision.isMultiple(of: 10) {
                await Task.yield()
            }
        }

        try await waitFor {
            clock.cancellationCount > 0 && clock.sleepStartCount > 1
        }
        try await waitForStableSleepCount(1, on: clock)
        XCTAssertEqual(clock.activeSleepCount, 1)
        XCTAssertGreaterThan(clock.sleepStartCount, 1)

        manager = nil
        try await waitFor { weakManager == nil }
        try await waitForStableSleepCount(0, on: clock)
        XCTAssertNil(weakManager)
        XCTAssertEqual(clock.activeSleepCount, 0)
    }

    func testHundredDetachedSourcesSerializeAndDrainWithoutDeadlock() async throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let activities = (0..<100).map { index in
            makeActivity(
                id: String(format: "concurrent-%03d", index),
                source: ActivitySource(
                    kind: .plugin,
                    identifier: String(format: "concurrent.source.%03d", index)
                ),
                priority: .normal,
                policy: .progress,
                title: "Initial \(index)"
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for activity in activities {
                group.addTask {
                    try await manager.publish(activity)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(manager.diagnostics.activityCount, 100)
        assertManagerInvariants(manager, knownIDs: activities.map(\.id))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for var activity in activities {
                activity.presentation.title = "Updated \(activity.id)"
                group.addTask {
                    try await manager.update(activity)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertTrue(activities.allSatisfy {
            manager.activity(id: $0.id)?.presentation.title == "Updated \($0.id)"
        })
        assertManagerInvariants(manager, knownIDs: activities.map(\.id))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for activity in activities {
                group.addTask {
                    try await manager.end(id: activity.id, source: activity.source)
                }
            }
            try await group.waitForAll()
        }

        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(
            manager.diagnostics,
            ActivityManagerDiagnostics(
                activityCount: 0,
                instanceTokenCount: 0,
                displayDeadlineCount: 0,
                firstPresentedCount: 0,
                rateLimitedSourceCount: 0,
                scheduledWakeDeadline: nil
            )
        )
    }

    func testHundredActivityLifecyclePerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
            do {
                for index in 0..<100 {
                    let source = ActivitySource(
                        kind: .plugin,
                        identifier: String(format: "performance.source.%03d", index)
                    )
                    let id = String(format: "performance-%03d", index)
                    var activity = makeActivity(
                        id: id,
                        source: source,
                        priority: .normal,
                        policy: .progress,
                        title: "Initial \(index)"
                    )
                    try manager.publish(activity)
                    activity.presentation.title = "Updated \(index)"
                    try manager.update(activity)
                    try manager.end(id: id, source: source)
                }
            } catch {
                XCTFail("100 Activity performance cycle failed: \(error)")
            }
        }
    }

    private func makeEntries(
        prefix: String,
        count: Int,
        priority: ActivityPriority,
        policy: ActivityLifecycle.Policy
    ) -> [(activity: IslandActivity, index: Int)] {
        (0..<count).map { index in
            let id = String(format: "%@-%02d", prefix, index)
            return (
                activity: makeActivity(
                    id: id,
                    source: ActivitySource(kind: .plugin, identifier: "source.\(id)"),
                    priority: priority,
                    policy: policy,
                    title: id
                ),
                index: index
            )
        }
    }

    private func makeActivity(
        id: String,
        source: ActivitySource,
        priority: ActivityPriority,
        policy: ActivityLifecycle.Policy,
        title: String,
        progress: Double? = nil,
        expiresAt: Date? = nil
    ) -> IslandActivity {
        IslandActivity(
            id: id,
            source: source,
            priority: priority,
            lifecycle: ActivityLifecycle(policy: policy),
            presentation: ActivityPresentation(
                title: title,
                progress: progress
            ),
            createdAt: start,
            expiresAt: expiresAt
        )
    }

    private func assertManagerInvariants(
        _ manager: ActivityManager,
        knownIDs: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stored = knownIDs.compactMap { manager.activity(id: $0) }
        let presented = stored.filter { $0.lifecycle.state == .presented }
        XCTAssertLessThanOrEqual(presented.count, 1, file: file, line: line)
        XCTAssertEqual(manager.currentSnapshot?.activity, manager.current, file: file, line: line)
        if let current = manager.current {
            XCTAssertEqual(presented.map(\.id), [current.id], file: file, line: line)
        } else {
            XCTAssertTrue(presented.isEmpty, file: file, line: line)
            XCTAssertNil(manager.currentSnapshot, file: file, line: line)
        }
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for Activity stress condition")
    }

    private func waitForStableSleepCount(
        _ expected: Int,
        on clock: TrackedActivityClock
    ) async throws {
        var consecutiveMatches = 0
        for _ in 0..<500 {
            if clock.activeSleepCount == expected {
                consecutiveMatches += 1
                if consecutiveMatches == 10 { return }
            } else {
                consecutiveMatches = 0
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Sleep count did not settle at \(expected)")
    }
}

private nonisolated final class TrackedActivityClock: ActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var activeSleeps = 0
    private var sleepStarts = 0
    private var cancellations = 0

    init(_ date: Date) {
        self.date = date
    }

    var activeSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeSleeps
    }

    var sleepStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepStarts
    }

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        beginSleep()
        defer { endSleep() }
        do {
            while now() < deadline {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        } catch {
            if Task.isCancelled {
                recordCancellation()
            }
            throw error
        }
    }

    private func beginSleep() {
        lock.lock()
        activeSleeps += 1
        sleepStarts += 1
        lock.unlock()
    }

    private func endSleep() {
        lock.lock()
        activeSleeps -= 1
        lock.unlock()
    }

    private func recordCancellation() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }
}
