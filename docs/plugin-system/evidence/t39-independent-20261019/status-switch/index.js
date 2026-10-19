/// <reference path="../../dynamic-island-sdk-1.0.0-walkthrough-20261019/DynamicIslandSDK/types/island.d.ts" />
'use strict';

const activityID = 'status-switch';
let currentStatus = '待选择';
let stopped = false;
let updating = false;

/** @param {string} status @returns {DynamicIsland.Presentation} */
function presentation(status) {
    return {
        role: 'tool',
        compactPolicy: 'selectedOnly',
        title: '双按钮状态',
        subtitle: '状态仅保存在本次运行中',
        showsCompact: false,
        expanded: {
            type: 'vStack',
            children: [
                {type: 'text', content: '当前状态：' + status},
                {type: 'hStack', children: [
                    {type: 'button', actionID: 'focus', accessibilityLabel: '切换到专注状态',
                        label: {type: 'text', content: '专注'}},
                    {type: 'button', actionID: 'rest', accessibilityLabel: '切换到休息状态',
                        label: {type: 'text', content: '休息'}}
                ]}
            ]
        }
    };
}

/**
 * @param {DynamicIsland.ActionEvent} event
 * @param {string} expectedAction
 * @param {string} nextStatus
 * @returns {void | Promise<unknown>}
 */
function chooseStatus(event, expectedAction, nextStatus) {
    if (stopped || updating || event.activityID !== activityID ||
        event.actionID !== expectedAction || event.value.type !== 'none') return;
    updating = true;
    return island.activity.update({id: activityID, presentation: presentation(nextStatus)}).then(() => {
        if (!stopped) currentStatus = nextStatus;
    }, () => {
        // Keep the previously acknowledged state if the Host rejects the update.
        // No resource access or automatic retry is needed for this memory-only tool.
    }).then(() => { updating = false; });
}

/** @param {DynamicIsland.ActionEvent} event @returns {void | Promise<unknown>} */
function chooseFocus(event) {
    return chooseStatus(event, 'focus', '专注中');
}

/** @param {DynamicIsland.ActionEvent} event @returns {void | Promise<unknown>} */
function chooseRest(event) {
    return chooseStatus(event, 'rest', '休息中');
}

/** @returns {undefined} */
function onStart() {
    island.actions.on('focus', chooseFocus).then(() => {
        if (stopped) return null;
        return island.actions.on('rest', chooseRest);
    }).then(() => {
        if (stopped) return null;
        return island.activity.publish({
            id: activityID,
            lifecycle: {policy: 'persistent'},
            presentation: presentation(currentStatus),
            actions: [{id: 'focus', title: '专注'}, {id: 'rest', title: '休息'}]
        });
    }).catch(() => {
        // Initialization failures are handled; inspect the Host diagnostics.
    });
    return undefined;
}

/** @returns {undefined} */
function onStop() {
    stopped = true;
    return undefined;
}
