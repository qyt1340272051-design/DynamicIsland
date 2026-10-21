/// <reference path="../../types/island.d.ts" />
'use strict';

/** @param {DynamicIsland.ActionEvent} event @returns {Promise<null>} */
function openGitHubRepository(event) {
    if (!event.activation) return Promise.resolve(null);
    // Submit the activation immediately; do not await storage or a fetch first.
    return island.links.open({url: 'https://github.com/cli/cli', activation: event.activation});
}
