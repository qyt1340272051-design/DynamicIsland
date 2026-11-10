// Every expected error protects a deliberate SDK boundary. tsc must reject
// each statement; an unused @ts-expect-error fails the type test.
export {};

// @ts-expect-error Lifecycle start hooks cannot return a Promise.
const asyncStart: DynamicIsland.LifecycleHook = async () => undefined;
// @ts-expect-error Lifecycle stop hooks cannot return a Promise.
const asyncStop: DynamicIsland.LifecycleContract = {onStart: () => undefined, onStop: async () => undefined};
// @ts-expect-error A synchronous hook must return undefined, not arbitrary data.
const resultStart: DynamicIsland.LifecycleHook = () => 1;
void [asyncStart, asyncStop, resultStart];

// @ts-expect-error Host calls return Promises, not immediate receipts.
const synchronousReceipt: DynamicIsland.ActivityReceipt = island.activity.publish({id: 'tool', presentation: {title: 'Tool'}});
// @ts-expect-error publish requires presentation.
void island.activity.publish({id: 'tool'});
// @ts-expect-error update requires at least one patch field.
void island.activity.update({id: 'tool'});
// @ts-expect-error A presentation replacement still requires title.
void island.activity.update({id: 'tool', presentation: {subtitle: 'Partial nested patch'}});
// @ts-expect-error No native objects or custom priority contract in this subset.
void island.activity.publish({id: 'tool', priority: 'critical', presentation: {title: 'Tool'}});
// @ts-expect-error compactPolicy is valid only for a tool presentation.
const invalidPolicy: DynamicIsland.Presentation = {title: 'Status', role: 'status', compactPolicy: 'automatic'};
void [synchronousReceipt, invalidPolicy];

// @ts-expect-error Native node uses content, not SuperIsland value.
const oldText: DynamicIsland.Node = {type: 'text', value: 'Wrong protocol'};
// @ts-expect-error No raw native views.
const nativeView: DynamicIsland.Node = {type: 'NSView'};
// @ts-expect-error Color is a finite semantic token, not CSS.
const cssColor: DynamicIsland.Node = {type: 'text', content: 'Hello', color: '#00ff00'};
// @ts-expect-error Layout dimensions are not plugin controlled.
const dimensions: DynamicIsland.Node = {type: 'icon', symbolName: 'star', width: 100};
// @ts-expect-error No arbitrary stack spacing field.
const spacing: DynamicIsland.Node = {type: 'hStack', children: [], spacing: 42};
// @ts-expect-error SDK subset intentionally excludes image assets.
const image: DynamicIsland.Node = {type: 'image', source: {type: 'pluginAsset', id: 'cover'}};
// @ts-expect-error SDK subset intentionally excludes toggles and sliders.
const slider: DynamicIsland.Node = {type: 'slider', actionID: 'drag', title: 'Value', value: 0.5};
// @ts-expect-error Button requires a node label.
const textButton: DynamicIsland.Node = {type: 'button', actionID: 'go', label: 'Go'};
// @ts-expect-error Generation must come from a Host countdown result.
const inventedTimer: DynamicIsland.Node = {type: 'countdown', id: 'timer', generation: 'fabricated'};
void [oldText, nativeView, cssColor, dimensions, spacing, image, slider, textButton, inventedTimer];

// @ts-expect-error A string cannot fabricate a Host activation ticket.
const forgedActivation: DynamicIsland.UserActivation = 'ticket';
// @ts-expect-error Countdown start requires a fresh action ticket.
void island.countdown.start({id: 'timer', durationMs: 15000});
// @ts-expect-error Generic strings cannot mint activation tickets.
void island.links.open({url: 'https://github.com', activation: 'ticket'});
void island.actions.on('start', event => {
    // @ts-expect-error An action may not contain activation; first narrow it.
    return island.countdown.start({id: 'timer', durationMs: 15000, activation: event.activation});
});
void island.countdown.get('timer').then(timer => {
    if (timer === null) return;
    // @ts-expect-error Countdown resume also requires a fresh ticket.
    void island.countdown.resume({id: timer.id, generation: timer.generation});
});
void forgedActivation;

// @ts-expect-error Storage accepts JSON, not undefined.
void island.storage.set('settings', undefined);
// @ts-expect-error Storage accepts data, not a callback.
void island.storage.set('settings', {compute: () => 1});
declare const incoming: DynamicIsland.HostJSONArray;
// @ts-expect-error Incoming null-prototype arrays do not provide map.
incoming.map((value: DynamicIsland.HostJSONValue) => value);
// @ts-expect-error Incoming null-prototype arrays do not provide slice.
incoming.slice();
// @ts-expect-error Incoming null-prototype arrays have no Symbol.iterator.
const spread = [...incoming];
// @ts-expect-error Incoming arrays must be treated as readonly snapshots.
incoming[0] = 'overwrite';
void spread;

// @ts-expect-error Native network currently supports only GET/HEAD.
void island.network.fetch('https://api.github.com', {method: 'POST'});
// @ts-expect-error No request body in this public subset.
void island.network.fetch('https://api.github.com', {body: '{}'});
// @ts-expect-error Timeout is measured as a numeric millisecond count.
void island.network.fetch('https://api.github.com', {timeoutMs: '1000'});
void island.network.fetch('https://api.github.com').then(response => {
    // @ts-expect-error Network response exposes text()/json(), not body.
    void response.body;
    // @ts-expect-error json() cannot assert an unvalidated caller-selected schema.
    void response.json<{id: number}>();
});

// @ts-expect-error No SuperIsland API in the Native SDK.
SuperIsland.registerModule({});
// @ts-expect-error No unmediated or invented presentation entry point.
island.activity.requestPresentation('tool');
// @ts-expect-error Private compatibility endpoints are absent.
island.superisland.render({});
// @ts-expect-error Clipboard is outside this deliberately small SDK.
island.clipboard.readText();
// @ts-expect-error File selection is outside this SDK.
island.files.chooseText();
// @ts-expect-error Notifications are not implemented in this SDK.
island.notifications.publish({});
// @ts-expect-error Calendar is not implemented in this SDK.
island.calendar.read();
// @ts-expect-error Not exercised by the two official packages; outside the authoring subset.
island.actions.off('start');
// @ts-expect-error Not exercised by the two official packages; outside the authoring subset.
island.countdown.offComplete();
// @ts-expect-error Not exercised by the two official packages; outside the authoring subset.
island.storage.remove('settings');
// @ts-expect-error Not exercised by the two official packages; outside the authoring subset.
island.storage.clear();
// @ts-expect-error Metadata is immutable and cannot select plugin identity.
island.plugin.id = 'com.example.someone-else';

// @ts-expect-error Typography is a finite semantic token, not a point size.
const arbitraryFont: DynamicIsland.TextNode = {type: 'text', content: '25:00', font: '26pt'};
// @ts-expect-error Numeric font sizes are outside the node contract.
const numericFont: DynamicIsland.TextNode = {type: 'text', content: '25:00', font: 26};
// @ts-expect-error Null is not an omitted font.
const nullFont: DynamicIsland.TextNode = {type: 'text', content: '25:00', font: null};
// @ts-expect-error Button style is a finite Host token.
const arbitraryButtonStyle: DynamicIsland.ButtonNode = {type: 'button', actionID: 'go', label: {type: 'spacer'}, style: 'filled'};
// @ts-expect-error Button color remains semantic, not CSS.
const arbitraryButtonColor: DynamicIsland.ButtonNode = {type: 'button', actionID: 'go', label: {type: 'spacer'}, color: '#fff'};
// @ts-expect-error isEnabled is strictly boolean.
const numericEnabled: DynamicIsland.ButtonNode = {type: 'button', actionID: 'go', label: {type: 'spacer'}, isEnabled: 1};
// @ts-expect-error Strings cannot coerce into enabled state.
const stringEnabled: DynamicIsland.ButtonNode = {type: 'button', actionID: 'go', label: {type: 'spacer'}, isEnabled: 'false'};
// @ts-expect-error Null is not an omitted enabled state.
const nullEnabled: DynamicIsland.ButtonNode = {type: 'button', actionID: 'go', label: {type: 'spacer'}, isEnabled: null};
// @ts-expect-error Progress supports only finite Host styles.
const arbitraryProgress: DynamicIsland.ProgressNode = {type: 'progress', value: 0.5, style: 'ring'};
// @ts-expect-error Countdown supports only finite Host styles.
const arbitraryCountdownStyle: DynamicIsland.CountdownStyle = 'ring';
void [arbitraryFont, numericFont, nullFont, arbitraryButtonStyle, arbitraryButtonColor, numericEnabled, stringEnabled, nullEnabled, arbitraryProgress, arbitraryCountdownStyle];

// @ts-expect-error Icon color is a semantic Host token, not CSS.
const cssIconColor: DynamicIsland.IconNode = {type: 'icon', symbolName: 'timer', color: '#ff6347'};
// @ts-expect-error Explicit null is not an omitted icon color.
const nullIconColor: DynamicIsland.IconNode = {type: 'icon', symbolName: 'timer', color: null};
void [cssIconColor, nullIconColor];
