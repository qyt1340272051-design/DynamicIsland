import AppKit
import Foundation

public enum MusicControlError: LocalizedError {
    case scriptCompilationFailed
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptCompilationFailed:
            return "无法创建 Apple Music 控制脚本"
        case .executionFailed(let details):
            return "Apple Music 控制失败：\(details)"
        }
    }
}

public enum NowPlayingParser {
    public nonisolated static let fieldSeparator = "\u{1F}"

    public nonisolated static func parse(_ raw: String?) -> NowPlayingInfo {
        let fields = raw?.components(separatedBy: fieldSeparator) ?? []
        let state = field(at: 0, in: fields).trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaying = state.lowercased() == "playing"
        return NowPlayingInfo(
            isPlaying: isPlaying,
            title: field(at: 1, in: fields),
            artist: field(at: 2, in: fields),
            album: field(at: 3, in: fields),
            duration: seconds(at: 4, in: fields),
            position: seconds(at: 5, in: fields),
            trackIdentifier: field(at: 6, in: fields)
        )
    }

    private nonisolated static func field(at index: Int, in fields: [String]) -> String {
        fields.indices.contains(index) ? fields[index] : ""
    }

    private nonisolated static func seconds(at index: Int, in fields: [String]) -> TimeInterval {
        let rawValue = field(at: index, in: fields)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(rawValue) ?? 0
    }
}

/// Script execution is synchronous, but callers run it from the dedicated
/// Apple Music actor so commands stay serialized and never block the UI actor.
enum AppleScriptRunner {
    nonisolated static func run(_ source: String) throws -> String? {
        try execute(source).stringValue
    }

    nonisolated static func runData(_ source: String) throws -> Data? {
        let data = try execute(source).data
        return data.isEmpty ? nil : data
    }

    private nonisolated static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MusicControlError.scriptCompilationFailed
        }

        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw MusicControlError.executionFailed(errorInfo.description)
        }

        return descriptor
    }
}

public actor AppleMusicControlService: MusicControlService {
    private var cachedArtworkIdentifier = ""
    private var cachedArtworkData: Data?
    private var lastArtworkAttempt = Date.distantPast
    private let artworkRetryInterval: TimeInterval = 10

    public init() {}

    public func togglePlayPause() async throws {
        _ = try AppleScriptRunner.run("tell application \"Music\" to playpause")
    }

    public func skipBackward() async throws {
        _ = try AppleScriptRunner.run("tell application \"Music\" to previous track")
    }

    public func skipForward() async throws {
        _ = try AppleScriptRunner.run("tell application \"Music\" to next track")
    }

    public func nowPlaying() async throws -> NowPlayingInfo {
        guard Self.isMusicRunning else {
            clearArtworkCache()
            return .empty
        }

        let raw = try AppleScriptRunner.run(Self.nowPlayingScript)
        var info = NowPlayingParser.parse(raw)
        guard !info.title.isEmpty else {
            clearArtworkCache()
            return info
        }

        let artworkIdentifier = info.trackIdentifier.isEmpty
            ? "\(info.title)\u{1F}\(info.artist)\u{1F}\(info.album)\u{1F}\(info.duration)"
            : info.trackIdentifier
        let shouldRefreshArtwork = artworkIdentifier != cachedArtworkIdentifier
            || (cachedArtworkData == nil && Date().timeIntervalSince(lastArtworkAttempt) >= artworkRetryInterval)

        if shouldRefreshArtwork {
            cachedArtworkIdentifier = artworkIdentifier
            lastArtworkAttempt = Date()
            cachedArtworkData = try? Self.readArtworkData()
        }

        info = info.replacing(artworkData: cachedArtworkData)
        return info
    }

    private static func readArtworkData() throws -> Data? {
        guard let data = try AppleScriptRunner.runData(Self.artworkScript),
              NSImage(data: data) != nil else {
            return nil
        }
        return data
    }

    private func clearArtworkCache() {
        cachedArtworkIdentifier = ""
        cachedArtworkData = nil
        lastArtworkAttempt = .distantPast
    }

    private nonisolated static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private static var nowPlayingScript: String {
        let sep = NowPlayingParser.fieldSeparator
        return [
            "tell application \"Music\"",
            "set s to player state as string",
            "if s is \"stopped\" then",
            "return \"stopped\(sep)\(sep)\(sep)\(sep)0\(sep)0\(sep)\"",
            "end if",
            "set trackDuration to duration of current track as string",
            "set trackPosition to player position as string",
            "try",
            "set trackID to persistent ID of current track as string",
            "on error",
            "set trackID to (name of current track) & \" | \" & (artist of current track) & \" | \" & trackDuration",
            "end try",
            "return s & \"\(sep)\" & (name of current track) & \"\(sep)\" & (artist of current track) & \"\(sep)\" & (album of current track) & \"\(sep)\" & trackDuration & \"\(sep)\" & trackPosition & \"\(sep)\" & trackID",
            "end tell",
        ].joined(separator: "\n")
    }

    private static var artworkScript: String {
        [
            "tell application \"Music\"",
            "if player state is stopped then return missing value",
            "if (count of artworks of current track) is 0 then return missing value",
            "try",
            "return data of artwork 1 of current track",
            "on error",
            "return missing value",
            "end try",
            "end tell",
        ].joined(separator: "\n")
    }
}
