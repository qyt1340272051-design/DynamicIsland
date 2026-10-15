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
            const promiseThen = Promise.prototype.then;
            const mapGet = Map.prototype.get, mapSet = Map.prototype.set, mapDelete = Map.prototype.delete;
            const charCode = String.prototype.charCodeAt, lowercase = String.prototype.toLowerCase;
            const sliceString = String.prototype.slice;
            const pending = new MapType();
            const handlers = new MapType();
            const promiseConstructor = create(null);
            const speciesAttributes = create(null);
            speciesAttributes.value = PromiseType;
            define(promiseConstructor, Symbol.species, speciesAttributes);
            freeze(promiseConstructor);
            const LIMIT = freeze(create(null));
            let outstanding = 0, nextID = 1;
            let handlerCount = 0, nextRegistration = 1, pendingActions = 0;
            let countdownHandler;
            const version = '1.0.0';

            function failure(code) {
                const result = create(null);
                result.code = code;
                result.message = code === 'quotaExceeded' ? 'A Host resource limit was exceeded.' :
                    code === 'invalidResponse' ? 'The Host response is invalid.' : 'Bridge arguments are invalid.';
                return freeze(result);
            }
            function rejected(code) { return new PromiseType((_, reject) => reject(failure(code))); }
            // Internal registration/log continuations must survive plugins
            // changing Promise.prototype.then or its constructor/species.
            function chainRequest(request, fulfilled, rejected) {
                const attributes = create(null);
                attributes.value = promiseConstructor;
                define(request, 'constructor', attributes);
                return apply(promiseThen, request, [fulfilled, rejected]);
            }
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
            function snapshotBudget(maximumNodes = 512, maximumStringBytes = 4096) {
                const budget = create(null);
                budget.count = 0;
                budget.maximumNodes = maximumNodes;
                budget.maximumStringBytes = maximumStringBytes;
                return budget;
            }
            function snapshot(value, depth, budget, ancestors) {
                // Eight node levels can contain both a children array and a
                // node object per level, plus image source and Activity data.
                if (++budget.count > budget.maximumNodes || depth > 20) throw LIMIT;
                if (value === null || typeof value === 'boolean') return value;
                if (typeof value === 'number') {
                    if (!finite(value)) throw null;
                    return value;
                }
                if (typeof value === 'string') {
                    if (utf8Bytes(value) > budget.maximumStringBytes) throw LIMIT;
                    return value;
                }
                if (typeof value !== 'object') throw null;
                for (let i = 0; i < ancestors.length; i++) if (ancestors[i] === value) throw null;
                const array = isArray(value);
                const proto = prototype(value);
                if (proto !== null && proto !== (array ? arrayPrototype : objectPrototype)) throw null;
                const keys = ownKeys(value);
                if (keys.length > budget.maximumNodes) throw LIMIT;
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
                        length % 1 !== 0 || length > budget.maximumNodes || keys.length !== length + 1) throw null;
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
                        request.params = snapshot(params, 1, snapshotBudget(), []);
                        if (method === 'activity.publish' || method === 'activity.update') {
                            validateActivityPresentation(request.params);
                        }
                        if (method.length > 10 && apply(sliceString, method, [0, 10]) === 'countdown.') {
                            validateCountdownParams(method, request.params);
                        }
                        const json = stringify(request);
                        if (utf8Bytes(json) > 16384) throw LIMIT;
                        id = nextID++;
                        const pair = create(null);
                        pair.resolve = resolve; pair.reject = reject; pair.method = method;
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
            function validActionID(value) {
                if (typeof value !== 'string' || value.length === 0) return false;
                for (let i = 0; i < value.length; i++) {
                    const code = apply(charCode, value, [i]);
                    if (!((code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
                          (code >= 97 && code <= 122) || code === 45 || code === 46 || code === 95)) return false;
                }
                return true;
            }
            function freezeTree(value) {
                if (value === null || typeof value !== 'object') return value;
                const keys = ownKeys(value);
                for (let i = 0; i < keys.length; i++) {
                    const field = descriptor(value, keys[i]);
                    if (field) freezeTree(field.value);
                }
                return freeze(value);
            }
            function fieldsWithShape(value, required, optional = []) {
                if (value === null || typeof value !== 'object' || isArray(value)) throw null;
                const proto = prototype(value);
                if (proto !== null && proto !== objectPrototype) throw null;
                const keys = ownKeys(value), fields = create(null);
                if (keys.length > required.length + optional.length) throw null;
                for (let i = 0; i < keys.length; i++) {
                    const key = keys[i];
                    let allowed = false;
                    for (let j = 0; j < required.length; j++) if (key === required[j]) allowed = true;
                    for (let j = 0; j < optional.length; j++) if (key === optional[j]) allowed = true;
                    if (!allowed) throw null;
                    const field = descriptor(value, key);
                    if (!field || !descriptor(field, 'value')) throw null;
                    fields[key] = field.value;
                }
                for (let i = 0; i < required.length; i++) if (!descriptor(fields, required[i])) throw null;
                return fields;
            }
            function validateActivityPresentation(params) {
                // Read only the safe snapshot. Host independently validates the
                // whole Activity and never coerces optional presentation fields.
                if (params === null || typeof params !== 'object' || isArray(params)) return;
                const presentation = descriptor(params, 'presentation');
                if (!presentation) return;
                const fields = fieldsWithShape(presentation.value, ['title'],
                    ['subtitle', 'symbolName', 'progress', 'minimal', 'compact', 'expanded', 'showsCompact', 'role']);
                if (descriptor(fields, 'showsCompact') && typeof fields.showsCompact !== 'boolean') throw null;
                if (descriptor(fields, 'role') && fields.role !== 'status' && fields.role !== 'tool') throw null;
                const layouts = ['minimal', 'compact', 'expanded'];
                for (let i = 0; i < layouts.length; i++) {
                    const layout = descriptor(fields, layouts[i]);
                    if (layout) validateCountdownNode(layout.value);
                }
            }
            function validateCountdownNode(value) {
                // Only follow the finite node edges of the existing safe
                // snapshot. Other node validation remains the Host's job.
                if (value === null || typeof value !== 'object' || isArray(value)) return;
                const type = descriptor(value, 'type');
                if (!type) return;
                if (type.value === 'countdown') {
                    const fields = fieldsWithShape(value, ['type', 'id', 'generation'], ['style', 'color']);
                    if (!validActionID(fields.id) || fields.id.length > 80 ||
                        !validCountdownGeneration(fields.generation)) throw null;
                    if (descriptor(fields, 'style') && fields.style !== 'time' && fields.style !== 'progress') throw null;
                    if (descriptor(fields, 'color') && fields.color !== 'primary' && fields.color !== 'secondary' &&
                        fields.color !== 'accent' && fields.color !== 'success' && fields.color !== 'warning' &&
                        fields.color !== 'danger') throw null;
                } else if (type.value === 'hStack' || type.value === 'vStack' || type.value === 'zStack') {
                    const children = descriptor(value, 'children');
                    if (!children || !isArray(children.value)) return;
                    const nodes = children.value;
                    for (let i = 0; i < nodes.length; i++) validateCountdownNode(nodes[i]);
                } else if (type.value === 'button') {
                    const label = descriptor(value, 'label');
                    if (label) validateCountdownNode(label.value);
                }
            }
            function hasHTTPSPrefix(url) {
                const scheme = 'https://';
                if (url.length <= scheme.length) return false;
                for (let i = 0; i < scheme.length; i++) {
                    const actual = apply(charCode, url, [i]), expected = apply(charCode, scheme, [i]);
                    if (actual !== expected && !(i < 5 && actual + 32 === expected)) return false;
                }
                for (let i = scheme.length; i < url.length; i++) {
                    const unit = apply(charCode, url, [i]);
                    if (unit <= 32 || unit === 127) return false;
                }
                return true;
            }
            function validHeaderName(name) {
                if (name.length === 0) return false;
                for (let i = 0; i < name.length; i++) {
                    const unit = apply(charCode, name, [i]);
                    if (!((unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) ||
                          (unit >= 97 && unit <= 122) || unit === 33 || unit === 35 || unit === 36 ||
                          unit === 37 || unit === 38 || unit === 39 || unit === 42 || unit === 43 ||
                          unit === 45 || unit === 46 || unit === 94 || unit === 95 || unit === 96 ||
                          unit === 124 || unit === 126)) return false;
                }
                return true;
            }
            function validatedHeaders(value, isRequest) {
                if (value === null || typeof value !== 'object' || isArray(value)) throw null;
                const proto = prototype(value);
                if (proto !== null && proto !== objectPrototype) throw null;
                const keys = ownKeys(value), output = create(null), seen = create(null);
                if (keys.length > (isRequest ? 16 : 512)) throw LIMIT;
                let bytes = 0;
                for (let i = 0; i < keys.length; i++) {
                    const name = keys[i];
                    if (typeof name !== 'string' || !validHeaderName(name)) throw null;
                    const nameBytes = utf8Bytes(name);
                    if (isRequest && nameBytes > 64) throw LIMIT;
                    const normalized = apply(lowercase, name, []);
                    if (descriptor(seen, normalized)) throw null;
                    seen[normalized] = true;
                    if (isRequest && (normalized === 'host' || normalized === 'cookie' || normalized === 'connection' ||
                        normalized === 'content-length' || normalized === 'transfer-encoding' || normalized === 'upgrade' ||
                        (apply(charCode, normalized, [0]) === 112 && apply(charCode, normalized, [1]) === 114 &&
                         apply(charCode, normalized, [2]) === 111 && apply(charCode, normalized, [3]) === 120 &&
                         apply(charCode, normalized, [4]) === 121 && apply(charCode, normalized, [5]) === 45))) throw null;
                    const field = descriptor(value, name);
                    if (!field || !descriptor(field, 'value') || typeof field.value !== 'string') throw null;
                    const text = field.value, valueBytes = utf8Bytes(text);
                    if (isRequest && valueBytes > 1024) throw LIMIT;
                    bytes += nameBytes + valueBytes;
                    if (bytes > 4096) throw LIMIT;
                    for (let j = 0; j < text.length; j++) {
                        const unit = apply(charCode, text, [j]);
                        if ((unit < 32 && unit !== 9) || unit === 127) throw null;
                    }
                    output[name] = text;
                }
                return freeze(output);
            }
            function networkResponse(value) {
                const fields = fieldsWithShape(value, ['status', 'headers', 'body']);
                if (typeof fields.status !== 'number' || !finite(fields.status) || fields.status % 1 !== 0 ||
                    fields.status < 100 || fields.status > 599 || typeof fields.body !== 'string') throw null;
                if (utf8Bytes(fields.body) > 65536) throw LIMIT;
                const response = create(null);
                response.status = fields.status;
                response.ok = fields.status >= 200 && fields.status < 300;
                response.headers = validatedHeaders(fields.headers, false);
                const body = fields.body;
                response.text = method(function() {
                    if (arguments.length !== 0) return rejected('invalidArguments');
                    return new PromiseType(resolve => resolve(body));
                });
                response.json = method(function() {
                    if (arguments.length !== 0) return rejected('invalidArguments');
                    return new PromiseType((resolve, reject) => {
                        try {
                            resolve(freezeTree(snapshot(parse(body), 1, snapshotBudget(4096, 65536), [])));
                        } catch (error) {
                            reject(failure(error === LIMIT ? 'quotaExceeded' : 'invalidResponse'));
                        }
                    });
                });
                return freeze(response);
            }
            function textFileResponse(value) {
                if (value === null) return null;
                const fields = fieldsWithShape(value, ['name', 'type', 'text', 'size']);
                if (typeof fields.name !== 'string' || fields.name.length === 0 ||
                    typeof fields.type !== 'string' || fields.type.length === 0 ||
                    typeof fields.text !== 'string' || typeof fields.size !== 'number' ||
                    !finite(fields.size) || fields.size % 1 !== 0 || fields.size < 0 || fields.size > 65536) throw null;
                if (utf8Bytes(fields.name) > 255 || utf8Bytes(fields.type) > 128 ||
                    utf8Bytes(fields.text) > 65536) throw LIMIT;
                for (let i = 0; i < fields.name.length; i++) {
                    const unit = apply(charCode, fields.name, [i]);
                    if (unit < 32 || unit === 127 || unit === 47) throw null;
                }
                if (fields.type !== 'text/plain' && fields.type !== 'text/markdown' &&
                    fields.type !== 'application/json' && fields.type !== 'text/csv') throw null;
                for (let i = 0; i < fields.text.length; i++) {
                    if (apply(charCode, fields.text, [i]) === 0) throw null;
                }
                if (fields.size !== utf8Bytes(fields.text)) throw null;
                return freeze(fields);
            }
            function schedulerResponse(value) {
                const fields = fieldsWithShape(value, ['policy']);
                if (fields.policy !== 'active' && fields.policy !== 'background' && fields.policy !== 'lowPower') throw null;
                return freeze(fields);
            }
            function validCountdownGeneration(value) {
                if (typeof value !== 'string' || value.length !== 36) return false;
                for (let i = 0; i < value.length; i++) {
                    const code = apply(charCode, value, [i]);
                    if (i === 8 || i === 13 || i === 18 || i === 23) {
                        if (code !== 45) return false;
                    } else if (!((code >= 48 && code <= 57) || (code >= 97 && code <= 102))) return false;
                }
                return true;
            }
            function validateCountdownParams(name, value) {
                let required;
                switch (name) {
                    case 'countdown.get': required = ['id']; break;
                    case 'countdown.start': required = ['id', 'durationMs', 'activation']; break;
                    case 'countdown.pause': case 'countdown.stop': required = ['id', 'generation']; break;
                    case 'countdown.resume': required = ['id', 'generation', 'activation']; break;
                    case 'countdown.onComplete': required = ['registrationID']; break;
                    case 'countdown.offComplete': required = []; break;
                    case 'countdown.failure': required = ['kind']; break;
                    default: throw null;
                }
                const fields = fieldsWithShape(value, required);
                const identifiers = ['id', 'activation', 'registrationID'];
                for (let i = 0; i < identifiers.length; i++) {
                    const key = identifiers[i];
                    if (descriptor(fields, key) && (!validActionID(fields[key]) || fields[key].length > 80)) throw null;
                }
                if (descriptor(fields, 'generation') && !validCountdownGeneration(fields.generation)) throw null;
                if (descriptor(fields, 'durationMs') && (typeof fields.durationMs !== 'number' ||
                    !finite(fields.durationMs) || fields.durationMs % 1 !== 0 ||
                    fields.durationMs < 1000 || fields.durationMs > 86400000)) throw null;
                if (descriptor(fields, 'kind') && fields.kind !== 'exception' && fields.kind !== 'rejection' && fields.kind !== 'limit') throw null;
            }
            function countdownResponse(value, nullable) {
                if (value === null && nullable) return null;
                const fields = fieldsWithShape(value, ['id', 'generation', 'state', 'durationMs', 'remainingMs']);
                if (!validActionID(fields.id) || fields.id.length > 80 || !validCountdownGeneration(fields.generation)) throw null;
                if (fields.state !== 'running' && fields.state !== 'paused' && fields.state !== 'completed') throw null;
                if (typeof fields.durationMs !== 'number' || !finite(fields.durationMs) || fields.durationMs % 1 !== 0 ||
                    fields.durationMs < 1000 || fields.durationMs > 86400000 ||
                    typeof fields.remainingMs !== 'number' || !finite(fields.remainingMs) || fields.remainingMs % 1 !== 0 ||
                    fields.remainingMs < 0 || fields.remainingMs > fields.durationMs ||
                    (fields.state === 'completed' && fields.remainingMs !== 0)) throw null;
                return freeze(fields);
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
            const clipboard = create(null);
            clipboard.apiVersion = version;
            clipboard.supported = true;
            clipboard.readText = method(function() {
                if (arguments.length !== 0) return rejected('invalidArguments');
                return send('clipboard.readText', {});
            });
            clipboard.writeText = method(function(text) {
                if (arguments.length !== 1 || typeof text !== 'string') return rejected('invalidArguments');
                if (utf8Bytes(text) > 4096) return rejected('quotaExceeded');
                return send('clipboard.writeText', {text});
            });
            const files = create(null);
            files.apiVersion = version;
            files.supported = true;
            files.chooseText = method(function() {
                if (arguments.length !== 0) return rejected('invalidArguments');
                return send('files.chooseText', {});
            });
            const scheduler = create(null);
            scheduler.apiVersion = version;
            scheduler.supported = true;
            scheduler.requestRefresh = method(function(delayMs) {
                if (arguments.length !== 1 || typeof delayMs !== 'number' || !finite(delayMs) ||
                    delayMs % 1 !== 0 || delayMs < 1000 || delayMs > 86400000) return rejected('invalidArguments');
                return send('scheduler.requestRefresh', {delayMs});
            });
            const countdown = create(null);
            countdown.apiVersion = version;
            countdown.supported = true;
            countdown.get = method(function(id) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('countdown.get', {id});
            });
            countdown.start = method(function(options) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('countdown.start', options);
            });
            countdown.pause = method(function(options) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('countdown.pause', options);
            });
            countdown.resume = method(function(options) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('countdown.resume', options);
            });
            countdown.stop = method(function(options) {
                if (arguments.length !== 1) return rejected('invalidArguments');
                return send('countdown.stop', options);
            });
            countdown.onComplete = method(function(handler) {
                if (arguments.length !== 1 || typeof handler !== 'function') return rejected('invalidArguments');
                if (nextRegistration > 9007199254740991) return rejected('quotaExceeded');
                const record = create(null);
                record.registrationID = 'c' + nextRegistration++;
                record.handler = handler;
                record.previous = countdownHandler;
                record.failed = false;
                countdownHandler = record;
                return chainRequest(send('countdown.onComplete', {registrationID: record.registrationID}), function() {
                    record.previous = undefined;
                    return null;
                }, function(error) {
                    record.failed = true;
                    if (countdownHandler === record) {
                        let previous = record.previous;
                        while (previous && previous.failed) previous = previous.previous;
                        countdownHandler = previous;
                    }
                    throw error;
                });
            });
            countdown.offComplete = method(function() {
                if (arguments.length !== 0) return rejected('invalidArguments');
                countdownHandler = undefined;
                return send('countdown.offComplete', {});
            });
            const network = create(null);
            network.apiVersion = version;
            network.supported = true;
            network.fetch = method(function(url, options) {
                if (arguments.length < 1 || arguments.length > 2) return rejected('invalidArguments');
                try {
                    if (typeof url !== 'string') throw null;
                    if (utf8Bytes(url) > 2048) throw LIMIT;
                    if (!hasHTTPSPrefix(url)) throw null;
                    const params = create(null);
                    params.url = url;
                    if (options !== undefined) {
                        // Snapshot first so a plugin Proxy supplies each data
                        // descriptor once. Host independently validates all
                        // options and the approved HTTPS destination.
                        const fields = fieldsWithShape(snapshot(options, 1, snapshotBudget(), []), [],
                            ['method', 'headers', 'timeoutMs']);
                        if (descriptor(fields, 'method')) {
                            if (fields.method !== 'GET' && fields.method !== 'HEAD') throw null;
                            params.method = fields.method;
                        }
                        if (descriptor(fields, 'headers')) params.headers = validatedHeaders(fields.headers, true);
                        if (descriptor(fields, 'timeoutMs')) {
                            const timeout = fields.timeoutMs;
                            if (typeof timeout !== 'number' || !finite(timeout) || timeout % 1 !== 0 ||
                                timeout < 100 || timeout > 30000) throw null;
                            params.timeoutMs = timeout;
                        }
                    }
                    return send('network.fetch', params);
                } catch (error) {
                    return rejected(error === LIMIT ? 'quotaExceeded' : 'invalidArguments');
                }
            });
            const actions = create(null);
            actions.apiVersion = version;
            actions.supported = true;
            actions.on = method(function(actionID, handler) {
                if (arguments.length !== 2 || !validActionID(actionID) || typeof handler !== 'function') {
                    return rejected('invalidArguments');
                }
                if (actionID.length > 80 || outstanding >= 64 || nextID > 9007199254740991) {
                    return rejected('quotaExceeded');
                }
                const previous = apply(mapGet, handlers, [actionID]);
                if ((!previous && handlerCount >= 128) || nextRegistration > 9007199254740991) {
                    return rejected('quotaExceeded');
                }
                const registrationID = 'r' + nextRegistration++;
                const record = create(null);
                record.registrationID = registrationID;
                record.handler = handler;
                record.previous = previous;
                record.failed = false;
                if (!previous) handlerCount++;
                apply(mapSet, handlers, [actionID, record]);
                return chainRequest(send('actions.on', {actionID, registrationID}), function() {
                    record.previous = undefined;
                    return null;
                }, function(error) {
                    record.failed = true;
                    if (apply(mapGet, handlers, [actionID]) === record) {
                        let restored = record.previous;
                        while (restored && restored.failed) restored = restored.previous;
                        if (restored) apply(mapSet, handlers, [actionID, restored]);
                        else {
                            apply(mapDelete, handlers, [actionID]);
                            handlerCount--;
                        }
                    }
                    throw error;
                });
            });
            actions.off = method(function(actionID) {
                if (arguments.length !== 1 || !validActionID(actionID)) return rejected('invalidArguments');
                if (actionID.length > 80) return rejected('quotaExceeded');
                if (apply(mapDelete, handlers, [actionID])) handlerCount--;
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
            island.clipboard = freeze(clipboard);
            island.files = freeze(files);
            island.network = freeze(network);
            island.scheduler = freeze(scheduler);
            island.countdown = freeze(countdown);
            island.actions = freeze(actions);
            const attributes = create(null);
            attributes.value = freeze(island);
            attributes.enumerable = true;
            define(globalThis, 'island', attributes);
            function receiveResponse(id, json) {
                const pair = apply(mapGet, pending, [id]);
                if (!pair) return;
                apply(mapDelete, pending, [id]);
                outstanding--;
                try {
                    // Never coerce a native object or pass it to JSON.parse.
                    // Bound the wire before allocating parsed JS objects.
                    if (typeof json !== 'string') throw null;
                    if (json.length > 524288 || utf8Bytes(json) > 524288) throw LIMIT;
                    const response = fieldsWithShape(parse(json), ['ok'], ['value', 'error']);
                    if (response.ok === true) {
                        if (!descriptor(response, 'value') || descriptor(response, 'error')) throw null;
                        // Null-prototype copies prevent inherited "then"
                        // getters from running during Promise resolution.
                        const value = snapshot(response.value, 1,
                            snapshotBudget(512, pair.method === 'network.fetch' || pair.method === 'files.chooseText' ? 65536 : 4096), []);
                        if (pair.method === 'network.fetch') pair.resolve(networkResponse(value));
                        else if (pair.method === 'files.chooseText') pair.resolve(textFileResponse(value));
                        else if (pair.method === 'scheduler.requestRefresh') pair.resolve(schedulerResponse(value));
                        else if (pair.method === 'countdown.get' || pair.method === 'countdown.start' ||
                                 pair.method === 'countdown.pause' || pair.method === 'countdown.resume') {
                            pair.resolve(countdownResponse(value, pair.method === 'countdown.get'));
                        } else if (pair.method === 'countdown.stop' || pair.method === 'countdown.onComplete' ||
                                   pair.method === 'countdown.offComplete' || pair.method === 'countdown.failure') {
                            if (value !== null) throw null;
                            pair.resolve(null);
                        }
                        else if (pair.method === 'clipboard.readText') {
                            if (value !== null && typeof value !== 'string') throw null;
                            pair.resolve(value);
                        } else if (pair.method === 'clipboard.writeText') {
                            if (value !== null) throw null;
                            pair.resolve(null);
                        } else pair.resolve(value);
                    } else if (response.ok === false) {
                        if (!descriptor(response, 'error') || descriptor(response, 'value')) throw null;
                        const fields = fieldsWithShape(snapshot(response.error, 1, snapshotBudget(), []), ['code', 'message']);
                        if (typeof fields.code !== 'string' || typeof fields.message !== 'string') throw null;
                        pair.reject(freeze(fields));
                    } else throw null;
                } catch (error) {
                    pair.reject(failure(error === LIMIT ? 'quotaExceeded' : 'invalidResponse'));
                }
            }
            function reportActionFailure(kind) {
                // The private runtime channel contains only a Host-defined
                // category. Never inspect, stringify or retain thrown values.
                // A rejected diagnostic request must not recursively report.
                chainRequest(send('runtime.actionFailure', {kind}), function() {}, function() {});
            }
            function receiveAction(registrationID, json) {
                let event;
                try {
                    event = freezeTree(snapshot(parse(json), 1, snapshotBudget(), []));
                } catch (_) {
                    return;
                }
                if (event === null || typeof event !== 'object') return;
                const record = apply(mapGet, handlers, [event.actionID]);
                if (!record || record.registrationID !== registrationID) return;
                if (pendingActions >= 64) {
                    reportActionFailure('limit');
                    return;
                }
                pendingActions++;
                let result;
                try {
                    result = apply(record.handler, undefined, [event]);
                } catch (_) {
                    pendingActions--;
                    reportActionFailure('exception');
                    return;
                }
                if (result !== null && typeof result === 'object') {
                    try {
                        // The captured native method checks the Promise brand
                        // before reading properties. Ordinary return objects
                        // and their then getters are ignored.
                        apply(promiseThen, result, [function() {
                            pendingActions--;
                        }, function() {
                            pendingActions--;
                            reportActionFailure('rejection');
                        }]);
                        return;
                    } catch (_) { /* An ordinary object is not a Promise. */ }
                }
                pendingActions--;
            }
            function reportCountdownFailure(kind) {
                chainRequest(send('countdown.failure', {kind}), function() {}, function() {});
            }
            function receiveCountdown(registrationID, json) {
                const record = countdownHandler;
                if (!record || record.registrationID !== registrationID) return;
                let event;
                try {
                    if (typeof json !== 'string' || json.length > 4096) throw null;
                    event = countdownResponse(snapshot(parse(json), 1, snapshotBudget(), []), false);
                    if (event.state !== 'completed') throw null;
                } catch (_) { return; }
                if (pendingActions >= 64) { reportCountdownFailure('limit'); return; }
                pendingActions++;
                let result;
                try { result = apply(record.handler, undefined, [event]); }
                catch (_) { pendingActions--; reportCountdownFailure('exception'); return true; }
                if (result !== null && typeof result === 'object') {
                    try {
                        apply(promiseThen, result, [function() { pendingActions--; }, function() {
                            pendingActions--; reportCountdownFailure('rejection');
                        }]);
                        return true;
                    } catch (_) { /* Ignore unbranded thenable objects. */ }
                }
                pendingActions--;
                return true;
            }
            const receivers = create(null);
            receivers.receiveResponse = receiveResponse;
            receivers.receiveAction = receiveAction;
            receivers.receiveCountdown = receiveCountdown;
            return freeze(receivers);
        })();
        """
    }
}
