'use strict';

const sessionID = 'session';
const completionID = 'completion';
const presets = [15, 25, 45, 60];
let selectedMinutes = 25;
let timer = null;
let published = false;
let handlingAction = false;
let notifiedGeneration = null;
let work = Promise.resolve();

function button(actionID, title, selected) {
    return {
        type: 'button', actionID,
        label: {type: 'text', content: title, color: selected ? 'accent' : 'primary'},
        accessibilityLabel: title + (selected ? '，当前预设' : '')
    };
}

function countdownNode(style) {
    return {type: 'countdown', id: timer.id, generation: timer.generation, style, color: 'accent'};
}

function presentation() {
    const status = timer === null ? '准备专注' : timer.state === 'running' ? '专注中' :
        timer.state === 'paused' ? '已暂停' : '本轮已完成';
    const primary = timer && timer.state === 'running' ? button('pause', '暂停', false) :
        timer && timer.state === 'paused' ? button('resume', '继续', false) : button('start', '开始', false);
    const idleTime = String(selectedMinutes).padStart(2, '0') + ':00';
    return {
        role: 'tool', compactPolicy: 'automatic', title: '番茄钟',
        subtitle: String(selectedMinutes) + ' 分钟 · ' + status, symbolName: 'timer',
        showsCompact: timer !== null && (timer.state === 'running' || timer.state === 'paused'),
        minimal: timer ? countdownNode('time') : {type: 'icon', symbolName: 'timer'},
        compact: {type: 'hStack', children: [
            {type: 'icon', symbolName: 'timer'}, {type: 'spacer'},
            timer ? countdownNode('time') : {type: 'text', content: idleTime}
        ]},
        expanded: {type: 'vStack', children: [
            {type: 'text', content: String(selectedMinutes) + ' 分钟 · ' + status},
            timer ? countdownNode('time') : {type: 'text', content: idleTime},
            timer ? countdownNode('progress') : {type: 'progress', value: 0},
            {type: 'hStack', children: presets.map(minutes =>
                button('preset.' + String(minutes), String(minutes) + ' 分钟', minutes === selectedMinutes))},
            {type: 'hStack', children: [primary, button('stop', '结束', false)]}
        ]}
    };
}

function render() {
    if (!published) return Promise.resolve();
    return island.activity.update({id: sessionID, presentation: presentation()});
}

function remember(value) {
    timer = value;
    if (value !== null) {
        const minutes = value.durationMs / 60000;
        if (presets.indexOf(minutes) !== -1) selectedMinutes = minutes;
    }
    return render();
}

function clearCompletion() {
    return island.activity.end(completionID).catch(error => {
        if (error.code !== 'activityNotFound') throw error;
    });
}

function clearCompletionKeeping(value) {
    return clearCompletion().then(() => value);
}

function action(command, presetAction) {
    return event => {
        if (event.activityID !== sessionID || event.value.type !== 'none' || handlingAction ||
            (presetAction && timer && timer.state === 'running')) return;
        handlingAction = true;
        const result = work.then(() => command(event)).then(value => {
            handlingAction = false;
            return remember(value);
        });
        work = result.catch(() => {
            handlingAction = false;
            // A Host command may succeed before a subsequent Activity write
            // fails. Recover its authoritative state without starting a timer.
            return island.countdown.get(sessionID).then(remember).catch(() => {}).then(() =>
                island.log('Pomodoro action failed', 'warning').catch(() => {}));
        });
        return work;
    };
}

function choosePreset(minutes) {
    if (timer && timer.state === 'running') return Promise.resolve(timer);
    const stopped = timer ? island.countdown.stop({id: sessionID, generation: timer.generation}) : Promise.resolve();
    return stopped.then(() => {
        selectedMinutes = minutes;
        return clearCompletion();
    }).then(() => null);
}

function complete(value) {
    if (value.id !== sessionID) return;
    const result = work.then(() => island.countdown.get(sessionID)).then(current => {
        if (!current || current.generation !== value.generation || current.state !== 'completed') return;
        const shouldNotify = notifiedGeneration !== current.generation;
        if (shouldNotify) notifiedGeneration = current.generation;
        return remember(current).then(() => {
            if (!shouldNotify) return;
            return island.activity.publish({
                id: completionID, priority: 'normal', lifecycle: {policy: 'transient'},
                presentation: {title: '专注完成', subtitle: '本轮专注已结束', symbolName: 'checkmark.circle.fill'}
            });
        });
    });
    work = result.catch(() => island.log('Pomodoro completion failed', 'warning').catch(() => {}));
    return work;
}

function onStart() {
    const registrations = [
        island.actions.on('start', action(event => island.countdown.start({
            id: sessionID, durationMs: selectedMinutes * 60000, activation: event.activation
        }).then(clearCompletionKeeping))),
        island.actions.on('pause', action(() => timer && timer.state === 'running'
            ? island.countdown.pause({id: sessionID, generation: timer.generation}).then(clearCompletionKeeping)
            : Promise.resolve(timer))),
        island.actions.on('resume', action(event => timer && timer.state === 'paused'
            ? island.countdown.resume({id: sessionID, generation: timer.generation, activation: event.activation})
                .then(clearCompletionKeeping)
            : Promise.resolve(timer))),
        island.actions.on('stop', action(() => {
            const stopped = timer ? island.countdown.stop({id: sessionID, generation: timer.generation}) : Promise.resolve();
            return stopped.then(clearCompletion).then(() => null);
        })),
        island.countdown.onComplete(complete)
    ];
    for (const minutes of presets) {
        registrations.push(island.actions.on('preset.' + String(minutes), action(() => choosePreset(minutes), true)));
    }
    work = Promise.all(registrations).then(() => island.countdown.get(sessionID)).then(value => {
        timer = value;
        if (value !== null && presets.indexOf(value.durationMs / 60000) !== -1) selectedMinutes = value.durationMs / 60000;
        return island.activity.publish({
            id: sessionID, lifecycle: {policy: 'persistent'}, presentation: presentation(),
            actions: [
                {id: 'start', title: '开始'}, {id: 'pause', title: '暂停'},
                {id: 'resume', title: '继续'}, {id: 'stop', title: '结束'},
                {id: 'preset.15', title: '15 分钟'}, {id: 'preset.25', title: '25 分钟'},
                {id: 'preset.45', title: '45 分钟'}, {id: 'preset.60', title: '60 分钟'}
            ]
        });
    }).then(() => {
        published = true;
        return render();
    }).catch(() => { island.log('Pomodoro initialization failed', 'error').catch(() => {}); });
}

function onStop() {}
