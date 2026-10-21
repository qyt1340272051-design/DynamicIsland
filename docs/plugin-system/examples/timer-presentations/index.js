'use strict';

const activityID = 'timer';
const durationMs = 300000;
const compactDelayMs = 30000;
let timer = null;
let stage = 'idle';
let published = false;
let stopped = false;
let handlingAction = false;
let refreshPending = false;
let run = 0;
let hint = '';
let work = Promise.resolve();

function text(content) { return {type: 'text', content}; }
function button(actionID, title) {
    return {type: 'button', actionID, label: text(title), accessibilityLabel: title};
}
function countdown(style) {
    return {type: 'countdown', id: timer.id, generation: timer.generation, style, color: 'accent'};
}

function presentation() {
    const running = timer !== null && timer.state === 'running';
    const state = timer === null ? '等待开始' : running ? '计时中' : '已完成';
    const controls = [];
    if (timer === null && !refreshPending) controls.push(button('start', '开始三态验收'));
    if (timer !== null) controls.push(button('stop', '结束验收'));
    const value = {
        role: 'tool', compactPolicy: 'automatic', title: '计时三态验收',
        subtitle: stage + ' · ' + state, symbolName: 'timer', showsCompact: running,
        minimal: timer ? countdown('time') : {type: 'icon', symbolName: 'timer'},
        expanded: {type: 'vStack', children: [
            text('三态计时 · ' + stage + ' · ' + state),
            text(hint || (refreshPending ? 'Host 刷新后切换 compact' : '使用同一个计时记录')),
            timer ? countdown('time') : text('05:00'),
            timer ? countdown('progress') : {type: 'progress', value: 0},
            controls.length > 0 ? {type: 'hStack', children: controls} : text('等待已申请的刷新结束')
        ]}
    };
    // During minimal there is deliberately no compact tree. Host policy must
    // choose the single time leaf and place it outside the physical camera.
    if (stage === 'compact') {
        value.compact = {type: 'hStack', children: [
            {type: 'icon', symbolName: 'timer'}, {type: 'spacer'}, countdown('time')
        ]};
    }
    return value;
}

function render() {
    return stopped || !published ? Promise.resolve() :
        island.activity.update({id: activityID, presentation: presentation()});
}

function warn() {
    if (!stopped) return island.log('Timer presentation acceptance failed', 'warning').catch(() => {});
}

function scheduleCompact(expectedRun, expectedGeneration) {
    refreshPending = true;
    // One Host request for this run. No JS interval, recursive reschedule,
    // simulated clock, storage, or permission is involved.
    island.scheduler.requestRefresh(compactDelayMs).then(receipt => {
        const result = work.then(() => island.countdown.get(activityID)).then(current => {
            refreshPending = false;
            if (stopped) return;
            if (expectedRun !== run || timer === null) return render();
            if (!current || current.generation !== expectedGeneration || current.state !== 'running') return;
            timer = current;
            stage = 'compact';
            hint = 'Host 刷新策略：' + receipt.policy;
            return render();
        });
        work = result.catch(warn);
        return work;
    }).catch(() => {
        refreshPending = false;
        if (stopped) return;
        if (expectedRun === run) hint = 'Host 刷新未完成，请结束后重试';
        const result = work.then(render);
        work = result.catch(warn);
    });
}

function action(command) {
    return event => {
        if (stopped || handlingAction || event.activityID !== activityID || event.value.type !== 'none') return;
        handlingAction = true;
        const result = work.then(() => command(event));
        work = result.catch(warn).then(() => { handlingAction = false; });
        return work;
    };
}

function start(event) {
    if (timer !== null || refreshPending) return;
    return island.countdown.start({id: activityID, durationMs, activation: event.activation}).then(value => {
        if (stopped) return;
        timer = value;
        stage = 'minimal';
        hint = '';
        const expectedRun = ++run;
        scheduleCompact(expectedRun, value.generation);
        return render();
    });
}

function stop() {
    const current = timer;
    run += 1;
    return (current ? island.countdown.stop({id: activityID, generation: current.generation}) :
        Promise.resolve(null)).then(() => {
        timer = null;
        stage = 'idle';
        hint = '';
        return render();
    });
}

function onStart() {
    work = Promise.all([
        island.actions.on('start', action(start)),
        island.actions.on('stop', action(stop)),
        island.countdown.onComplete(value => {
            if (stopped || value.id !== activityID) return;
            const result = work.then(() => island.countdown.get(activityID)).then(current => {
                if (stopped || !current || current.generation !== value.generation || current.state !== 'completed') return;
                timer = current;
                return render();
            });
            work = result.catch(warn);
            return work;
        })
    ]).then(() => {
        if (stopped) return;
        return island.activity.publish({
            id: activityID, priority: 'background', lifecycle: {policy: 'persistent'},
            presentation: presentation(),
            actions: [{id: 'start', title: '开始三态验收'}, {id: 'stop', title: '结束验收'}]
        });
    }).then(() => { published = !stopped; }).catch(warn);
}

function onStop() {
    stopped = true;
    run += 1;
}
