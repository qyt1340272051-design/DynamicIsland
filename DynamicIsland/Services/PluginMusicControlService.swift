import Combine
import CryptoKit
import Darwin
import Foundation

public nonisolated struct MusicProviderChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
}

public nonisolated enum MusicSourceStatus: Equatable, Sendable {
    case detecting, idle, active(String), unavailable(String), unsupported, failed
}

public nonisolated enum PluginMusicError: Error, Equatable, LocalizedError, Sendable {
    case untrustedHelper, invalidResponse, helperFailed, timedOut, sourceChanged, inactiveProvider, busy

    public var errorDescription: String? {
        switch self {
        case .untrustedHelper: "此音乐辅助组件未经宿主验证，请安装受支持的官方插件。"
        case .invalidResponse: "音乐插件返回的数据无效。"
        case .helperFailed: "无法连接音乐播放器，请确认播放器已打开并播放过歌曲。"
        case .timedOut: "读取音乐播放器超时，请稍后重试。"
        case .sourceChanged: "音乐来源已切换，请重试。"
        case .inactiveProvider: "所选音乐插件已停止，请重新启用或选择其他播放器。"
        case .busy: "音乐播放器正在处理其他请求。"
        }
    }
}

/// Only Host code can construct the runner. JavaScript receives no process or
/// command execution API. The source must match the Host's exact helper pin.
protocol PluginMusicHelperRunning: Sendable {
    nonisolated func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data
}

nonisolated struct PluginMusicHelperAdmission: Sendable {
    let lifecycle: PluginResourceAdmission
    let read: PluginPermissionLease?
    let control: PluginPermissionLease?

    func perform(_ operation: () throws -> Void) throws {
        try lifecycle.perform {
            if let read { try read.perform { try withControl(operation) } }
            else { try withControl(operation) }
        }
    }

    private func withControl(_ operation: () throws -> Void) throws {
        if let control { try control.perform(operation) }
        else { try operation() }
    }
}

/// Active provider registrations carry the original Runtime generation and
/// immutable package bytes. Installation alone never starts a subprocess.
@MainActor
public final class OptionalMusicProviderRegistry: ObservableObject {
    public nonisolated static let appleMusicID = "apple-music"
    public nonisolated static let noActiveSourceID = "no-active-source"
    // The optional helper ships only in the .dip, never in the Host resources.
    // Updating its implementation requires a reviewed Host pin update.
    static let trustedHelpers: [String: Set<String>] = [
        "37c306a675aa34419a34bc03a412a934953f2b5243c96ee3f9855d5b537a9d32": ["com.netease.163music"],
        "422c5eb11cf94e523c7427b953e83d0e6f1b94850897ffbb529a9abd9d44b9ec": ["com.tencent.QQMusicMac"],
        "d2288f6e59608d8681c3d3b7a6de3f4725e8e3a87fc995c6c31de45c3022141b": ["com.spotify.client"]
    ]

    @Published public private(set) var providers: [MusicProviderChoice] = [
        .init(id: appleMusicID, displayName: "Apple Music")
    ]
    @Published public internal(set) var selectedProviderID = appleMusicID {
        didSet {
            if oldValue != selectedProviderID {
                artworkGeneration = UUID()
                generation = UUID()
                entries.values.forEach { $0.cancelRequests() }
            }
        }
    }
    @Published public private(set) var sourceStatus: MusicSourceStatus = .detecting
    let sourceDetector: (any MusicSourceDetecting)?
    @Published private(set) var generation = UUID()
    // Reading artwork and controlling playback are independent grants. A
    // control-only change invalidates pending transport work, not allowed art.
    @Published private(set) var artworkGeneration = UUID()
    private let runner: any PluginMusicHelperRunning
    private let trust: [String: Set<String>]
    private var isShutDown = false
    private var sourceResolutionSequence: UInt64 = 0
    private var completedSourceResolutionSequence: UInt64 = 0
    var allowsDetection: Bool { !isShutDown }
    private var entries: [String: Entry] = [:]

    private final class Entry {
        let package: ValidatedPluginPackage
        let context: PluginExecutionContext
        let permissions: PermissionManager
        let source: String
        let generation = UUID()
        var requests: [UUID: Task<Data, Error>] = [:]
        var permissionObserverID: UUID?
        var mediaStates: [PluginPermission: PluginPermissionState]

        init(package: ValidatedPluginPackage, context: PluginExecutionContext,
             permissions: PermissionManager, source: String) {
            self.package = package
            self.context = context
            self.permissions = permissions
            self.source = source
            mediaStates = (try? permissions.snapshot(package: package).states) ?? [:]
        }

        func cancelRequests() { requests.values.forEach { $0.cancel() }; requests.removeAll() }
    }

    public init(defaults: UserDefaults? = nil) {
        runner = SystemMusicHelperRunner()
        trust = Self.trustedHelpers
        sourceDetector = SystemMusicSourceDetector()
        // Old manual choices must never select or start a player in auto mode.
        selectedProviderID = Self.noActiveSourceID
    }

    // A nil detector retains direct routing only for isolated transport tests.
    init(runner: any PluginMusicHelperRunning, trustedHelpers: [String: Set<String>],
         sourceDetector: (any MusicSourceDetecting)? = nil) {
        self.runner = runner
        trust = trustedHelpers
        self.sourceDetector = sourceDetector
        if sourceDetector != nil { selectedProviderID = Self.noActiveSourceID }
    }

    func updateSourceStatus(_ status: MusicSourceStatus) { sourceStatus = status }

    func beginSourceResolution() -> UInt64 {
        sourceResolutionSequence &+= 1
        return sourceResolutionSequence
    }

    func completeSourceResolution(_ sequence: UInt64) throws {
        guard sequence > completedSourceResolutionSequence else { throw PluginMusicError.sourceChanged }
        completedSourceResolutionSequence = sequence
    }

    func applyDetection(_ detection: MusicSourceDetection) -> String? {
        guard !isShutDown else { return nil }
        let selected: String?
        let status: MusicSourceStatus
        switch detection {
        case .none:
            selected = nil; status = .idle
        case .unsupported:
            selected = nil; status = .unsupported
        case .source(let bundle):
            let names = ["com.apple.Music": "Apple Music", "com.netease.163music": "网易云音乐",
                         "com.tencent.QQMusicMac": "QQ 音乐", "com.spotify.client": "Spotify"]
            guard let name = names[bundle] else {
                selectedProviderID = Self.noActiveSourceID
                sourceStatus = .unsupported
                return nil
            }
            if bundle == "com.apple.Music" { selected = Self.appleMusicID }
            else {
                selected = entries.keys.sorted().first { id in
                    guard let entry = entries[id],
                          entry.package.manifest.mediaProvider?.targetBundleIdentifier == bundle,
                          (try? entry.permissions.snapshot(package: entry.package).states[.readMedia]) == .granted else {
                        return false
                    }
                    do { try entry.context.perform {}; return true } catch { return false }
                }
            }
            status = selected == nil ? .unavailable(name) : .active(name)
        }
        selectedProviderID = selected ?? Self.noActiveSourceID
        sourceStatus = status
        return selected
    }

    func detectionFailed() {
        selectedProviderID = Self.noActiveSourceID
        sourceStatus = .failed
    }

    public func activate(package: ValidatedPluginPackage, context: PluginExecutionContext,
                         permissions: PermissionManager) throws {
        guard let descriptor = package.manifest.mediaProvider else { return }
        try context.perform {}
        guard context.id == package.manifest.id,
              package.manifest.capabilities.contains(.musicProvider),
              package.manifest.permissions.contains(.readMedia),
              package.manifest.permissions.contains(.controlMedia),
              let bytes = package.mediaHelperSource, bytes.count <= 128 * 1_024,
              let source = String(data: bytes, encoding: .utf8), !source.contains("\0"),
              Self.sha256(bytes) == descriptor.helperSHA256,
              trust[descriptor.helperSHA256]?.contains(descriptor.targetBundleIdentifier) == true else {
            throw PluginMusicError.untrustedHelper
        }
        removeEntry(pluginID: context.id)
        let entry = Entry(package: package, context: context, permissions: permissions, source: source)
        entries[context.id] = entry
        entry.permissionObserverID = permissions.observeChanges { [weak self] in
            guard let self, let current = self.entries[context.id] else { return }
            let states = (try? permissions.snapshot(package: current.package).states) ?? [:]
            let readChanged = current.mediaStates[.readMedia] != states[.readMedia]
            let changed = readChanged
                || current.mediaStates[.controlMedia] != states[.controlMedia]
            current.mediaStates = states
            guard changed else { return }
            current.cancelRequests()
            guard self.selectedProviderID == context.id else { return }
            if self.sourceDetector != nil, states[.readMedia] != .granted {
                self.selectedProviderID = Self.noActiveSourceID
                self.sourceStatus = .unavailable(current.package.manifest.mediaProvider?.displayName ?? current.package.manifest.name)
                return
            }
            if readChanged { self.artworkGeneration = UUID() }
            self.generation = UUID()
        }
        if selectedProviderID == context.id { artworkGeneration = UUID(); generation = UUID() }
        publishChoices()
    }

    public func deactivate(pluginID: String) {
        guard entries[pluginID] != nil else { return }
        let name = entries[pluginID]?.package.manifest.mediaProvider?.displayName ?? "播放器"
        removeEntry(pluginID: pluginID)
        if selectedProviderID == pluginID {
            if sourceDetector != nil {
                selectedProviderID = Self.noActiveSourceID; sourceStatus = .unavailable(name)
            } else { artworkGeneration = UUID(); generation = UUID() }
        }
        publishChoices()
    }

    public func shutdown() {
        isShutDown = true
        Array(entries.keys).forEach { removeEntry(pluginID: $0) }
        artworkGeneration = UUID()
        generation = UUID()
        if sourceDetector != nil { selectedProviderID = Self.noActiveSourceID; sourceStatus = .idle }
        publishChoices()
    }

    private func removeEntry(pluginID: String) {
        guard let entry = entries.removeValue(forKey: pluginID) else { return }
        entry.cancelRequests()
        if let observer = entry.permissionObserverID { entry.permissions.removeChangeObserver(observer) }
    }

    private func publishChoices() {
        let choices = [MusicProviderChoice(id: Self.appleMusicID, displayName: "Apple Music")] + entries.values.compactMap {
            guard let descriptor = $0.package.manifest.mediaProvider else { return nil }
            return MusicProviderChoice(id: $0.package.manifest.id, displayName: descriptor.displayName)
        }.sorted { $0.id < $1.id }
        if providers != choices { providers = choices }
    }

    static nonisolated func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func request(providerID: String, operation: String, position: TimeInterval? = nil,
                 trackIdentifier: String? = nil) async throws -> Data {
        guard let entry = entries[providerID], let descriptor = entry.package.manifest.mediaProvider else {
            throw PluginMusicError.inactiveProvider
        }
        try Task.checkCancellation()
        try entry.context.perform {}
        let readLease = try entry.permissions.require(permission: .readMedia, package: entry.package)
        let controlLease = operation == "nowPlaying" ? nil
            : try entry.permissions.require(permission: .controlMedia, package: entry.package)
        try readLease.perform {}
        try controlLease?.perform {}
        guard entry.requests.count < 4 else { throw PluginMusicError.busy }
        let requestID = UUID()
        var arguments = [descriptor.targetBundleIdentifier, operation]
        if let position, let trackIdentifier {
            arguments += [String(position), trackIdentifier]
        }
        let runner = self.runner
        let admission = PluginMusicHelperAdmission(lifecycle: entry.context.resourceAdmission,
                                                   read: readLease, control: controlLease)
        let task = Task { try await runner.run(source: entry.source, arguments: arguments, admission: admission) }
        entry.requests[requestID] = task
        let lifecycleCancellation: UUID
        do { lifecycleCancellation = try entry.context.resourceAdmission.registerCancellation { task.cancel() } }
        catch {
            task.cancel()
            entry.requests.removeValue(forKey: requestID)
            throw error
        }
        let readObservation = readLease.observeRevocation { task.cancel() }
        let controlObservation = controlLease?.observeRevocation { task.cancel() }
        defer {
            readObservation.cancel()
            controlObservation?.cancel()
            entry.context.resourceAdmission.unregister(lifecycleCancellation)
            entry.requests.removeValue(forKey: requestID)
        }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard entries[providerID] === entry else { throw PluginMusicError.inactiveProvider }
        try entry.context.perform {}
        try readLease.perform {}
        try controlLease?.perform {}
        guard data.count <= SystemMusicHelperRunner.maximumOutputBytes else { throw PluginMusicError.invalidResponse }
        return data
    }
}

/// Follows the system media session. A transport action stays bound to the
/// player whose metadata was delivered, even if another app becomes active.
@MainActor
public final class MusicSourceRouter: MusicControlService {
    private let registry: OptionalMusicProviderRegistry
    private let fallback: any MusicControlService
    private var sourceObservation: AnyCancellable?
    private var artworkCache: [ArtworkKey: Data] = [:]
    private var artworkRecency: [ArtworkKey] = []
    private var cachedArtworkBytes = 0
    private var readJob: (id: UUID, generation: UUID, task: Task<NowPlayingInfo, Error>)?
    private var readWaiters: [UUID: Set<UUID>] = [:]
    private var displayedTrack: DisplayedTrack?
    static let maximumCachedArtworkCount = 8
    static let maximumCachedArtworkBytes = 8 * 1_024 * 1_024

    private struct DisplayedTrack: Equatable {
        let providerID: String
        let originalIdentifier: String
        let publicIdentifier: String
        let generation: UUID
    }

    private nonisolated struct ArtworkKey: Hashable {
        let providerID: String
        let title: String
        let artist: String
        let album: String
        let durationMilliseconds: Double
    }

    var artworkCacheStatistics: (count: Int, bytes: Int) { (artworkCache.count, cachedArtworkBytes) }

    public init(registry: OptionalMusicProviderRegistry,
                fallback: any MusicControlService = AppleMusicControlService()) {
        self.registry = registry
        self.fallback = fallback
        sourceObservation = registry.$artworkGeneration.sink { [weak self] _ in self?.clearArtworkCache() }
    }

    public func nowPlaying() async throws -> NowPlayingInfo {
        guard registry.sourceDetector != nil else { return try await readSelectedSource() }
        try Task.checkCancellation()
        let job: (id: UUID, generation: UUID, task: Task<NowPlayingInfo, Error>)
        if let current = readJob, current.generation == registry.generation {
            job = current
        } else {
            readJob?.task.cancel()
            let id = UUID()
            let task = Task { try await self.readAutomaticSource(jobID: id) }
            job = (id, registry.generation, task)
            readJob = job
        }
        let waiter = UUID()
        readWaiters[job.id, default: []].insert(waiter)
        return try await withTaskCancellationHandler {
            defer { releaseReadWaiter(jobID: job.id, waiter: waiter) }
            let value = try await job.task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseReadWaiter(jobID: job.id, waiter: waiter) }
        }
    }

    private func releaseReadWaiter(jobID: UUID, waiter: UUID) {
        readWaiters[jobID]?.remove(waiter)
        guard readWaiters[jobID]?.isEmpty == true else { return }
        readWaiters.removeValue(forKey: jobID)
        if readJob?.id == jobID {
            readJob?.task.cancel()
            readJob = nil
        }
    }

    private func resolveAutomaticSource() async throws -> String? {
        guard registry.allowsDetection, let detector = registry.sourceDetector else { return nil }
        let sequence = registry.beginSourceResolution()
        let detection: MusicSourceDetection
        do { detection = try await detector.activeSource() }
        catch {
            try Task.checkCancellation()
            try registry.completeSourceResolution(sequence)
            registry.detectionFailed()
            displayedTrack = nil
            throw error
        }
        try Task.checkCancellation()
        try registry.completeSourceResolution(sequence)
        return registry.applyDetection(detection)
    }

    private func readAutomaticSource(jobID: UUID) async throws -> NowPlayingInfo {
        let selected = try await resolveAutomaticSource()
        // The source notification can schedule another ViewModel read. It
        // joins this read after selection, instead of launching another helper.
        if readJob?.id == jobID { readJob?.generation = registry.generation }
        guard let selected else { displayedTrack = nil; return .empty }
        let info = try await readSelectedSource()
        try Task.checkCancellation()
        guard selected == registry.selectedProviderID else { throw PluginMusicError.sourceChanged }
        guard !info.title.isEmpty else { displayedTrack = nil; return info }
        let identity = OptionalMusicProviderRegistry.sha256(Data((selected + "\0" + info.trackIdentifier).utf8))
        let handle = "auto:" + identity
        displayedTrack = DisplayedTrack(providerID: selected, originalIdentifier: info.trackIdentifier,
                                        publicIdentifier: handle, generation: registry.generation)
        return NowPlayingInfo(isPlaying: info.isPlaying, title: info.title, artist: info.artist,
                              album: info.album, duration: info.duration, position: info.position,
                              trackIdentifier: info.trackIdentifier.isEmpty ? "" : handle, artworkData: info.artworkData)
    }

    private func readSelectedSource() async throws -> NowPlayingInfo {
        let generation = registry.generation
        let selected = registry.selectedProviderID
        let result: NowPlayingInfo
        if selected == OptionalMusicProviderRegistry.appleMusicID {
            result = try await fallback.nowPlaying()
        } else {
            result = try Self.parseNowPlaying(await registry.request(providerID: selected, operation: "nowPlaying"))
        }
        guard generation == registry.generation else { throw PluginMusicError.sourceChanged }
        return selected == OptionalMusicProviderRegistry.appleMusicID
            ? result : restoringArtwork(result, providerID: selected)
    }

    /// NetEase's system ContentItemIdentifier may change on pause/resume and
    /// its artwork callback can temporarily return nil. Keep a small in-memory
    /// cache by stable song metadata, while leaving transport identity intact.
    private func restoringArtwork(_ info: NowPlayingInfo, providerID: String) -> NowPlayingInfo {
        let durationMilliseconds = (info.duration * 1_000).rounded()
        guard !info.title.isEmpty, durationMilliseconds.isFinite else { return info }
        let key = ArtworkKey(providerID: providerID, title: info.title, artist: info.artist,
                             album: info.album, durationMilliseconds: durationMilliseconds)
        if let artwork = info.artworkData {
            if let old = artworkCache.removeValue(forKey: key) { cachedArtworkBytes -= old.count }
            artworkRecency.removeAll { $0 == key }
            // The decoder validates the per-image budget first; retain an
            // independent aggregate limit in case that decoder limit changes.
            guard artwork.count <= Self.maximumCachedArtworkBytes else { return info }
            artworkCache[key] = artwork
            cachedArtworkBytes += artwork.count
            artworkRecency.append(key)
            while artworkCache.count > Self.maximumCachedArtworkCount || cachedArtworkBytes > Self.maximumCachedArtworkBytes {
                let evicted = artworkRecency.removeFirst()
                if let bytes = artworkCache.removeValue(forKey: evicted) { cachedArtworkBytes -= bytes.count }
            }
            return info
        }
        guard let cached = artworkCache[key] else { return info }
        artworkRecency.removeAll { $0 == key }
        artworkRecency.append(key)
        return info.replacing(artworkData: cached)
    }

    private func clearArtworkCache() {
        artworkCache.removeAll()
        artworkRecency.removeAll()
        cachedArtworkBytes = 0
    }

    public func togglePlayPause() async throws { try await control("togglePlayPause") }
    public func skipBackward() async throws { try await control("skipBackward") }
    public func skipForward() async throws { try await control("skipForward") }

    public func seek(to position: TimeInterval, trackIdentifier: String) async throws -> Bool {
        guard position.isFinite, position >= 0, !trackIdentifier.isEmpty,
              trackIdentifier.utf8.count <= 4_096, !trackIdentifier.contains("\0") else { return false }
        var originalIdentifier = trackIdentifier
        if registry.sourceDetector != nil {
            guard let displayed = displayedTrack, displayed.publicIdentifier == trackIdentifier,
                  !displayed.originalIdentifier.isEmpty else { return false }
            do { try await validateAutomaticControl(displayed) }
            catch PluginMusicError.sourceChanged { return false }
            guard displayedTrack == displayed else { return false }
            originalIdentifier = displayed.originalIdentifier
        }
        let generation = registry.generation
        let selected = registry.selectedProviderID
        let result: Bool
        if selected == OptionalMusicProviderRegistry.appleMusicID {
            result = try await fallback.seek(to: position, trackIdentifier: originalIdentifier)
        } else {
            result = try Self.parseControl(await registry.request(providerID: selected, operation: "seek",
                                                                  position: position, trackIdentifier: originalIdentifier))
        }
        guard generation == registry.generation else { throw PluginMusicError.sourceChanged }
        return result
    }

    private func control(_ operation: String) async throws {
        if registry.sourceDetector != nil {
            guard let displayed = displayedTrack else { throw PluginMusicError.inactiveProvider }
            try await validateAutomaticControl(displayed)
        }
        let generation = registry.generation
        let selected = registry.selectedProviderID
        if selected == OptionalMusicProviderRegistry.appleMusicID {
            switch operation {
            case "togglePlayPause": try await fallback.togglePlayPause()
            case "skipBackward": try await fallback.skipBackward()
            default: try await fallback.skipForward()
            }
        } else {
            guard try Self.parseControl(await registry.request(providerID: selected, operation: operation)) else {
                throw PluginMusicError.helperFailed
            }
        }
        guard generation == registry.generation else { throw PluginMusicError.sourceChanged }
    }

    private func validateAutomaticControl(_ displayed: DisplayedTrack) async throws {
        guard displayed.generation == registry.generation else {
            displayedTrack = nil
            throw PluginMusicError.sourceChanged
        }
        let generation = registry.generation
        let selected = try await resolveAutomaticSource()
        guard selected == displayed.providerID, generation == registry.generation else {
            displayedTrack = nil
            readJob?.task.cancel()
            readJob = nil
            throw PluginMusicError.sourceChanged
        }
    }

    private nonisolated struct Payload: Decodable {
        let isPlaying: Bool?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let position: Double?
        let trackIdentifier: String?
        let artworkBase64: String?
        let ok: Bool?
        let error: String?
    }

    static nonisolated func parseNowPlaying(_ data: Data) throws -> NowPlayingInfo {
        let payload = try decode(data)
        guard let playing = payload.isPlaying, let title = payload.title,
              let artist = payload.artist, let album = payload.album,
              let duration = payload.duration, let position = payload.position,
              let identifier = payload.trackIdentifier,
              duration.isFinite, position.isFinite, duration >= 0, position >= 0,
              [title, artist, album, identifier].allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw PluginMusicError.invalidResponse
        }
        let artwork: Data?
        if let encoded = payload.artworkBase64 {
            guard encoded.utf8.count <= 5_592_408, let bytes = Data(base64Encoded: encoded),
                  let validated = AppleMusicControlService.validatedArtworkData(bytes) else {
                throw PluginMusicError.invalidResponse
            }
            artwork = validated
        } else { artwork = nil }
        return NowPlayingInfo(isPlaying: playing, title: title, artist: artist, album: album,
                              duration: duration, position: position, trackIdentifier: identifier, artworkData: artwork)
    }

    static nonisolated func parseControl(_ data: Data) throws -> Bool {
        guard let ok = try decode(data).ok else { throw PluginMusicError.invalidResponse }
        return ok
    }

    private static nonisolated func decode(_ data: Data) throws -> Payload {
        guard data.count <= SystemMusicHelperRunner.maximumOutputBytes else { throw PluginMusicError.invalidResponse }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw PluginMusicError.invalidResponse }
        if payload.error != nil { throw PluginMusicError.helperFailed }
        return payload
    }
}

/// One process per bounded request; no listener exists when an optional source
/// is unused. stdout and stderr drain on independent queues to avoid deadlock.
nonisolated struct SystemMusicHelperRunner: PluginMusicHelperRunning {
    static let maximumOutputBytes = 6 * 1_024 * 1_024
    private let timeoutOverride: TimeInterval?
    let outputLimit: Int

    init(timeout: TimeInterval? = nil, outputLimit: Int = Self.maximumOutputBytes) {
        timeoutOverride = timeout
        self.outputLimit = outputLimit
    }

    func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data {
        // Metadata is a replaceable snapshot: bound a hung read so the next
        // poll can recover promptly. Transport/seek may await more than one
        // native completion and retain their existing six-second budget.
        let isMetadataRead = arguments.count > 1 && arguments[1] == "nowPlaying"
        let timeout = timeoutOverride ?? (isMetadataRead ? 2 : 6)
        let request = MusicHelperProcess(source: source, arguments: arguments, admission: admission,
                                         timeout: timeout, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
    }
}

private nonisolated final class MusicHelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var cancelled = false
    private var outputBytes = Data()
    private var outputDone = false
    private var errorDone = false
    private var exitStatus: Int32?
    private let admission: PluginMusicHelperAdmission
    private let timeout: TimeInterval
    private let outputLimit: Int

    init(source: String, arguments: [String], admission: PluginMusicHelperAdmission,
         timeout: TimeInterval, outputLimit: Int) {
        self.admission = admission
        self.timeout = timeout
        self.outputLimit = outputLimit
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source, "--"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // Do not inherit user-provided interpreter environment variables.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            do {
                process.terminationHandler = { [weak self] process in self?.didExit(process.terminationStatus) }
                try admission.perform { try process.run() }
                lock.unlock()
                DispatchQueue.global(qos: .utility).async { [self] in drain(output.fileHandleForReading, isOutput: true) }
                DispatchQueue.global(qos: .utility).async { [self] in drain(errors.fileHandleForReading, isOutput: false) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(PluginMusicError.timedOut), terminate: true)
                }
            } catch {
                lock.unlock()
                let safeError: Error
                if let permission = error as? PluginPermissionError { safeError = permission }
                else if let resource = error as? PluginResourceError { safeError = resource }
                else { safeError = PluginMusicError.helperFailed }
                finish(.failure(safeError), terminate: false)
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()), terminate: true)
    }

    private func drain(_ handle: FileHandle, isOutput: Bool) {
        var byteCount = 0
        do {
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                byteCount += chunk.count
                guard byteCount <= (isOutput ? outputLimit : 65_536) else {
                    finish(.failure(PluginMusicError.invalidResponse), terminate: true)
                    return
                }
                if isOutput {
                    lock.lock()
                    if !finished { outputBytes.append(chunk) }
                    lock.unlock()
                }
            }
            lock.lock()
            if isOutput { outputDone = true } else { errorDone = true }
            lock.unlock()
            completeIfReady()
        } catch { finish(.failure(PluginMusicError.helperFailed), terminate: true) }
    }

    private func didExit(_ status: Int32) {
        lock.lock(); exitStatus = status; lock.unlock()
        completeIfReady()
    }

    private func completeIfReady() {
        lock.lock()
        guard !finished, outputDone, errorDone, let status = exitStatus else { lock.unlock(); return }
        let bytes = outputBytes
        lock.unlock()
        finish(status == 0 ? .success(bytes) : .failure(PluginMusicError.helperFailed), terminate: false)
    }

    private func finish(_ result: Result<Data, Error>, terminate: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        outputBytes.removeAll()
        let pid = process.isRunning ? process.processIdentifier : nil
        lock.unlock()
        if terminate, let pid {
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if self?.process.isRunning == true { kill(pid, SIGKILL) }
            }
        }
        continuation?.resume(with: result)
    }
}
