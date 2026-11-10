import Foundation
import XCTest
@testable import DynamicIsland

final class MusicSourceDetectorTests: XCTestCase {
    func testDecoderAcceptsOnlySupportedSourceIdentitiesAndEmptyStates() throws {
        for bundle in SystemMusicSourceDetector.supportedBundleIdentifiers {
            let data = try JSONSerialization.data(withJSONObject: ["status": "source", "bundleIdentifier": bundle])
            XCTAssertEqual(try SystemMusicSourceDetector.parse(data), .source(bundleIdentifier: bundle))
        }
        XCTAssertEqual(try SystemMusicSourceDetector.parse(Data(#"{"status":"none"}"#.utf8)), .none)
        XCTAssertEqual(try SystemMusicSourceDetector.parse(Data(#"{"status":"unsupported"}"#.utf8)), .unsupported)
    }

    func testDecoderRejectsUnknownAppsMetadataAndMalformedResponses() {
        for response in [
            #"{"status":"source","bundleIdentifier":"com.example.browser"}"#,
            #"{"status":"source"}"#,
            #"{"status":"none","bundleIdentifier":"com.apple.Music"}"#,
            #"{"status":"unsupported","title":"private song"}"#,
            #"{"status":"source","bundleIdentifier":"com.spotify.client","title":"private song"}"#,
            #"{"status":"other"}"#, #"{"status":true}"#, "[]", "not JSON",
            #"{"status":"error","error":"arbitrary details"}"#,
            #"{"status":"none","error":"queryFailed"}"#,
            String(repeating: " ", count: SystemMusicSourceDetector.maximumOutputBytes + 1)
        ] {
            XCTAssertThrowsError(try SystemMusicSourceDetector.parse(Data(response.utf8))) {
                XCTAssertEqual($0 as? PluginMusicError, .invalidResponse)
            }
        }
    }

    func testKnownSystemFailuresNeverBecomeAnIdleOrFallbackSource() {
        for code in ["unsupportedSystem", "queryFailed", "invalidArguments"] {
            XCTAssertThrowsError(try SystemMusicSourceDetector.parse(Data("{\"status\":\"error\",\"error\":\"\(code)\"}".utf8))) {
                XCTAssertEqual($0 as? PluginMusicError, .helperFailed)
            }
        }
    }

    func testDetectionUsesInjectedReadOnlyRunnerAndPropagatesCancellation() async throws {
        let runner = DetectionRunnerFixture()
        let detector = SystemMusicSourceDetector(runner: runner)
        let result = try await detector.activeSource()
        XCTAssertEqual(result, .source(bundleIdentifier: "com.spotify.client"))
        let calls = await runner.calls()
        XCTAssertEqual(calls, 1)

        let waiting = DetectionRunnerFixture(suspends: true)
        let pending = Task { try await SystemMusicSourceDetector(runner: waiting).activeSource() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await waiting.calls() == 0 {
            guard ContinuousClock.now < deadline else { XCTFail("Detector did not start"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("A cancelled detector delivered a source") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancellations = await waiting.cancellations()
        XCTAssertEqual(cancellations, 1)
    }

    func testCancellationBeforeDetectionDoesNotLaunchRunner() async throws {
        let runner = DetectionRunnerFixture()
        let gate = DetectionCancellationGate()
        let pending = Task {
            await gate.wait()
            return try await SystemMusicSourceDetector(runner: runner).activeSource()
        }
        pending.cancel()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Cancelled task detected a source") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await runner.calls()
        XCTAssertEqual(calls, 0)
    }

    /// Loads only the fixed identity probe from the actual App-hosted runner.
    /// This does not read song information or send any player command.
    func testFixedSystemProbeRunsInTheSandboxWithoutSongOrControlOutput() async throws {
        let data = try await SystemMusicSourceDetectionRunner().run()
        let result = try SystemMusicSourceDetector.parse(data)
        if case .source(let bundle) = result {
            XCTAssertTrue(SystemMusicSourceDetector.supportedBundleIdentifiers.contains(bundle))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["status", "bundleIdentifier"]))
    }
}

private actor DetectionRunnerFixture: MusicSourceDetectionRunning {
    private var count = 0
    private var cancelled = 0
    private let suspends: Bool
    init(suspends: Bool = false) { self.suspends = suspends }

    func run() async throws -> Data {
        count += 1
        if suspends {
            do { try await Task.sleep(for: .seconds(20)) }
            catch { cancelled += 1; throw error }
        }
        return Data(#"{"status":"source","bundleIdentifier":"com.spotify.client"}"#.utf8)
    }
    func calls() -> Int { count }
    func cancellations() -> Int { cancelled }
}

private actor DetectionCancellationGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
