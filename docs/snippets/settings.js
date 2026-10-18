/// <reference path="../../types/island.d.ts" />
'use strict';

/**
 * Storage is untrusted data. Accept only this version's exact shape.
 * @param {DynamicIsland.HostJSONValue} value
 * @returns {15 | 25 | 45 | 60}
 */
function parseMinutes(value) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return 25;
    const keys = Object.keys(value);
    if (keys.length !== 2 || !keys.includes('schemaVersion') || !keys.includes('minutes')) return 25;
    const record = /** @type {DynamicIsland.HostJSONObject} */ (value);
    if (record.schemaVersion !== 1) return 25;
    const minutes = record.minutes;
    return minutes === 15 || minutes === 25 || minutes === 45 || minutes === 60 ? minutes : 25;
}

/** @returns {Promise<15 | 25 | 45 | 60>} */
function loadMinutes() {
    return island.storage.get('preferences').then(parseMinutes, () => /** @type {25} */ (25));
}

/** @param {15 | 25 | 45 | 60} minutes @returns {Promise<boolean>} */
function saveMinutes(minutes) {
    // TypeScript types do not replace validation of runtime input.
    if (minutes !== 15 && minutes !== 25 && minutes !== 45 && minutes !== 60) return Promise.resolve(false);
    return island.storage.set('preferences', {schemaVersion: 1, minutes: minutes})
        .then(() => true, () => false);
}
