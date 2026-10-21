/// <reference path="../../types/island.d.ts" />
'use strict';

const activityID = 'counter';
let count = 0;
let stopped = false;
let updating = false;

/** @param {number} value @returns {DynamicIsland.Presentation} */
function presentation(value) {
    return {
        role: 'tool', compactPolicy: 'selectedOnly', title: '你好，计数器',
        subtitle: '本次运行已点击 ' + String(value) + ' 次',
        symbolName: 'plus.circle', showsCompact: false,
        minimal: {type: 'icon', symbolName: 'plus.circle'},
        compact: {type: 'hStack', children: [
            {type: 'icon', symbolName: 'plus.circle'}, {type: 'spacer'},
            {type: 'text', content: String(value)}
        ]},
        expanded: {type: 'vStack', children: [
            {type: 'text', content: '已点击 ' + String(value) + ' 次'},
            {type: 'button', actionID: 'increment', accessibilityLabel: '增加一次',
                label: {type: 'text', content: '加一'}}
        ]}
    };
}

/** @param {DynamicIsland.ActionEvent} event @returns {void | Promise<unknown>} */
function increment(event) {
    if (stopped || updating || event.activityID !== activityID || event.value.type !== 'none') return;
    updating = true;
    const next = count + 1;
    return island.activity.update({id: activityID, presentation: presentation(next)}).then(() => {
        if (!stopped) count = next;
    }, () => {
        if (!stopped) return island.log('Counter update failed', 'warning').catch(() => {});
    }).then(() => { updating = false; });
}

/**
 * Lifecycle hooks return synchronously. Host work is fire-and-catch; do not
 * make this function async or return the initialization Promise.
 * @returns {undefined}
 */
function onStart() {
    island.actions.on('increment', increment).then(() => {
        if (stopped) return null;
        return island.activity.publish({
            id: activityID, lifecycle: {policy: 'persistent'}, presentation: presentation(count),
            actions: [{id: 'increment', title: '加一'}]
        });
    }).catch(() => {
        if (!stopped) island.log('Counter initialization failed', 'error').catch(() => {});
    });
    return undefined;
}

/** @returns {undefined} */
function onStop() {
    // Host has already revoked this execution and removes its UI/handlers.
    stopped = true;
    return undefined;
}
