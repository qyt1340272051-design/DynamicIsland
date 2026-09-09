import Foundation

public struct NowPlayingInfo: Equatable, Sendable {
    public let isPlaying: Bool
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let position: TimeInterval
    public let trackIdentifier: String
    public let artworkData: Data?

    public nonisolated init(
        isPlaying: Bool,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval = 0,
        position: TimeInterval = 0,
        trackIdentifier: String = "",
        artworkData: Data? = nil
    ) {
        let normalizedDuration = Self.normalizedSeconds(duration)
        let normalizedPosition = Self.normalizedSeconds(position)

        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = normalizedDuration
        self.position = normalizedDuration > 0
            ? min(normalizedPosition, normalizedDuration)
            : normalizedPosition
        self.trackIdentifier = trackIdentifier
        self.artworkData = artworkData
    }

    public nonisolated static let empty = NowPlayingInfo(isPlaying: false, title: "", artist: "", album: "")

    public nonisolated var progress: Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(position / duration, 0), 1)
    }

    public nonisolated func advanced(by interval: TimeInterval) -> NowPlayingInfo {
        guard isPlaying, duration > 0, interval > 0 else {
            return self
        }
        return replacing(position: position + interval)
    }

    public nonisolated func replacing(position: TimeInterval) -> NowPlayingInfo {
        NowPlayingInfo(
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            trackIdentifier: trackIdentifier,
            artworkData: artworkData
        )
    }

    public nonisolated func replacing(artworkData: Data?) -> NowPlayingInfo {
        NowPlayingInfo(
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            trackIdentifier: trackIdentifier,
            artworkData: artworkData
        )
    }

    private nonisolated static func normalizedSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else {
            return 0
        }
        return max(value, 0)
    }
}

public protocol MusicControlService {
    func togglePlayPause() async throws
    func skipBackward() async throws
    func skipForward() async throws
    func nowPlaying() async throws -> NowPlayingInfo
}

public struct PlaceholderMusicControlService: MusicControlService {
    public init() {}

    public func togglePlayPause() async throws {}
    public func skipBackward() async throws {}
    public func skipForward() async throws {}
    public func nowPlaying() async throws -> NowPlayingInfo { .empty }
}
