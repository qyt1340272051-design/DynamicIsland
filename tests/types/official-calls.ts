// Compile-only contracts for the two official examples. This is independently
// written call coverage, not a copy of their implementation or a runtime test.
export {};

const tool: DynamicIsland.Presentation = {
    role: 'tool', compactPolicy: 'automatic', title: 'Official call fixture',
    subtitle: 'No automatic expansion', symbolName: 'timer', showsCompact: false,
    minimal: {type: 'icon', symbolName: 'timer'},
    compact: {type: 'hStack', children: [
        {type: 'icon', symbolName: 'timer'}, {type: 'spacer'}, {type: 'text', content: 'Ready'}
    ]},
    expanded: {type: 'vStack', children: [
        {type: 'text', content: 'Choose a tool', color: 'secondary'},
        {type: 'progress', value: 0, style: 'linear', color: 'accent'},
        {type: 'button', actionID: 'start', label: {type: 'text', content: 'Start'}, accessibilityLabel: 'Start session'}
    ]}
};

const initial: Promise<DynamicIsland.ActivityReceipt> = island.activity.publish({
    id: 'session', priority: 'background', lifecycle: {policy: 'persistent'}, presentation: tool,
    actions: [{id: 'start', title: 'Start'}]
});
const update: Promise<DynamicIsland.ActivityReceipt> = island.activity.update({id: 'session', presentation: tool});
const ended: Promise<null> = island.activity.end('completion');
const logged: Promise<null> = island.log('Fixed failure category', 'warning');
void [initial, update, ended, logged];

const status: DynamicIsland.ActivityPublish = {
    id: 'completion', priority: 'normal', lifecycle: {policy: 'transient'},
    presentation: {
        title: 'Completed', symbolName: 'checkmark.circle.fill',
        compact: {type: 'hStack', children: [
            {type: 'icon', symbolName: 'checkmark.circle.fill'}, {type: 'spacer'}, {type: 'text', content: 'Done'}
        ]}
    }
};
void island.activity.publish(status);

// Pomodoro-style genuine action tickets, generation references and completion.
void island.actions.on('start', event => {
    if (event.activityID !== 'session' || event.value.type !== 'none' || event.activation === undefined) return;
    return island.countdown.start({id: 'session', durationMs: 15 * 60 * 1000, activation: event.activation}).then(timer => {
        const time: DynamicIsland.CountdownNode = {type: 'countdown', id: timer.id, generation: timer.generation, style: 'time'};
        const progress: DynamicIsland.CountdownNode = {...time, style: 'progress', color: 'accent'};
        return island.activity.update({id: 'session', presentation: {role: 'tool', title: 'Running', compact: time, expanded: progress}});
    });
});
void island.countdown.get('session').then(timer => {
    if (timer === null) return;
    const paused: Promise<DynamicIsland.CountdownSnapshot> = island.countdown.pause({id: timer.id, generation: timer.generation});
    const stopped: Promise<null> = island.countdown.stop({id: timer.id, generation: timer.generation});
    void [paused, stopped];
});
void island.actions.on('resume', event => {
    const activation = event.activation;
    if (activation === undefined) return;
    return island.countdown.get('session').then(timer => {
        if (timer === null) return null;
        return island.countdown.resume({id: timer.id, generation: timer.generation, activation});
    });
});
const completionRegistration: Promise<null> = island.countdown.onComplete(event => {
    const completed: 'completed' = event.state;
    const zero: 0 = event.remainingMs;
    void [completed, zero];
    return island.countdown.get(event.id).then(current => {
        if (current && current.generation === event.generation) return island.activity.publish(status);
        return null;
    });
});
void completionRegistration;

// GitHub-style stored settings. Incoming arrays are indexed, never .map'd.
void island.storage.set('settings', {schemaVersion: 1, repository: 'cli/cli', notifiedResults: [null, '42.1']});
function isHostArray(value: DynamicIsland.HostJSONValue): value is DynamicIsland.HostJSONArray {
    return value !== null && typeof value === 'object' && Array.isArray(value);
}
void island.storage.get('settings').then(value => {
    if (isHostArray(value)) {
        for (let index = 0; index < value.length; index++) {
            const item: DynamicIsland.HostJSONValue | undefined = value[index];
            void item;
        }
    }
});

void island.network.fetch('https://api.github.com/repos/cli/cli/actions/runs', {
    method: 'GET', timeoutMs: 10000,
    headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'SDK-Compile-Fixture'}
}).then(response => {
    const statusCode: number = response.status;
    const success: boolean = response.ok;
    const remaining: string | undefined = response.headers['x-ratelimit-remaining'];
    const json: Promise<DynamicIsland.HostJSONValue> = response.json();
    const text: Promise<string> = response.text();
    void [statusCode, success, remaining, json, text];
});
void island.actions.on('open.build', event => {
    if (event.value.type !== 'none' || event.activation === undefined) return;
    return island.links.open({url: 'https://github.com/cli/cli/actions', activation: event.activation});
});
void island.scheduler.requestRefresh(300000).then(receipt => {
    const policy: DynamicIsland.SchedulerPolicy = receipt.policy;
    void policy;
});

const hooks: DynamicIsland.LifecycleContract = {
    onStart: () => {
        void island.log('Initialization starts').catch(() => {});
        return undefined;
    },
    onStop: () => undefined
};
void hooks;
