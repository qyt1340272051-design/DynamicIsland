import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCountdownRendererTests: XCTestCase {
    func testMultipleConsumersShareOneTimerAndLastReleaseRejectsLatePulses() async throws {
        let clock = IslandCountdownDisplayClock()
        defer { clock.shutdown() }
        let first = UUID()
        let second = UUID()
        clock.setNeedsTicks(true, for: first)
        clock.setNeedsTicks(true, for: first)
        clock.setNeedsTicks(true, for: second)
        XCTAssertEqual(clock.consumerCount, 2)
        XCTAssertEqual(clock.timerCount, 1)
        try await waitUntil { clock.revision > 0 }

        clock.setNeedsTicks(false, for: first)
        XCTAssertEqual(clock.consumerCount, 1)
        XCTAssertEqual(clock.timerCount, 1)
        let remainingConsumerRevision = clock.revision
        try await waitUntil { clock.revision > remainingConsumerRevision }

        clock.setNeedsTicks(false, for: second)
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)
        let stoppedRevision = clock.revision
        // Also cancel a replacement generation before either old task can wake.
        clock.setNeedsTicks(true, for: first)
        clock.setNeedsTicks(false, for: first)
        try await Task.sleep(for: .milliseconds(1_150))
        XCTAssertEqual(clock.revision, stoppedRevision)
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)
    }

    func testMountedTimeAndProgressRefreshThenProjectCompletionWithoutBusinessCallback() async throws {
        let time = CountdownRendererManualClock()
        let broker = PluginCountdownBroker(clock: { time.now }, automaticScheduling: false)
        let displayClock = IslandCountdownDisplayClock()
        let owner = try broker.registerOwner(pluginID: "com.example.renderer")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 4_000)
        let completion = CountdownRendererCompletionCapture()
        let observer = try broker.observeCompletions(owner: owner) { completion.events.append($0) }
        let reads = CountdownRendererReadCapture()
        let visibility = CountdownRendererVisibility(isVisible: true)
        let presentation = twoLeafPresentation(generation: started.generation.rawValue)
        let fixture = mount(presentation: presentation, visibility: visibility, clock: displayClock) { reference in
            reads.record(reference)
            guard let generation = PluginCountdownGeneration(rawValue: reference.generation),
                  let snapshot = broker.snapshotForDisplay(owner: owner, id: reference.id, generation: generation) else {
                return nil
            }
            return .init(text: snapshot.displayText, progress: snapshot.elapsedFraction,
                         requiresTick: snapshot.requiresDisplayTick)
        }
        defer {
            fixture.close()
            displayClock.shutdown()
            broker.shutdown()
        }
        let initialPNG = try png(fixture.hostingView)
        try await waitUntil { displayClock.consumerCount == 2 }
        XCTAssertEqual(displayClock.timerCount, 1)
        attach(initialPNG, name: "Countdown running 00-04")

        var previousRevision = displayClock.revision
        var previousReads = reads.counts
        time.now = .seconds(1)
        try await waitUntil {
            displayClock.revision > previousRevision && reads.exceeds(previousReads, styles: [.time, .progress])
        }
        let advancedPNG = try png(fixture.hostingView)
        XCTAssertNotEqual(advancedPNG, initialPNG)
        attach(advancedPNG, name: "Countdown running 00-03")

        previousRevision = displayClock.revision
        previousReads = reads.counts
        time.now = .seconds(2)
        try await waitUntil {
            displayClock.revision > previousRevision && reads.exceeds(previousReads, styles: [.time, .progress])
        }
        XCTAssertEqual(displayClock.consumerCount, 2)
        XCTAssertTrue(completion.events.isEmpty)

        time.now = .seconds(4)
        try await waitUntil { displayClock.consumerCount == 0 && displayClock.timerCount == 0 }
        let completedPNG = try png(fixture.hostingView)
        XCTAssertNotEqual(completedPNG, advancedPNG)
        attach(completedPNG, name: "Countdown completed 00-00")
        XCTAssertTrue(completion.events.isEmpty, "Display projection must not deliver a business completion.")
        XCTAssertEqual(broker.diagnostics.runningCount, 1, "Rendering must not settle the stored record.")
        XCTAssertEqual(broker.diagnostics.completedCount, 0)
        let stoppedRevision = displayClock.revision
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(displayClock.revision, stoppedRevision)

        broker.processDue()
        XCTAssertEqual(completion.events.count, 1)
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: started.id,
                                                     generation: started.generation, observerToken: observer))
        broker.processDue()
        XCTAssertEqual(completion.events.count, 1)
    }

    func testMountedHiddenRendererOnlyTicksWhileExplicitlyVisible() async throws {
        let clock = IslandCountdownDisplayClock()
        let visibility = CountdownRendererVisibility(isVisible: false)
        let reads = CountdownRendererReadCapture()
        let fixture = mount(presentation: twoLeafPresentation(), visibility: visibility, clock: clock) { reference in
            reads.record(reference)
            return .init(text: "00:30", progress: 0.5, requiresTick: true)
        }
        defer { fixture.close(); clock.shutdown() }
        _ = try png(fixture.hostingView)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(reads.counts[IslandCountdownStyleToken.time.rawValue, default: 0], 0)
        XCTAssertGreaterThan(reads.counts[IslandCountdownStyleToken.progress.rawValue, default: 0], 0)
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)
        let hiddenRevision = clock.revision
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(clock.revision, hiddenRevision)

        visibility.isVisible = true
        try await waitUntil { clock.consumerCount == 2 && clock.timerCount == 1 }
        let visibleRevision = clock.revision
        let visibleReads = reads.counts
        try await waitUntil {
            clock.revision > visibleRevision && reads.exceeds(visibleReads, styles: [.time, .progress])
        }
        visibility.isVisible = false
        try await waitUntil { clock.consumerCount == 0 && clock.timerCount == 0 }
        let releasedRevision = clock.revision
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(clock.revision, releasedRevision)
    }

    func testMountedPausedAndInvalidReferencesDoNotRequestDisplayTicks() async throws {
        let clock = IslandCountdownDisplayClock()
        let reads = CountdownRendererReadCapture()
        let fixture = mount(presentation: twoLeafPresentation(),
                            visibility: .init(isVisible: true), clock: clock) { reference in
            reads.record(reference)
            return reference.style == .time
                ? .init(text: "00:12", progress: 0.6, requiresTick: false) : nil
        }
        defer { fixture.close(); clock.shutdown() }
        let image = try png(fixture.hostingView)
        XCTAssertFalse(image.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(reads.counts[IslandCountdownStyleToken.time.rawValue, default: 0], 0)
        XCTAssertGreaterThan(reads.counts[IslandCountdownStyleToken.progress.rawValue, default: 0], 0)
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)
        let revision = clock.revision
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(clock.revision, revision)
        XCTAssertEqual(clock.consumerCount, 0)
    }

    func testAcceptedOverflowTreeUsesSummaryWithoutHiddenCountdownConsumers() async throws {
        let clock = IslandCountdownDisplayClock()
        let reads = CountdownRendererReadCapture()
        let node: IslandNode = .vStack(.init((0..<7).map { _ in
            .countdown(.init(id: "focus", generation: Self.generation, style: .time))
        }))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: .expanded))
        let fixture = mount(presentation: .init(title: "Overflow summary", expanded: node),
                            visibility: .init(isVisible: true), clock: clock) { reference in
            reads.record(reference)
            return .init(text: "24:00:00", progress: 0, requiresTick: true)
        }
        defer { fixture.close(); clock.shutdown() }
        let image = try png(fixture.hostingView)
        attach(image, name: "Accepted overflowing countdown tree summary")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(image.isEmpty)
        XCTAssertEqual(clock.consumerCount, 0,
                       "A measured ViewThatFits candidate must not retain invisible countdown leaves.")
        XCTAssertEqual(clock.timerCount, 0)
        let revision = clock.revision
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(clock.revision, revision)
    }

    private static let generation = "12345678-1234-1234-1234-123456789abc"

    private func twoLeafPresentation(generation: String = IslandCountdownRendererTests.generation) -> ActivityPresentation {
        .init(title: "Countdown", expanded: .vStack(.init([
            .countdown(.init(id: "focus", generation: generation, style: .time)),
            .countdown(.init(id: "focus", generation: generation, style: .progress))
        ])))
    }

    private func mount(presentation: ActivityPresentation, visibility: CountdownRendererVisibility,
                       clock: IslandCountdownDisplayClock,
                       resolver: @escaping IslandRenderer.CountdownResolver) -> CountdownRendererMountedView {
        let driver = CountdownRendererDriver(presentation: presentation, visibility: visibility,
                                             clock: clock, resolver: resolver)
        let hostingView = NSHostingView(rootView: driver.environment(\.colorScheme, .dark))
        hostingView.frame = CGRect(x: 0, y: 0, width: 412, height: 134)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hostingView
        return .init(hostingView: hostingView, window: window)
    }

    private func png(_ hostingView: NSView) throws -> Data {
        let size = hostingView.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func attach(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3),
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Countdown renderer did not settle before the deadline.", file: file, line: line)
                throw CountdownRendererTestError.conditionTimedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class CountdownRendererVisibility: ObservableObject {
    @Published var isVisible: Bool
    init(isVisible: Bool) { self.isVisible = isVisible }
}

private struct CountdownRendererDriver: View {
    let presentation: ActivityPresentation
    @ObservedObject var visibility: CountdownRendererVisibility
    let clock: IslandCountdownDisplayClock
    let resolver: IslandRenderer.CountdownResolver

    var body: some View {
        IslandRenderer(presentation: presentation, mode: .expanded,
                       shellSize: CGSize(width: 428, height: 184),
                       countdownResolver: resolver, isVisible: visibility.isVisible,
                       displayClock: clock)
    }
}

@MainActor
private struct CountdownRendererMountedView {
    let hostingView: NSView
    let window: NSWindow
    func close() { window.contentView = nil; window.close() }
}

@MainActor
private final class CountdownRendererReadCapture {
    var counts: [String: Int] = [:]
    func record(_ reference: IslandNode.Countdown) { counts[reference.style.rawValue, default: 0] += 1 }
    func exceeds(_ previous: [String: Int], styles: [IslandCountdownStyleToken]) -> Bool {
        styles.allSatisfy { counts[$0.rawValue, default: 0] > previous[$0.rawValue, default: 0] }
    }
}

@MainActor
private final class CountdownRendererManualClock { var now: Duration = .zero }

@MainActor
private final class CountdownRendererCompletionCapture { var events: [PluginCountdownCompletion] = [] }

private enum CountdownRendererTestError: Error { case conditionTimedOut }
