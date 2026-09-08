import XCTest
@testable import DynamicIsland

final class MusicControlServiceTests: XCTestCase {
    func testParseNilReturnsEmptyInfo() async {
        await MainActor.run {
            let info = NowPlayingParser.parse(nil)
            XCTAssertEqual(info, .empty)
            XCTAssertFalse(info.isPlaying)
        }
    }

    func testParsePlayingTrackFields() async {
        await MainActor.run {
            let sep = NowPlayingParser.fieldSeparator
            let info = NowPlayingParser.parse(
                "playing\(sep)Song\(sep)Artist\(sep)Album\(sep)245.5\(sep)61.25\(sep)TRACK-ID"
            )
            XCTAssertTrue(info.isPlaying)
            XCTAssertEqual(info.title, "Song")
            XCTAssertEqual(info.artist, "Artist")
            XCTAssertEqual(info.album, "Album")
            XCTAssertEqual(info.duration, 245.5, accuracy: 0.001)
            XCTAssertEqual(info.position, 61.25, accuracy: 0.001)
            XCTAssertEqual(info.trackIdentifier, "TRACK-ID")
            XCTAssertEqual(info.progress, 0.249_490_835, accuracy: 0.000_001)
        }
    }

    func testParsePausedTrackIsNotPlaying() async {
        await MainActor.run {
            let sep = NowPlayingParser.fieldSeparator
            let info = NowPlayingParser.parse("paused\(sep)Song\(sep)Artist\(sep)Album")
            XCTAssertFalse(info.isPlaying)
            XCTAssertEqual(info.title, "Song")
        }
    }

    func testParseStoppedStateHasNoTrack() async {
        await MainActor.run {
            let sep = NowPlayingParser.fieldSeparator
            let info = NowPlayingParser.parse("stopped\(sep)\(sep)\(sep)")
            XCTAssertFalse(info.isPlaying)
            XCTAssertEqual(info.title, "")
            XCTAssertEqual(info.artist, "")
            XCTAssertEqual(info.album, "")
        }
    }

    func testParseMissingFieldsDefaultToEmpty() async {
        await MainActor.run {
            let sep = NowPlayingParser.fieldSeparator
            let info = NowPlayingParser.parse("playing\(sep)Song")
            XCTAssertTrue(info.isPlaying)
            XCTAssertEqual(info.title, "Song")
            XCTAssertEqual(info.artist, "")
            XCTAssertEqual(info.album, "")
        }
    }

    func testParseLocalizedSecondsAndClampPositionToDuration() async {
        await MainActor.run {
            let sep = NowPlayingParser.fieldSeparator
            let info = NowPlayingParser.parse(
                "paused\(sep)Song\(sep)Artist\(sep)Album\(sep)180,5\(sep)999\(sep)TRACK-ID"
            )

            XCTAssertEqual(info.duration, 180.5, accuracy: 0.001)
            XCTAssertEqual(info.position, 180.5, accuracy: 0.001)
            XCTAssertEqual(info.progress, 1, accuracy: 0.001)
        }
    }

    func testAdvancingPlaybackProgressOnlyMovesPlayingTrack() async {
        await MainActor.run {
            let playing = NowPlayingInfo(
                isPlaying: true,
                title: "Song",
                artist: "Artist",
                album: "Album",
                duration: 120,
                position: 20
            )
            let paused = NowPlayingInfo(
                isPlaying: false,
                title: "Song",
                artist: "Artist",
                album: "Album",
                duration: 120,
                position: 20
            )

            XCTAssertEqual(playing.advanced(by: 0.25).position, 20.25, accuracy: 0.001)
            XCTAssertEqual(paused.advanced(by: 0.25).position, 20, accuracy: 0.001)
            XCTAssertEqual(playing.advanced(by: 200).position, 120, accuracy: 0.001)
        }
    }

    func testAppleScriptPermissionDenialMapsToActionableError() {
        let error = AppleScriptErrorMapper.musicControlError(from: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1743),
            "NSAppleScriptErrorMessage": "Not authorized to send Apple events",
        ])

        XCTAssertEqual(error, .automationPermissionDenied)
        XCTAssertEqual(
            error.localizedDescription,
            "没有控制 Apple Music 的权限，请在系统设置的“隐私与安全性 > 自动化”中允许灵动岛控制音乐"
        )
    }

    func testAppleScriptFailurePreservesCodeAndReadableMessage() {
        let error = AppleScriptErrorMapper.musicControlError(from: [
            "NSAppleScriptErrorNumber": NSNumber(value: -1728),
            "NSAppleScriptErrorMessage": "The requested track was not found.",
        ])

        XCTAssertEqual(
            error,
            .executionFailed(code: -1728, message: "The requested track was not found.")
        )
        XCTAssertEqual(
            error.localizedDescription,
            "Apple Music 控制失败（错误 -1728）：The requested track was not found."
        )
    }

    func testAppleScriptFailureWithoutDetailsUsesStableFallbackMessage() {
        let error = AppleScriptErrorMapper.musicControlError(from: [:])

        XCTAssertEqual(error, .executionFailed(code: nil, message: "未知错误"))
        XCTAssertEqual(error.localizedDescription, "Apple Music 控制失败：未知错误")
    }
}
