/// <reference path="../../types/island.d.ts" />
'use strict';

/** @returns {Promise<DynamicIsland.ActivityReceipt>} */
function publishReading() {
    return island.activity.publish({
        id: 'reading', lifecycle: {policy: 'persistent'},
        presentation: {role: 'tool', title: '读数', showsCompact: false,
            expanded: {type: 'text', content: '等待更新'}}
    });
}

/** @param {number} value @returns {Promise<DynamicIsland.ActivityReceipt>} */
function updateReading(value) {
    if (!Number.isFinite(value) || value < 0 || value > 1) {
        return Promise.reject({code: 'invalidReading', message: 'Expected 0...1.'});
    }
    return island.activity.update({id: 'reading', presentation: {
        role: 'tool', title: '读数', showsCompact: false,
        expanded: {type: 'progress', value: value, color: 'accent'}
    }});
}

/** @returns {Promise<null>} */
function endReading() {
    return island.activity.end('reading');
}
