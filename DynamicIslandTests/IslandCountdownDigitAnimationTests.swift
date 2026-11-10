import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

/// Keeps the actual renderer and Text identity mounted across a value change.
/// Intermediate native frames must differ from both endpoints; a disabled
/// animation transaction provides the same update without transition frames.
/// The read-only system reduced-motion setting is never changed by these tests.
@MainActor
final class IslandCountdownDigitAnimationTests: XCTestCase {
    func testMountedCountdownDigitsAnimateInCompactAndExpandedModes() async throws {
        for sample in [DigitSample.compact, .expanded] {
            try await verify(sample, disablesAnimations: false)
            try await verify(sample, disablesAnimations: true)
        }
    }

    func testMountedIdleTimerPresetUsesTheSameAnimatedDigitTransition() async throws {
        try await verify(.idlePreset, disablesAnimations: false)
        try await verify(.idlePreset, disablesAnimations: true)
    }

    private func verify(_ sample: DigitSample, disablesAnimations: Bool) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Native numeric transition evidence requires the system Reduce Motion preference to be off.")
        }
        let value = DigitProbeValue(sample.initial)
        let clock = IslandCountdownDisplayClock()
        let root = DigitProbeRoot(sample: sample, value: value, clock: clock)
            .environment(\.colorScheme, .dark)
            .transaction { if disablesAnimations { $0.disablesAnimations = true } }
            .environment(\.islandLayoutScale, sample.scale)
            .frame(width: sample.size.width, height: sample.size.height)
            .background(Color.black)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: sample.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close(); clock.shutdown() }
        try await Task.sleep(for: .milliseconds(250))

        let evidence = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-countdown-digit-animation", isDirectory: true)
            .appendingPathComponent(sample.rawValue + (disablesAnimations ? "-disabled" : "-animated"), isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        print("DIGIT_ANIMATION_EVIDENCE=\(evidence.path)")
        let start = try capture(hosting)
        try save(start, name: "00-start", in: evidence)
        XCTAssertGreaterThan(brightness(start), 10, "The fixture must paint actual timer digits")
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0, "Manual value changes must not start business/display polling")

        // Countdown references stay identical: only the Host-produced value and
        // its shared display invalidation change, exactly as a second tick does.
        value.text = sample.final
        clock.invalidate()
        var intermediate: [NSBitmapImageRep] = []
        for index in 1...10 {
            try await Task.sleep(for: .milliseconds(20))
            let frame = try capture(hosting)
            intermediate.append(frame)
            try save(frame, name: String(format: "%02d-mid", index), in: evidence)
        }
        // Numeric Text has its own native glyph settling. Require the mounted
        // view to converge to an independently mounted, animation-disabled
        // final value, rather than assuming a single wall-clock capture is final.
        let reference = try await staticReference(sample)
        try save(reference, name: "13-static-reference", in: evidence)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var end = try capture(hosting)
        var prior = end
        var stableSamples = 0
        while stableSamples < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            end = try capture(hosting)
            if difference(end, reference) < 0.005 && difference(end, prior) < 0.002 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            prior = end
        }
        try save(end, name: "11-end", in: evidence)
        XCTAssertEqual(stableSamples, 2, "The native transition must reach its static final glyphs within two seconds")
        XCTAssertLessThan(difference(end, reference), 0.005,
            "An animation endpoint must match the corresponding static Host rendering")
        try await Task.sleep(for: .milliseconds(140))
        let settled = try capture(hosting)
        try save(settled, name: "12-settled", in: evidence)

        let endpointDifference = difference(start, end)
        XCTAssertGreaterThan(endpointDifference, 0.025, "A real digit update must occur: \(sample.rawValue)")
        XCTAssertLessThan(difference(end, settled), 0.002,
            "The final glyphs must settle without continuing display or shell work")
        XCTAssertEqual(try XCTUnwrap(paintedBounds(start)).width,
                       try XCTUnwrap(paintedBounds(end)).width, accuracy: 2,
            "Equal-length monospaced ticks/presets must retain their layout width")
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)

        let distances = intermediate.map { (difference($0, start), difference($0, end)) }
        let diagnostic = "\(sample.rawValue) disabled=\(disablesAnimations), endpoints=\(endpointDifference), intermediate(start,end)=\(distances)"
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = sample.rawValue + (disablesAnimations ? " disabled transaction" : " animated") + " frame distances"
        attachment.lifetime = .keepAlways
        add(attachment)
        if disablesAnimations {
            XCTAssertTrue(distances.allSatisfy { $0.1 < 0.005 },
                "Disabled animations must immediately show final digits, without roll/fade frames: \(diagnostic)")
        } else {
            XCTAssertTrue(distances.contains { $0.0 > 0.025 && $0.1 > 0.025 },
                "A mounted numeric transition must paint a genuine intermediate glyph frame: \(diagnostic)")
        }
    }

    private func staticReference(_ sample: DigitSample) async throws -> NSBitmapImageRep {
        let value = DigitProbeValue(sample.final)
        let clock = IslandCountdownDisplayClock()
        let hosting = NSHostingView(rootView: DigitProbeRoot(sample: sample, value: value, clock: clock)
            .environment(\.colorScheme, .dark)
            .environment(\.islandLayoutScale, sample.scale)
            .transaction { $0.disablesAnimations = true }
            .frame(width: sample.size.width, height: sample.size.height)
            .background(Color.black))
        hosting.frame = CGRect(origin: .zero, size: sample.size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.contentView = hosting
        defer { window.close(); clock.shutdown() }
        try await Task.sleep(for: .milliseconds(100))
        return try capture(hosting)
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        let size = view.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String, in directory: URL) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = directory.lastPathComponent + "-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func brightness(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh { total += intensity(bitmap, x, y) }
        }
        return total
    }

    private func difference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        var delta = 0.0
        var covered = 0.0
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                let a = intensity(lhs, x, y), b = intensity(rhs, x, y)
                delta += abs(a - b)
                covered += max(a, b)
            }
        }
        return delta / max(1, covered)
    }

    private func intensity(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return Double(max(color.redComponent, color.greenComponent, color.blueComponent) * color.alphaComponent)
    }

    private func paintedBounds(_ image: NSBitmapImageRep) -> CGRect? {
        var result = CGRect.null
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh where intensity(image, x, y) > 0.15 {
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result.isNull ? nil : result
    }
}

private enum DigitSample: String {
    case compact, expanded, idlePreset
    var initial: String { self == .idlePreset ? "25:00" : "00:10" }
    var final: String { self == .idlePreset ? "45:00" : "00:09" }
    var scale: CGFloat { self == .compact ? 1.75 : 1 }
    var size: CGSize { self == .compact ? CGSize(width: 180, height: 70) : CGSize(width: 412, height: 134) }
    var mode: ActivityPresentation.Mode { self == .compact ? .compact : .expanded }
}

@MainActor
private final class DigitProbeValue: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

private struct DigitProbeRoot: View {
    let sample: DigitSample
    @ObservedObject var value: DigitProbeValue
    let clock: IslandCountdownDisplayClock

    var body: some View {
        let node: IslandNode = sample == .idlePreset
            ? .text(.init(value.text, font: .timer))
            : .countdown(.init(id: "focus", generation: "12345678-1234-1234-1234-123456789abc",
                              style: sample == .compact ? .time : .timer, color: .primary))
        let presentation = ActivityPresentation(title: "Numeric transition", compact: node, expanded: node)
        IslandRenderer(presentation: presentation, mode: sample.mode, shellSize: sample.size,
            countdownResolver: { _ in .init(text: value.text, progress: 0.5, requiresTick: false) },
            isVisible: true, displayClock: clock)
    }
}
