import Foundation

/// A source identity only. Detection never includes another app's song data.
public nonisolated enum MusicSourceDetection: Equatable, Sendable {
    case none
    case source(bundleIdentifier: String)
    case unsupported
}

public protocol MusicSourceDetecting: Sendable {
    nonisolated func activeSource() async throws -> MusicSourceDetection
}

nonisolated protocol MusicSourceDetectionRunning: Sendable {
    func run() async throws -> Data
}

/// The Host reads only the system's active player identity. Actual metadata and
/// controls still go through the selected provider's independent permissions.
public nonisolated struct SystemMusicSourceDetector: MusicSourceDetecting {
    static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.Music", "com.netease.163music", "com.tencent.QQMusicMac", "com.spotify.client"
    ]
    static let maximumOutputBytes = 1_024
    private let runner: any MusicSourceDetectionRunning

    public init() { runner = SystemMusicSourceDetectionRunner() }

    init(runner: any MusicSourceDetectionRunning) { self.runner = runner }

    public func activeSource() async throws -> MusicSourceDetection {
        try Task.checkCancellation()
        let data = try await runner.run()
        try Task.checkCancellation()
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> MusicSourceDetection {
        guard data.count <= maximumOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { throw PluginMusicError.invalidResponse }
        let fields = Set(object.keys)
        switch status {
        case "none", "unsupported":
            guard fields == ["status"] else { throw PluginMusicError.invalidResponse }
            return status == "none" ? .none : .unsupported
        case "source":
            guard fields == ["status", "bundleIdentifier"],
                  let bundle = object["bundleIdentifier"] as? String,
                  supportedBundleIdentifiers.contains(bundle) else { throw PluginMusicError.invalidResponse }
            return .source(bundleIdentifier: bundle)
        case "error":
            guard fields == ["status", "error"], let code = object["error"] as? String,
                  ["unsupportedSystem", "queryFailed", "invalidArguments"].contains(code) else {
                throw PluginMusicError.invalidResponse
            }
            throw PluginMusicError.helperFailed
        default:
            throw PluginMusicError.invalidResponse
        }
    }
}

/// This runner has no caller-supplied script, target, or command. A fresh Host
/// admission reuses the bounded/cancellable system interpreter implementation;
/// no plugin session or media-permission lease is acquired for identity alone.
nonisolated struct SystemMusicSourceDetectionRunner: MusicSourceDetectionRunning {
    func run() async throws -> Data {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        return try await SystemMusicHelperRunner(timeout: 1, outputLimit: SystemMusicSourceDetector.maximumOutputBytes)
            .run(source: Self.source, arguments: [], admission: admission)
    }

    static let source = #"""
        ObjC.import('Foundation');
        ObjC.import('AppKit');
        function run(argv) {
            'use strict';
            var allowed = ['com.apple.Music', 'com.netease.163music',
                           'com.tencent.QQMusicMac', 'com.spotify.client'];
            function present(value) {
                if (value === null || value === undefined) return false;
                try { return !value.isNil(); } catch (_) { return true; }
            }
            function scalar(value) {
                if (!present(value)) return null;
                try { return ObjC.unwrap(value); } catch (_) { return null; }
            }
            function reply(status) { return JSON.stringify({status: status}); }
            function identity(Request) {
                var path = Request.localNowPlayingPlayerPath;
                if (!present(path) || !present(path.client)) return {status: 'none'};
                var client = path.client;
                var bundle = scalar(client.bundleIdentifier);
                var parent = scalar(client.parentApplicationBundleIdentifier);
                var matches = allowed.filter(function(target) { return target === bundle || target === parent; });
                // Do not export unsupported identities, including browser and
                // helper Bundle IDs, or choose between conflicting identities.
                if (matches.length !== 1) return {status: 'unsupported'};
                return {status: 'source', bundleIdentifier: matches[0]};
            }
            try {
                if (!argv || argv.length !== 0) return JSON.stringify({status: 'error', error: 'invalidArguments'});
                var framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
                if (!present(framework) || !framework.load) {
                    return JSON.stringify({status: 'error', error: 'unsupportedSystem'});
                }
                var Request = $.NSClassFromString('MRNowPlayingRequest');
                if (!present(Request) || !Request.respondsToSelector($.NSSelectorFromString('localNowPlayingPlayerPath'))) {
                    return JSON.stringify({status: 'error', error: 'unsupportedSystem'});
                }
                var found = identity(Request);
                if (found.status !== 'source') return JSON.stringify(found);
                if (Number($.NSRunningApplication.runningApplicationsWithBundleIdentifier(found.bundleIdentifier).count) === 0) {
                    return reply('none');
                }
                // A session may switch while checking its running app. Return
                // no source for that sample rather than an obsolete identity.
                var current = identity(Request);
                if (current.status !== 'source' || current.bundleIdentifier !== found.bundleIdentifier) return reply('none');
                return JSON.stringify(found);
            } catch (_) {
                return JSON.stringify({status: 'error', error: 'queryFailed'});
            }
        }
        """#
}
