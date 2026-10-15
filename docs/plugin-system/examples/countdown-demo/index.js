'use strict';

const clockID = 'clock';
let timer = null;
let published = false;
let handlingAction = false;
let work = Promise.resolve();

function countdownNode(style) {
    return {type: 'countdown', id: timer.id, generation: timer.generation, style, color: 'accent'};
}

function button(actionID, title) {
    return {type: 'button', actionID, label: {type: 'text', content: title}, accessibilityLabel: title};
}

function presentation() {
    const status = timer === null ? '等待开始' :
        timer.state === 'running' ? '进行中' : timer.state === 'paused' ? '已暂停' : '已完成';
    return {
        role: 'tool', title: '10 秒倒计时', subtitle: status, symbolName: 'timer', showsCompact: false,
        minimal: timer ? countdownNode('time') : {type: 'icon', symbolName: 'timer'},
        compact: {type: 'hStack', children: [
            {type: 'icon', symbolName: 'timer'},
            timer ? countdownNode('time') : {type: 'text', content: '10 秒'}
        ]},
        expanded: {type: 'vStack', children: [
            {type: 'text', content: status},
            timer ? countdownNode('time') : {type: 'text', content: '00:10'},
            timer ? countdownNode('progress') : {type: 'progress', value: 0},
            {type: 'hStack', children: [
                button('start', '开始'), button('pause', '暂停'), button('resume', '继续'), button('stop', '结束')
            ]}
        ]}
    };
}

function render() {
    if (!published) return Promise.resolve();
    return island.activity.update({id: clockID, presentation: presentation()});
}

function remember(value) {
    timer = value;
    return render();
}

function action(command) {
    return event => {
        if (event.activityID !== clockID || event.value.type !== 'none' || handlingAction) return;
        handlingAction = true;
        return command(event).then(value => {
            handlingAction = false;
            return remember(value);
        }).catch(() => {
            handlingAction = false;
            return island.log('Countdown demo action failed', 'warning').catch(() => {});
        });
    };
}

function onStart() {
    work = Promise.all([
        island.actions.on('start', action(event => island.countdown.start({
            id: clockID, durationMs: 10000, activation: event.activation
        }))),
        island.actions.on('pause', action(() => timer && timer.state === 'running'
            ? island.countdown.pause({id: clockID, generation: timer.generation})
            : island.countdown.get(clockID))),
        island.actions.on('resume', action(event => timer && timer.state === 'paused'
            ? island.countdown.resume({id: clockID, generation: timer.generation, activation: event.activation})
            : island.countdown.get(clockID))),
        island.actions.on('stop', action(() => timer
            ? island.countdown.stop({id: clockID, generation: timer.generation}).then(() => null)
            : Promise.resolve(null))),
        island.countdown.onComplete(value => {
            if (value.id !== clockID) return;
            // A deadline can fire while a pause/resume response is in flight.
            // Read the current Host record after that command has settled.
            const result = work.then(() => island.countdown.get(clockID)).then(current => {
                if (current && current.generation === value.generation && current.state === 'completed') {
                    return remember(current);
                }
            });
            work = result.catch(() => island.log('Countdown demo completion failed', 'warning'));
            return work;
        })
    ]).then(() => island.countdown.get(clockID)).then(value => {
        timer = value;
        return island.activity.publish({
            id: clockID, lifecycle: {policy: 'persistent'}, presentation: presentation(),
            actions: [
                {id: 'start', title: '开始'}, {id: 'pause', title: '暂停'},
                {id: 'resume', title: '继续'}, {id: 'stop', title: '结束'}
            ]
        });
    }).then(() => {
        published = true;
        // A Host completion can arrive while the initial publish is in flight.
        return render();
    }).catch(() => { island.log('Countdown demo initialization failed', 'error').catch(() => {}); });
}

function onStop() {}
