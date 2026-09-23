import AppKit
import Foundation
import ImageIO

public enum MusicControlError: LocalizedError, Equatable, Sendable {
    case automationPermissionDenied
    case scriptCompilationFailed
    case executionFailed(code: Int?, message: String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .automationPermissionDenied:
            return "没有控制 Apple Music 的权限，请在系统设置的“隐私与安全性 > 自动化”中允许 Dynamic Island 控制音乐"
        case .scriptCompilationFailed:
            return "无法创建 Apple Music 控制脚本"
        case .executionFailed(let code, let message):
            if let code {
                return "Apple Music 控制失败（错误 \(code)）：\(message)"
            }
            return "Apple Music 控制失败：\(message)"
        }
    }
}

enum AppleScriptErrorMapper {
    nonisolated static let automationPermissionDeniedCode = -1743

    nonisolated static func musicControlError(from errorInfo: NSDictionary) -> MusicControlError {
        let code = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        if code == automationPermissionDeniedCode {
            return .automationPermissionDenied
        }

        let rawMessage = errorInfo["NSAppleScriptErrorMessage"] as? String
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .executionFailed(
            code: code,
            message: message.flatMap { $0.isEmpty ? nil : $0 } ?? "未知错误"
        )
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
            throw AppleScriptErrorMapper.musicControlError(from: errorInfo)
        }

        return descriptor
    }
}

public actor AppleMusicControlService: MusicControlService {
    nonisolated static let maximumArtworkByteCount = 4 * 1_024 * 1_024
    nonisolated static let maximumArtworkPixelDimension = 2_048

    private var cachedArtworkIdentifier = ""
    private var cachedArtworkData: Data?
    private var lastArtworkAttempt = Date.distantPast
    private var consecutiveArtworkMisses = 0

    public init() {}

    public func togglePlayPause() async throws {
        _ = try AppleScriptRunner.run("tell application \"Music\" to playpause")
    }

    public func skipBackward() async throws {
        _ = try AppleScriptRunner.run(Self.skipBackwardScript)
    }

    public func skipForward() async throws {
        _ = try AppleScriptRunner.run("tell application \"Music\" to next track")
    }

    public func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool {
        guard !Task.isCancelled, Self.isMusicRunning,
              let script = Self.seekScript(position: position, trackIdentifier: trackIdentifier) else {
            return false
        }
        return try AppleScriptRunner.run(script) == "true"
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
        let isNewTrack = artworkIdentifier != cachedArtworkIdentifier
        let shouldRefreshArtwork = isNewTrack
            || (cachedArtworkData == nil && Date().timeIntervalSince(lastArtworkAttempt) >= Self.artworkRetryInterval(afterMisses: consecutiveArtworkMisses))

        if shouldRefreshArtwork {
            if isNewTrack {
                consecutiveArtworkMisses = 0
                cachedArtworkData = nil
            }
            cachedArtworkIdentifier = artworkIdentifier
            lastArtworkAttempt = Date()
            cachedArtworkData = try? Self.readArtworkData()
            consecutiveArtworkMisses = cachedArtworkData == nil ? consecutiveArtworkMisses + 1 : 0
        }

        info = info.replacing(artworkData: cachedArtworkData)
        return info
    }

    private nonisolated static func readArtworkData() throws -> Data? {
        let data = try AppleScriptRunner.runData(Self.artworkScript)
        return validatedArtworkData(data)
    }

    /// Validates artwork before it can enter the service cache or a
    /// `NowPlayingInfo` value. The byte limit is checked before ImageIO parses
    /// or decodes the payload so oversized data does not consume decode work.
    nonisolated static func validatedArtworkData(_ data: Data?) -> Data? {
        guard let data,
              artworkFitsResourceLimits(
                  byteCount: data.count,
                  pixelWidth: 1,
                  pixelHeight: 1
              ),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              artworkFitsResourceLimits(
                  byteCount: data.count,
                  pixelWidth: pixelWidth,
                  pixelHeight: pixelHeight
              ),
              let decodedImage = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              artworkFitsResourceLimits(
                  byteCount: data.count,
                  pixelWidth: decodedImage.width,
                  pixelHeight: decodedImage.height
              ) else {
            return nil
        }
        return data
    }

    nonisolated static func artworkFitsResourceLimits(
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        byteCount > 0
            && byteCount <= maximumArtworkByteCount
            && pixelWidth > 0
            && pixelWidth <= maximumArtworkPixelDimension
            && pixelHeight > 0
            && pixelHeight <= maximumArtworkPixelDimension
    }

    private func clearArtworkCache() {
        cachedArtworkIdentifier = ""
        cachedArtworkData = nil
        lastArtworkAttempt = .distantPast
        consecutiveArtworkMisses = 0
    }

    nonisolated static func artworkRetryInterval(afterMisses misses: Int) -> TimeInterval {
        misses < 3 ? 1 : 10
    }

    private nonisolated static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private nonisolated static var nowPlayingScript: String {
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

    nonisolated static func seekScript(position: TimeInterval, trackIdentifier: String) -> String? {
        guard position.isFinite, position >= 0, !trackIdentifier.isEmpty else {
            return nil
        }

        let seconds = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), position)
        let identifier = trackIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            "tell application \"Music\"",
            "if player state is stopped then return \"false\"",
            "set trackDuration to duration of current track as string",
            "try",
            "set trackID to persistent ID of current track as string",
            "on error",
            "set trackID to (name of current track) & \" | \" & (artist of current track) & \" | \" & trackDuration",
            "end try",
            "if trackID is not \"\(identifier)\" then return \"false\"",
            "set player position to \(seconds)",
            "return \"true\"",
            "end tell",
        ].joined(separator: "\n")
    }

    nonisolated static var skipBackwardScript: String {
        [
            "tell application \"Music\"",
            // Music can treat a previous-track request during playback as a restart.
            // Start at zero so a single request selects the preceding track.
            "try",
            "if player state is not stopped then set player position to 0",
            "end try",
            "previous track",
            "end tell",
        ].joined(separator: "\n")
    }

    private nonisolated static var artworkScript: String {
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
