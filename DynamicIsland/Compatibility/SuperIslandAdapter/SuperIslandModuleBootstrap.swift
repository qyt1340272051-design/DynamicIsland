import Foundation

/// An independent, deliberately small implementation of the fixed upstream
/// Module/View protocol. The installer and all callbacks stay in the plugin's
/// existing worker VM. Its bridge argument is retained only in this closure.
nonisolated enum SuperIslandModuleBootstrap {
    static let script = """
    (function(bridge) {
        'use strict';
        const create = Object.create, freeze = Object.freeze;
        const descriptor = Object.getOwnPropertyDescriptor, prototype = Object.getPrototypeOf;
        const define = Object.defineProperty, setPrototype = Object.setPrototypeOf;
        const ownKeys = Reflect.ownKeys, apply = Reflect.apply;
        const objectPrototype = Object.prototype;
        const functionPrototype = Function.prototype, isArray = Array.isArray;
        const charCode = String.prototype.charCodeAt;
        const nativeActionsOn = island.actions.on, nativeActionsOff = island.actions.off;
        const snapshotValue = bridge.snapshot, sendRender = bridge.render;
        const reportFailure = bridge.reportFailure, chain = bridge.chain, resolved = bridge.resolved;
        const INVALID = problem('invalidArguments');
        const LIMIT = problem('quotaExceeded');
        const UNSUPPORTED = problem('unsupportedMethod');
        let config, registering = false, didStart = false, didStop = false, active = false;
        let inFlight = false, pendingRender;
        const registrations = create(null);

        function problem(code) {
            const value = create(null);
            value.code = code;
            value.message = 'The compatibility operation is unsupported or invalid.';
            return freeze(value);
        }
        function dataFields(value, allowed) {
            if (value === null || typeof value !== 'object' || isArray(value)) throw INVALID;
            const proto = prototype(value);
            if (proto !== null && proto !== objectPrototype) throw INVALID;
            const keys = ownKeys(value), fields = create(null);
            if (keys.length > allowed.length) throw INVALID;
            for (let i = 0; i < keys.length; i++) {
                const key = keys[i];
                let accepted = false;
                for (let j = 0; j < allowed.length; j++) if (key === allowed[j]) accepted = true;
                if (!accepted) throw INVALID;
                const field = descriptor(value, key);
                if (!field || !descriptor(field, 'value')) throw INVALID;
                fields[key] = field.value;
            }
            return fields;
        }
        function options(value, allowed) {
            return value === undefined || value === null ? create(null) : dataFields(value, allowed);
        }
        function ownArray() {
            const value = [];
            setPrototype(value, null);
            return value;
        }
        function validActionID(value) {
            if (typeof value !== 'string' || value.length === 0 || value.length > 80) return false;
            for (let i = 0; i < value.length; i++) {
                const code = apply(charCode, value, [i]);
                if (!((code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
                    (code >= 97 && code <= 122) || code === 45 || code === 46 || code === 95)) return false;
            }
            return true;
        }
        function synchronous(callback, args) {
            const value = apply(callback, undefined, args);
            if (value !== undefined) throw INVALID;
        }
        function safeSnapshot(value) {
            try { return snapshotValue(value); }
            catch (error) {
                // snapshotValue always replaces thrown values with a private
                // fixed data error. Never inspect a plugin callback exception.
                const code = descriptor(error, 'code');
                throw code && code.value === 'quotaExceeded' ? LIMIT : INVALID;
            }
        }
        function collectActions(node, depth, budget, ids) {
            if (depth > \(IslandNode.Limits.maxDepth) || ++budget.count > \(IslandNode.Limits.maxNodes)) throw LIMIT;
            if (node === null || typeof node !== 'object' || isArray(node)) throw INVALID;
            switch (node.type) {
            case 'button':
                if (!validActionID(node.action)) throw INVALID;
                if (!descriptor(ids, node.action)) {
                    if (++budget.actions > 8) throw LIMIT;
                    ids[node.action] = true;
                }
                collectActions(node.label, depth + 1, budget, ids);
                break;
            case 'hstack':
            case 'vstack':
                if (!isArray(node.children)) throw INVALID;
                if (node.children.length > \(IslandNode.Limits.maxChildren)) throw LIMIT;
                for (let i = 0; i < node.children.length; i++) {
                    collectActions(node.children[i], depth + 1, budget, ids);
                }
                break;
            case 'text': case 'icon': case 'progress': break;
            // The Host converter rejects unsupported nodes, fields and
            // values. This walk collects references; it grants no UI rights.
            default: break;
            }
        }
        function prepareRender() {
            const compact = apply(config.compact, undefined, []);
            const expanded = config.expanded ? apply(config.expanded, undefined, []) : compact;
            const value = safeSnapshot({compact, expanded});
            const ids = create(null);
            const compactBudget = create(null); compactBudget.count = 0; compactBudget.actions = 0;
            collectActions(value.compact, 1, compactBudget, ids);
            const expandedBudget = create(null); expandedBudget.count = 0;
            expandedBudget.actions = compactBudget.actions;
            collectActions(value.expanded, 1, expandedBudget, ids);
            if (expandedBudget.actions > 0 && !config.onAction) throw INVALID;
            const request = create(null);
            request.compact = value.compact; request.expanded = value.expanded;
            request.actions = ownKeys(ids);
            return request;
        }
        function failed(error) {
            if (!active) return;
            reportFailure(error === LIMIT ? 'limit' : error === INVALID ? 'invalidArguments' : 'rejection');
        }
        function handleAction(event) {
            if (!active || !config.onAction) return;
            // Current subset has only buttons. Do not forward the Host's
            // execution identity or user-activation ticket to module code.
            synchronous(config.onAction, [event.actionID]);
            try { requestRender(); }
            catch (error) {
                reportFailure(error === LIMIT ? 'limit' : error === INVALID ? 'invalidArguments' : 'exception');
            }
        }
        function requestRender() {
            if (!active) return;
            // Keep one current and one replacement request. Rapid actions
            // coalesce instead of creating an unbounded Promise/render queue.
            pendingRender = prepareRender();
            drainRender();
        }
        function drainRender() {
            if (!active || inFlight || !pendingRender) return;
            const request = pendingRender;
            pendingRender = undefined;
            inFlight = true;
            const desired = create(null);
            for (let i = 0; i < request.actions.length; i++) desired[request.actions[i]] = true;
            let work = resolved();
            const previous = ownKeys(registrations);
            const added = ownArray();
            for (let i = 0; i < request.actions.length; i++) {
                const actionID = request.actions[i];
                if (descriptor(registrations, actionID)) continue;
                work = chain(work, function() {
                    if (!active) return null;
                    return chain(nativeActionsOn(actionID, handleAction), function() {
                        registrations[actionID] = true;
                        added[added.length] = actionID;
                        return null;
                    });
                });
            }
            work = chain(work, function() {
                if (!active) return null;
                return sendRender(request.compact, request.expanded);
            });
            chain(work, function() {
                // An accepted Host render is the transaction boundary. Keep
                // old callbacks usable until the replacement is published;
                // rejecting a new layout must not break the still-visible UI.
                const retired = ownArray();
                for (let i = 0; i < previous.length; i++) {
                    if (!descriptor(desired, previous[i])) retired[retired.length] = previous[i];
                }
                chain(removeRegistrations(retired), function(cleanupFailed) {
                    inFlight = false;
                    if (cleanupFailed && active) reportFailure('rejection');
                    drainRender();
                });
            }, function(error) {
                // Newly registered IDs were never exposed in Activity data.
                // Roll them back while retaining the previous registration
                // set, then admit a later action/render that can recover.
                chain(removeRegistrations(added), function() {
                    inFlight = false;
                    failed(error);
                    drainRender();
                });
            });
        }
        function removeRegistrations(ids) {
            let work = resolved(), cleanupFailed = false;
            for (let i = 0; i < ids.length; i++) {
                const actionID = ids[i];
                work = chain(work, function() {
                    if (!active) return null;
                    return chain(nativeActionsOff(actionID), function() {
                        delete registrations[actionID];
                        return null;
                    }, function() {
                        // Continue releasing the rest. A failed removal stays
                        // in the bounded registration table for a later retry;
                        // Host Activity admission still blocks invisible IDs.
                        cleanupFailed = true;
                    });
                });
            }
            return chain(work, function() { return cleanupFailed; });
        }
        function registerModule(value) {
            if (arguments.length !== 1 || config || registering || didStart || didStop) throw INVALID;
            // Reflective Proxy traps are plugin code too. Reentrant
            // registration must not install a second module while the first
            // config's descriptors are being inspected.
            registering = true;
            try {
                const fields = dataFields(value, ['compact', 'expanded', 'onActivate', 'onDeactivate', 'onAction']);
                if (!descriptor(fields, 'compact')) throw INVALID;
                const keys = ownKeys(fields);
                for (let i = 0; i < keys.length; i++) {
                    const callback = fields[keys[i]];
                    // Async/generator functions are outside this synchronous
                    // subset; return checks also reject wrapped async callbacks.
                    if (typeof callback !== 'function' || prototype(callback) !== functionPrototype) throw INVALID;
                }
                config = freeze(fields);
            } finally {
                registering = false;
            }
        }
        function start() {
            if (!config || didStart || didStop) throw INVALID;
            didStart = true;
            active = true;
            if (config.onActivate) synchronous(config.onActivate, []);
            requestRender();
        }
        function stop() {
            if (didStop) return;
            didStop = true;
            active = false;
            pendingRender = undefined;
            if (didStart && config.onDeactivate) synchronous(config.onDeactivate, []);
        }
        function unsupported() { throw UNSUPPORTED; }
        function text(value, opts) {
            if (arguments.length < 1 || arguments.length > 2 || typeof value !== 'string') throw INVALID;
            const fields = options(opts, ['style', 'color', 'lineLimit']);
            const node = create(null); node.type = 'text'; node.value = value;
            node.style = fields.style === undefined ? 'body' : fields.style;
            if (fields.color !== undefined) node.color = fields.color;
            if (fields.lineLimit !== undefined) node.lineLimit = fields.lineLimit;
            return node;
        }
        function icon(name, opts) {
            if (arguments.length < 1 || arguments.length > 2 || typeof name !== 'string') throw INVALID;
            const fields = options(opts, ['size', 'color']);
            const node = create(null); node.type = 'icon'; node.name = name;
            node.size = fields.size === undefined ? 14 : fields.size;
            if (fields.color !== undefined) node.color = fields.color;
            return node;
        }
        function stack(type, children, opts, spacing) {
            const fields = options(opts, ['spacing', 'align', 'distribution']);
            if (children === undefined || children === null) children = ownArray();
            if (!isArray(children)) throw INVALID;
            const node = create(null); node.type = type; node.children = children;
            node.spacing = fields.spacing === undefined ? spacing : fields.spacing;
            if (fields.align !== undefined) node.align = fields.align;
            if (fields.distribution !== undefined) node.distribution = fields.distribution;
            return node;
        }
        function hstack(children, opts) {
            if (arguments.length > 2) throw INVALID;
            return stack('hstack', children, opts, 8);
        }
        function vstack(children, opts) {
            if (arguments.length > 2) throw INVALID;
            return stack('vstack', children, opts, 4);
        }
        function progress(value, opts) {
            if (arguments.length < 1 || arguments.length > 2 || typeof value !== 'number') throw INVALID;
            const fields = options(opts, ['total', 'color']);
            const node = create(null); node.type = 'progress'; node.value = value;
            node.total = fields.total === undefined ? 1 : fields.total;
            if (fields.color !== undefined) node.color = fields.color;
            return node;
        }
        function button(label, actionID) {
            if (arguments.length !== 2 || !validActionID(actionID)) throw INVALID;
            const node = create(null); node.type = 'button'; node.label = label; node.action = actionID;
            return node;
        }
        const view = create(null);
        view.text = freeze(text); view.icon = freeze(icon);
        view.hstack = freeze(hstack); view.vstack = freeze(vstack);
        view.progress = freeze(progress); view.button = freeze(button);
        const controls = create(null);
        controls.supported = false;
        controls.activate = freeze(unsupported); controls.dismiss = controls.activate;
        const superIsland = create(null);
        superIsland.registerModule = freeze(registerModule);
        superIsland.island = freeze(controls);
        const viewAttributes = create(null);
        viewAttributes.value = freeze(view); viewAttributes.enumerable = true;
        define(globalThis, 'View', viewAttributes);
        const moduleAttributes = create(null);
        moduleAttributes.value = freeze(superIsland); moduleAttributes.enumerable = true;
        define(globalThis, 'SuperIsland', moduleAttributes);
        const lifecycle = create(null);
        lifecycle.start = freeze(start); lifecycle.stop = freeze(stop);
        return freeze(lifecycle);
    })
    """
}
