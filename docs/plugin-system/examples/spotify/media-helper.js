// Copyright (c) 2026 qyt1340272051-design. MIT license; see LICENSE.
// Spotify optional-provider adapter; shares the Host media protocol. This is JXA, not a plugin VM entry.
// Host supplies verified immutable source to /usr/bin/osascript -l JavaScript -e.
ObjC.import('Foundation');
ObjC.import('AppKit');

function run(argv) {
    'use strict';
    var target = 'com.spotify.client';
    var allowed = ['nowPlaying', 'togglePlayPause', 'skipBackward', 'skipForward', 'seek'];
    var retained = [];
    var failure = null;
    var queue = null;

    function reject(code) { throw new Error(code); }
    function present(value) {
        if (value === null || value === undefined) return false;
        try { return !value.isNil(); } catch (_) { return true; }
    }
    function scalar(value) {
        if (!present(value)) return null;
        try { return ObjC.unwrap(value); } catch (_) { return null; }
    }
    function field(info, suffix) {
        return present(info) ? scalar(info.objectForKey('kMRMediaRemoteNowPlayingInfo' + suffix)) : null;
    }
    function text(value) { return typeof value === 'string' ? value.slice(0, 2048) : ''; }
    function number(value) {
        return typeof value === 'number' && isFinite(value) && value >= 0 ? value : 0;
    }
    function empty() {
        return {isPlaying: false, title: '', artist: '', album: '', duration: 0, position: 0, trackIdentifier: ''};
    }
    function pump(completed) {
        var until = Date.now() + 1250;
        while (!completed() && Date.now() < until) {
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.01));
        }
        return completed();
    }
    // Foundation supplies the native block representation for object replies.
    // Keep all holders alive until callbacks finish or the process exits.
    function replyBlock(callback) {
        var bridge = ObjC.block(['void', ['id', 'id']], callback);
        var predicate = $.NSPredicate.predicateWithBlock(bridge);
        var native = predicate.valueForKey('block');
        retained.push(bridge, predicate, native);
        return native;
    }
    function running() {
        return Number($.NSRunningApplication.runningApplicationsWithBundleIdentifier(target).count) > 0;
    }
    function activeTarget(Request) {
        var path = Request.localNowPlayingPlayerPath;
        if (!present(path) || !present(path.client)) return false;
        var client = path.client;
        return scalar(client.bundleIdentifier) === target || scalar(client.parentApplicationBundleIdentifier) === target;
    }
    function artworkBase64(artwork) {
        if (!present(artwork)) return null;
        try {
            var bytes = artwork.respondsToSelector($.NSSelectorFromString('imageData')) ? artwork.imageData : artwork;
            if (!present(bytes) || Number(bytes.length) > 2 * 1024 * 1024) return null;
            return scalar(bytes.base64EncodedStringWithOptions(0));
        } catch (_) { return null; }
    }
    function snapshot(Request, includeArtwork) {
        var path = $.NSClassFromString('MRPlayerPath').alloc.initWithOriginBundleIdentifierPlayer(
            $.NSClassFromString('MROrigin').localOrigin, target, $.NSClassFromString('MRPlayer').defaultPlayer);
        var request = Request.alloc.initWithPlayerPath(path);
        retained.push(path, request);
        var state = {infoDone: false, playingDone: false, artDone: !includeArtwork,
                     info: null, playing: false, artwork: null, error: false};
        function ask(selector, callback) {
            var sel = $.NSSelectorFromString(selector);
            if (!request.respondsToSelector(sel)) reject('unsupportedSystem');
            $.objc_msgSend(request, sel, replyBlock(callback), null);
        }
        ask('requestNowPlayingInfoWithCompletion:', function(value, error) {
            state.info = value;
            state.error = state.error || present(error);
            state.infoDone = true;
        });
        var playingReply = ObjC.block(['void', ['bool', 'id']], function(value, error) {
            state.playing = !present(error) && Boolean(value);
            state.error = state.error || present(error);
            state.playingDone = true;
        });
        var playingSelector = $.NSSelectorFromString('requestIsPlayingOnQueue:completion:');
        if (!request.respondsToSelector(playingSelector)) reject('unsupportedSystem');
        retained.push(playingReply);
        $.objc_msgSend(request, playingSelector, queue, playingReply);
        if (includeArtwork) {
            var artSelector = $.NSSelectorFromString('requestNowPlayingItemArtworkWithCompletion:');
            if (request.respondsToSelector(artSelector)) {
                ask('requestNowPlayingItemArtworkWithCompletion:', function(value, _) {
                    state.artwork = value;
                    state.artDone = true;
                });
            } else { state.artDone = true; }
        }
        pump(function() { return state.infoDone && state.playingDone && state.artDone; });
        if (!state.infoDone || !state.playingDone) reject('queryTimedOut');
        if (state.error) reject('queryFailed');
        if (!present(state.info)) return empty();
        var info = state.info;
        var result = empty();
        result.title = text(field(info, 'Title'));
        result.artist = text(field(info, 'Artist'));
        result.album = text(field(info, 'Album'));
        result.duration = number(field(info, 'Duration'));
        if (!result.title) return empty();
        result.isPlaying = state.playing;
        result.position = number(field(info, 'ElapsedTime'));
        var timestamp = info.objectForKey('kMRMediaRemoteNowPlayingInfoTimestamp');
        if (result.isPlaying && present(timestamp)) {
            try {
                var age = Date.now() / 1000 - Number(timestamp.timeIntervalSince1970);
                var rate = number(field(info, 'PlaybackRate'));
                if (isFinite(age) && age >= 0 && age < 86400) result.position += age * (rate || 1);
            } catch (_) { /* Older players may omit the timestamp. */ }
        }
        if (result.duration > 0) result.position = Math.min(result.position, result.duration);
        var unique = field(info, 'ContentItemIdentifier');
        if (unique === null || unique === '') unique = field(info, 'UniqueIdentifier');
        var identity = (typeof unique === 'string' || typeof unique === 'number') ? String(unique) : '';
        result.trackIdentifier = target + ':' + (identity || JSON.stringify([
            result.title, result.artist, result.album, result.duration]));
        if (includeArtwork) {
            var encoded = artworkBase64(state.artwork) || artworkBase64(info.objectForKey('kMRMediaRemoteNowPlayingInfoArtworkData'));
            if (encoded) result.artworkBase64 = encoded;
        }
        return result;
    }
    function control(Request, operation) {
        if (!running() || !activeTarget(Request)) reject('targetNotActive');
        var position = null;
        if (operation === 'seek') {
            if (argv.length !== 4 || argv[2] === '' || argv[3] === '') reject('invalidArguments');
            position = Number(argv[2]);
            if (!isFinite(position) || position < 0) reject('invalidArguments');
            var current = snapshot(Request, false);
            if (!current.trackIdentifier || current.trackIdentifier !== argv[3] ||
                current.duration <= 0 || position > current.duration) return {ok: false};
        }
        // Recheck after asynchronous metadata work; never switch or launch players.
        if (!running() || !activeTarget(Request)) reject('targetNotActive');
        var commands = {togglePlayPause: 2, skipForward: 4, skipBackward: 5, seek: 24};
        var options = $.NSMutableDictionary.dictionary;
        if (position !== null) options.setObjectForKey($(position), 'kMRMediaRemoteOptionPlaybackPosition');
        var done = false;
        var accepted = false;
        var completion = ObjC.block(['void', ['unsigned int', 'id']], function(error, statuses) {
            accepted = Number(error) === 0;
            if (present(statuses)) {
                for (var index = 0; index < Number(statuses.count); index += 1) {
                    accepted = accepted && Number(scalar(statuses.objectAtIndex(index))) === 0;
                }
            }
            done = true;
        });
        retained.push(completion, options);
        var sent = $.MRMediaRemoteSendCommandToApp(commands[operation], options,
            $.NSClassFromString('MROrigin').localOrigin, $(target), 0, queue, completion);
        if (!sent) reject('commandRejected');
        if (!pump(function() { return done; })) reject('commandTimedOut');
        if (!accepted) reject('commandRejected');
        return {ok: true};
    }
    try {
        if (!argv || argv[0] !== target || allowed.indexOf(argv[1]) < 0 ||
            (argv[1] !== 'seek' && argv.length !== 2)) reject('invalidArguments');
        if (!running()) {
            if (argv[1] === 'nowPlaying') return JSON.stringify(empty());
            reject('targetNotRunning');
        }
        var framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (!present(framework) || !framework.load) reject('unsupportedSystem');
        var Request = $.NSClassFromString('MRNowPlayingRequest');
        if (!present(Request) || !present($.NSClassFromString('MROrigin')) ||
            !present($.NSClassFromString('MRPlayer')) || !present($.NSClassFromString('MRPlayerPath'))) reject('unsupportedSystem');
        ObjC.bindFunction('objc_msgSend', ['void', ['id', 'selector', 'id', 'id']]);
        ObjC.bindFunction('dispatch_queue_create', ['id', ['string', 'void*']]);
        queue = $.dispatch_queue_create('com.dynamicisland.spotify.helper', null);
        retained.push(queue);
        ObjC.bindFunction('MRMediaRemoteSendCommandToApp', ['bool',
            ['unsigned int', 'id', 'id', 'id', 'unsigned int', 'id', 'id']]);
        return JSON.stringify(argv[1] === 'nowPlaying' ? snapshot(Request, true) : control(Request, argv[1]));
    } catch (error) {
        var known = ['invalidArguments', 'unsupportedSystem', 'targetNotRunning', 'targetNotActive',
                     'queryTimedOut', 'queryFailed', 'commandRejected', 'commandTimedOut'];
        failure = error && known.indexOf(error.message) >= 0 ? error.message : 'helperFailed';
        return JSON.stringify({ok: false, error: failure});
    }
}
