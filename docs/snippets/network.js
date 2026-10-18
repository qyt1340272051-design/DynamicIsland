/// <reference path="../../types/island.d.ts" />
'use strict';

/** @returns {Promise<number>} */
function readGitHubStars() {
    return island.network.fetch('https://api.github.com/repos/cli/cli', {
        method: 'GET', headers: {Accept: 'application/vnd.github+json'}, timeoutMs: 10000
    }).then(response => {
        if (!response.ok) throw {code: 'httpStatus', message: 'GitHub returned an unsuccessful status.'};
        return response.json();
    }).then(value => {
        if (value === null || typeof value !== 'object' || Array.isArray(value)) {
            throw {code: 'invalidData', message: 'Expected a repository record.'};
        }
        const record = /** @type {DynamicIsland.HostJSONObject} */ (value);
        const stars = record.stargazers_count;
        if (typeof stars !== 'number' || !Number.isSafeInteger(stars) || stars < 0) {
            throw {code: 'invalidData', message: 'Expected a nonnegative star count.'};
        }
        return stars;
    });
}
