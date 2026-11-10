import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class MusicRefreshLatencyTests: XCTestCase {
    func testOlderMetadataResponseCannotReplaceNewTrack() async throws {
        let service = OrderedMusicRefreshService()
        let model = model(service: service)
        try await waitUntil { await service.calls > 0 }
        await service.holdNext()
        let old = Task { await model.refreshNowPlaying() }
        try await waitUntil { await service.isHolding }
        await service.setCurrent(track("new"))
        await model.refreshNowPlaying()
        await service.completeHeld(with: .success(track("old")))
        await old.value

        XCTAssertEqual(model.nowPlaying.trackIdentifier, "new")
    }

    func testOlderFailureCannotOverwriteSuccessfulRefresh() async throws {
        let service = OrderedMusicRefreshService()
        let model = model(service: service)
        try await waitUntil { await service.calls > 0 }
        await service.holdNext()
        let old = Task { await model.refreshNowPlaying() }
        try await waitUntil { await service.isHolding }
        await service.setCurrent(track("new"))
        await model.refreshNowPlaying()
        await service.completeHeld(with: .failure(PluginMusicError.timedOut))
        await old.value

        XCTAssertEqual(model.nowPlaying.trackIdentifier, "new")
        XCTAssertNil(model.musicErrorMessage)
    }

    func testCompletedReadCanDisplayWhileNewerReadIsStillWaiting() async throws {
        let service = OrderedMusicRefreshService()
        let model = model(service: service)
        try await waitUntil { await service.calls > 0 }
        await service.holdNext()
        let first = Task { await model.refreshNowPlaying() }
        try await waitUntil { await service.heldCount == 1 }
        await service.holdNext()
        let next = Task { await model.refreshNowPlaying() }
        try await waitUntil { await service.heldCount == 2 }
        await service.completeHeld(with: .success(track("first")))
        await first.value
        XCTAssertEqual(model.nowPlaying.trackIdentifier, "first",
                       "A pending newer request must not leave an already completed read undisplayed.")
        await service.completeHeld(with: .success(track("next")))
        await next.value
        XCTAssertEqual(model.nowPlaying.trackIdentifier, "next")
    }

    func testPollCadenceIncludesTheTimeSpentReading() async throws {
        let service = TimedMusicRefreshService()
        let model = model(service: service, interval: 500_000_000)
        try await waitUntil { await service.starts.count >= 2 }
        let times = await service.measurements()
        let idleGap = Double(times.secondStart - times.firstEnd) / 1_000_000_000
        XCTAssertLessThan(idleGap, 0.4, "Reading for 300ms must not add another full 500ms polling sleep.")
        withExtendedLifetime(model) {}
    }

    func testHidingStopsPollsAndShowingStartsAFreshRead() async throws {
        let service = OrderedMusicRefreshService()
        let model = model(service: service, interval: 20_000_000)
        try await waitUntil { await service.calls >= 2 }
        model.setIslandPanelVisible(false)
        let count = await service.calls
        try await Task.sleep(for: .milliseconds(100))
        let hiddenCount = await service.calls
        XCTAssertEqual(hiddenCount, count)
        model.setIslandPanelVisible(true)
        try await waitUntil { await service.calls > hiddenCount }
        model.setIslandPanelVisible(false)
    }

    func testSlowReadSkipsTicksWithoutOverlappingOrCatchingUpInABurst() async throws {
        let service = TimedMusicRefreshService()
        let model = model(service: service, interval: 30_000_000)
        try await waitUntil { await service.starts.count >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        let firstCount = await service.starts.count
        XCTAssertEqual(firstCount, 1)
        try await waitUntil { await service.starts.count >= 2 }
        let concurrency = await service.maximumConcurrentReads
        XCTAssertEqual(concurrency, 1)
        model.setIslandPanelVisible(false)
    }

    private func model(service: any MusicControlService, interval: UInt64 = 3_600_000_000_000) -> IslandViewModel {
        IslandViewModel(volumeService: MusicActivityTestVolume(), fileTrayService: MusicActivityTestTray(),
            sharingService: MusicActivityTestSharing(), musicService: service,
            hapticFeedbackService: MusicActivityTestHaptic(), nowPlayingPollIntervalNanoseconds: interval)
    }

    private func track(_ id: String) -> NowPlayingInfo {
        .init(isPlaying: true, title: id, artist: "Artist", album: "Album", trackIdentifier: id)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

private actor OrderedMusicRefreshService: MusicControlService {
    private(set) var calls = 0
    private var holdsNext = false
    private var held: [Int: CheckedContinuation<NowPlayingInfo, Error>] = [:]
    private var current = NowPlayingInfo.empty
    var isHolding: Bool { !held.isEmpty }
    var heldCount: Int { held.count }
    func holdNext() { holdsNext = true }
    func setCurrent(_ info: NowPlayingInfo) { current = info }
    func completeHeld(with result: Result<NowPlayingInfo, Error>) {
        guard let call = held.keys.min() else { return }
        held.removeValue(forKey: call)?.resume(with: result)
    }
    func nowPlaying() async throws -> NowPlayingInfo {
        calls += 1
        if holdsNext {
            holdsNext = false
            let call = calls
            return try await withCheckedThrowingContinuation { held[call] = $0 }
        }
        return current
    }
    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool { false }
}

private actor TimedMusicRefreshService: MusicControlService {
    private(set) var starts: [UInt64] = []
    private var ends: [UInt64] = []
    private var activeReads = 0
    private(set) var maximumConcurrentReads = 0
    func nowPlaying() async throws -> NowPlayingInfo {
        starts.append(DispatchTime.now().uptimeNanoseconds)
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        try await Task.sleep(for: .milliseconds(300))
        ends.append(DispatchTime.now().uptimeNanoseconds)
        return .empty
    }
    func measurements() -> (firstEnd: UInt64, secondStart: UInt64) { (ends[0], starts[1]) }
    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool { false }
}
