import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class VolumeActivityProviderTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 95_000)

    func testInitialNilEventDoesNotPublish() async {
        let volume = VolumeActivityTestVolume(initialVolume: 0.5)
        let model = makeModel(volume: volume)
        let manager = ActivityManager(configuration: .immediate)
        let provider = VolumeActivityProvider(viewModel: model, manager: manager, debounceNanoseconds: 0)

        await Task.yield()

        XCTAssertNil(manager.activity(id: VolumeActivityProvider.activityID))
        XCTAssertNil(manager.current)
        withExtendedLifetime(provider) {}
    }

    func testDebouncePublishesOnlyLatestVolumeEvent() async throws {
        let volume = VolumeActivityTestVolume(initialVolume: 0.5)
        let model = makeModel(volume: volume)
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let provider = VolumeActivityProvider(
            viewModel: model,
            manager: manager,
            debounceNanoseconds: 100_000_000,
            now: clock.now
        )

        volume.simulateExternal(volume: 0.2)
        try await waitFor { model.volumeActivityEvent?.volume == 0.2 }
        volume.simulateExternal(volume: 0.45)
        try await waitFor { model.volumeActivityEvent?.volume == 0.45 }
        volume.simulateExternal(volume: 0.82)
        try await waitFor { model.volumeActivityEvent?.volume == 0.82 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(manager.activity(id: VolumeActivityProvider.activityID))

        try await waitFor {
            guard let progress = manager.activity(id: VolumeActivityProvider.activityID)?.presentation.progress else {
                return false
            }
            return abs(progress - 0.82) < 0.000_1
        }
        let activity = try XCTUnwrap(manager.activity(id: VolumeActivityProvider.activityID))
        XCTAssertEqual(activity.presentation.progress ?? -1, 0.82, accuracy: 0.000_1)
        XCTAssertEqual(activity.presentation.subtitle, "82%")
        XCTAssertEqual(activity.createdAt, start)
        XCTAssertEqual(activity.expiresAt, start.addingTimeInterval(1.5))
        withExtendedLifetime(provider) {}
    }

    func testExternalValueIsRepublishedAfterSuppressedLocalRoundTrip() async throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            transientDuration: VolumeActivityProvider.presentationDuration,
            maximumTransientContinuousDuration: 10,
            ordinaryDebounce: 0,
            minimumDwell: 0
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let volume = VolumeActivityTestVolume(initialVolume: 0.5)
        let model = makeModel(volume: volume)
        let provider = VolumeActivityProvider(
            viewModel: model,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        volume.simulateExternal(volume: 0.4)
        try await waitFor { manager.current?.presentation.subtitle == "40%" }
        let first = try XCTUnwrap(manager.currentSnapshot)

        clock.advance(by: 1)
        model.setVolume(0.8)
        XCTAssertEqual(model.volumeActivityEvent, VolumeActivityEvent(volume: 0.4, isMuted: false))
        volume.simulateExternal(volume: 0.4)
        try await waitFor {
            manager.current?.expiresAt == self.start.addingTimeInterval(2.5)
        }

        let republished = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(republished.instanceToken, first.instanceToken)
        XCTAssertEqual(republished.activity.presentation.subtitle, "40%")
        XCTAssertEqual(republished.activity.expiresAt, start.addingTimeInterval(2.5))
        withExtendedLifetime(provider) {}
    }

    func testUpdateKeepsInstanceRenewsExpiryAndRestoresMusic() async throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            transientDuration: VolumeActivityProvider.presentationDuration,
            maximumTransientContinuousDuration: 10,
            ordinaryDebounce: 0,
            minimumDwell: 0
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let music = IslandActivity(
            id: "test.music",
            source: ActivitySource(kind: .builtIn, identifier: "test-music"),
            priority: .background,
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: ActivityPresentation(title: "音乐"),
            createdAt: start
        )
        try manager.publish(music)
        let volume = VolumeActivityTestVolume(initialVolume: 0.5)
        let model = makeModel(volume: volume)
        let provider = VolumeActivityProvider(
            viewModel: model,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        volume.simulateExternal(volume: 0.25)
        try await waitFor { manager.current?.id == VolumeActivityProvider.activityID }
        let first = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(first.activity.expiresAt, start.addingTimeInterval(1.5))

        clock.advance(by: 1)
        volume.simulateExternal(volume: 0.75)
        try await waitFor { manager.current?.presentation.progress == 0.75 }
        let renewed = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(renewed.instanceToken, first.instanceToken)
        XCTAssertEqual(renewed.activity.expiresAt, start.addingTimeInterval(2.5))

        clock.advance(by: 0.6)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, VolumeActivityProvider.activityID)

        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertNil(manager.activity(id: VolumeActivityProvider.activityID))
        XCTAssertEqual(manager.current?.id, music.id)
        withExtendedLifetime(provider) {}
    }

    func testFixedIdentityHasNoActionsAndEveryLayoutPassesHostPolicy() async throws {
        let volume = VolumeActivityTestVolume(initialVolume: 0.5)
        let model = makeModel(volume: volume)
        let manager = ActivityManager(configuration: .immediate)
        let provider = VolumeActivityProvider(viewModel: model, manager: manager, debounceNanoseconds: 0)

        volume.simulateExternal(volume: 0.6)
        try await waitFor { manager.current?.id == VolumeActivityProvider.activityID }
        let activity = try XCTUnwrap(manager.current)

        XCTAssertEqual(activity.id, "builtin.volume")
        XCTAssertEqual(activity.source, ActivitySource(kind: .builtIn, identifier: "volume"))
        XCTAssertEqual(activity.priority, .normal)
        XCTAssertEqual(activity.lifecycle.policy, .transient)
        XCTAssertTrue(activity.actions.isEmpty)
        for mode in ActivityPresentation.Mode.allCases {
            let node = activity.presentation.resolvedNode(for: mode)
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: mode), "\(mode)")
        }
        withExtendedLifetime(provider) {}
    }

    private func makeModel(volume: VolumeActivityTestVolume) -> IslandViewModel {
        IslandViewModel(
            volumeService: volume,
            fileTrayService: VolumeActivityTestTray(),
            sharingService: VolumeActivityTestSharing(),
            musicService: VolumeActivityTestMusic(),
            hapticFeedbackService: VolumeActivityTestHaptic(),
            nowPlayingPollIntervalNanoseconds: 3_600_000_000_000
        )
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for Volume Activity")
    }
}

private final class VolumeActivityTestVolume: VolumeService, @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float
    private var muted = false
    private var observation: (@Sendable () -> Void)?

    init(initialVolume: Float) {
        level = initialVolume
    }

    func currentVolume() throws -> Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    func isMuted() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func setVolume(_ volume: Float) throws {
        lock.lock()
        level = volume
        muted = volume == 0
        lock.unlock()
    }

    func setMuted(_ muted: Bool) throws {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation? {
        lock.lock()
        observation = handler
        lock.unlock()
        return nil
    }

    func simulateExternal(volume: Float, isMuted: Bool = false) {
        let handler: (@Sendable () -> Void)?
        lock.lock()
        level = volume
        muted = isMuted
        handler = observation
        lock.unlock()
        handler?()
    }
}

private struct VolumeActivityTestTray: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

private struct VolumeActivityTestSharing: SharingService {
    func share(urls: [URL]) throws {}
}

private actor VolumeActivityTestMusic: MusicControlService {
    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool { false }
    func nowPlaying() async throws -> NowPlayingInfo { .empty }
}

private struct VolumeActivityTestHaptic: HapticFeedbackService {
    func performExpansionFeedback() {}
}
