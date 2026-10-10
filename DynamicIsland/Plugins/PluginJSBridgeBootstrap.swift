import Foundation

/// Captured primordials and Promise resolvers remain private to this Context.
/// Native receives only a numeric request ID and validated JSON string.
nonisolated enum PluginJSBridgeBootstrap {
    static func script(metadataJSON: String, nativeKey: String) -> String {
        """
        (() => {
            'use strict';
            const metadata = \(metadataJSON);
            const native = globalThis['\(nativeKey)'];
            delete globalThis['\(nativeKey)'];
            const create = Object.create, freeze = Object.freeze;
            const descriptor = Object.getOwnPropertyDescriptor, prototype = Object.getPrototypeOf;
            const setPrototype = Object.setPrototypeOf, define = Object.defineProperty;
            const objectPrototype = Object.prototype, arrayPrototype = Array.prototype;
            const ownKeys = Reflect.ownKeys, apply = Reflect.apply;
            const isArray = Array.isArray, finite = Number.isFinite;
            const stringify = JSON.stringify, parse = JSON.parse;
            const PromiseType = Promise, MapType = Map;
            const mapGet = Map.prototype.get, mapSet = Map.prototype.set, mapDelete = Map.prototype.delete;
            const charCode = String.prototype.charCodeAt;
            const pending = new MapType();
            const LIMIT = freeze(create(null));
            let outstanding = 0, nextID = 1;
            const version = '1.0.0';

            function failure(code) {
                const result = create(null);
                result.code = code;
                result.message = code === 'quotaExceeded' ? 'A Host resource limit was exceeded.' : 'Bridge arguments are invalid.';
                return freeze(result);
            }
            function rejected(code) { return new PromiseType((_, reject) => reject(failure(code))); }
            function utf8Bytes(text) {
                let size = 0;
                for (let i = 0; i < text.length; i++) {
                    const unit = apply(charCode, text, [i]);
                    if (unit < 128) size++;
                    else if (unit < 2048) size += 2;
                    else if (unit >= 55296 && unit <= 56319 && i + 1 < text.length) {
                        const second = apply(charCode, text, [i + 1]);
                        if (second >= 56320 && second <= 57343) { size += 4; i++; }
                        else size += 3;
                    } else size += 3;
                }
                return size;
            }
            function snapshot(value, depth, budget, ancestors) {
                // Eight node levels can contain both a children array and a
                // node object per level, plus image source and Activity data.
                if (++budget.count > 512 || depth > 20) throw LIMIT;
                if (value === null || typeof value === 'boolean') return value;
                if (typeof value === 'number') {
                    if (!finite(value)) throw null;
                    return value;
                }
                if (typeof value === 'string') {
                    if (utf8Bytes(value) > 4096) throw LIMIT;
                    return value;
                }
                if (typeof value !== 'object') throw null;
                for (let i = 0; i < ancestors.length; i++) if (ancestors[i] === value) throw null;
                const array = isArray(value);
                const proto = prototype(value);
                if (proto !== null && proto !== (array ? arrayPrototype : objectPrototype)) throw null;
                const keys = ownKeys(value);
                if (keys.length > 512) throw LIMIT;
                const fields = create(null);
                for (let i = 0; i < keys.length; i++) {
                    const key = keys[i];
                    if (typeof key !== 'string' || key === 'toJSON') throw null;
                    if (utf8Bytes(key) > 4096) throw LIMIT;
                    const field = descriptor(value, key);
                    // Descriptors have own data properties even if plugins
                    // change Object.prototype. Never read value[key].
                    if (!field || !descriptor(field, 'value')) throw null;
                    // Cache the validated data once. A Proxy can change its
                    // descriptor on a second reflective read.
                    fields[key] = field.value;
                }
                const chain = [];
                setPrototype(chain, null);
                for (let i = 0; i < ancestors.length; i++) chain[i] = ancestors[i];
                chain[ancestors.length] = value;
                if (array) {
                    const length = fields.length;
                    if (typeof length !== 'number' || !finite(length) || length < 0 ||
                        length % 1 !== 0 || length > 512 || keys.length !== length + 1) throw null;
                    const output = [];
                    setPrototype(output, null);
                    for (let i = 0; i < length; i++) {
                        const field = descriptor(fields, '' + i);
                        if (!field) throw null; // Sparse arrays are not accepted.
                        output[i] = snapshot(field.value, depth + 1, budget, chain);
                    }
                    return output;
                }
                const output = create(null);
                for (let i = 0; i < keys.length; i++) {
                    const key = keys[i];
                    output[key] = snapshot(fields[key], depth + 1, budget, chain);
                }
                return output;
            }
            function send(method, params) {
                return new PromiseType((resolve, reject) => {
                    let id;
                    try {
                        if (outstanding >= 64 || nextID > 9007199254740991) throw LIMIT;
                        const request = create(null);
                        request.apiVersion = version;
                        request.method = method;
                        request.params = snapshot(params, 1, {count: 0}, []);
                        const json = stringify(request);
                        if (utf8Bytes(json) > 16384) throw LIMIT;
                        id = nextID++;
                        const pair = create(null);
                        pair.resolve = resolve; pair.reject = reject;
                        apply(mapSet, pending, [id, pair]);
                        outstanding++;
                        native(id, json);
                    } catch (error) {
                        if (id !== undefined && apply(mapDelete, pending, [id])) outstanding--;
                        reject(failure(error === LIMIT ? 'quotaExceeded' : 'invalidArguments'));
                    }
                });
            }
            function method(fn) {
                const attributes = create(null);
                attributes.value = version;
                define(fn, 'apiVersion', attributes);
                return freeze(fn);
            }
            const log = method(function(message, level) {
                if (arguments.length < 1 || arguments.length > 2) return rejected('invalidArguments');
                return send('log', {message, level: level === undefined ? 'info' : level});
            });
            const activity = create(null);
            activity.apiVersion = version;
            activity.publish = method(function(value) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('activity.publish', value);
            });
            activity.update = method(function(value) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('activity.update', value);
            });
            activity.end = method(function(id) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('activity.end', {id});
            });
            const storage = create(null);
            storage.apiVersion = version;
            storage.get = method(function(key) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('storage.get', {key});
            });
            storage.set = method(function(key, value) {
                if (arguments.length !== 2) return rejected('invalidArguments');
                return send('storage.set', {key, value});
            });
            storage.remove = method(function(key) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('storage.remove', {key});
            });
            storage.clear = method(function() {
                if (arguments.length !== 0) return rejected('invalidArguments');
                return send('storage.clear', {});
            });
            const actions = create(null);
            actions.apiVersion = version;
            actions.supported = false;
            actions.on = method(function(actionID, handler) {
                if (arguments.length !== 2 || typeof handler !== 'function') return rejected('invalidArguments');
                return send('actions.on', {actionID});
            });
            actions.off = method(function(actionID) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('actions.off', {actionID});
            });
            const plugin = create(null);
            plugin.id = metadata.plugin.id; plugin.name = metadata.plugin.name; plugin.version = metadata.plugin.version;
            const island = create(null);
            island.apiVersion = version;
            island.plugin = freeze(plugin);
            island.log = log;
            island.activity = freeze(activity);
            island.storage = freeze(storage);
            island.actions = freeze(actions);
            const attributes = create(null);
            attributes.value = freeze(island);
            attributes.enumerable = true;
            define(globalThis, 'island', attributes);
            return function receive(id, json) {
                const pair = apply(mapGet, pending, [id]);
                if (!pair) return;
                apply(mapDelete, pending, [id]);
                outstanding--;
                const response = parse(json);
                if (response.ok) {
                    // Null-prototype copies also prevent inherited "then"
                    // getters from running during Promise resolution.
                    pair.resolve(snapshot(response.value, 1, {count: 0}, []));
                } else {
                    const error = create(null);
                    error.code = response.error.code;
                    error.message = response.error.message;
                    pair.reject(freeze(error));
                }
            };
        })();
        """
    }
}
