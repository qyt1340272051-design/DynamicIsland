'use strict';

const actionMockState = {running: true, enabled: false, progress: 0.1};

function actionMockPresentation() {
    const title = actionMockState.running ? '正在运行' : '已暂停';
    return {
        title,
        symbolName: 'playpause.fill',
        progress: actionMockState.progress,
        minimal: {type: 'icon', symbolName: 'playpause.fill'},
        compact: {type: 'text', content: title},
        expanded: {type: 'vStack', children: [
            {type: 'text', content: title},
            {type: 'button', actionID: 'pause', label: {type: 'text', content: '暂停 / 继续'}, accessibilityLabel: '暂停 / 继续'},
            {type: 'toggle', actionID: 'enabled', title: '启用示例', isOn: actionMockState.enabled},
            {type: 'slider', actionID: 'progress', title: '示例进度', value: actionMockState.progress}
        ]}
    };
}

function actionMockUpdate(message) {
    return island.activity.update({id: 'controls', presentation: actionMockPresentation()})
        .then(() => island.log(message));
}

function onStart() {
    Promise.all([
        island.actions.on('pause', event => {
            if (event.activityID !== 'controls' || event.value.type !== 'none') return;
            actionMockState.running = !actionMockState.running;
            return actionMockUpdate('action.pause');
        }),
        island.actions.on('enabled', event => {
            if (event.activityID !== 'controls' || event.value.type !== 'toggle') return;
            actionMockState.enabled = event.value.value;
            return actionMockUpdate('action.toggle');
        }),
        island.actions.on('progress', event => {
            if (event.activityID !== 'controls' ||
                (event.value.type !== 'slider' && event.value.type !== 'sliderCommit')) return;
            actionMockState.progress = event.value.value;
            return actionMockUpdate('action.' + event.value.type);
        })
    ]).then(() => island.activity.publish({
        id: 'controls', lifecycle: {policy: 'persistent'},
        presentation: actionMockPresentation(),
        actions: [
            {id: 'pause', title: '暂停 / 继续'},
            {id: 'enabled', title: '启用示例'},
            {id: 'progress', title: '示例进度'}
        ]
    })).then(() => island.log('action.ready')).catch(error => {
        island.log('action.error:' + error.code, 'error').catch(() => {});
    });
}

function onStop() {}
