'use strict';

// Public repositories only. No credential is requested, read, or stored.
const repositories = ['actions/checkout', 'cli/cli'];
const repositoryKeys = ['checkout', 'cli'];
const dashboardID = 'dashboard';
const normalDelay = 300000;
const maximumDelay = 3600000;
let repository = repositories[0];
let notifiedResults = [null, null];
let notificationRevisions = [0, 0];
let revision = 0;
let run = null;
let pull = null;
let hint = '正在读取';
let linkHint = '';
let storageHint = false;
let published = false;
let savedSettings = null;
let desiredSettings = null;
let saving = false;
let uiWork = Promise.resolve();
let renderQueued = false;
let activeBuild = null;
let dashboardLinks = {build: null, pr: null};
let inFlight = null;
let failures = 0;
let cooldown = 0;
let cooldownRevision = 0;
let scheduled = false;

function object(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function integer(value) {
    return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

// Bound by UTF-8 bytes, including astral characters, before sending to IslandNode.
function shortText(value, maximum) {
    if (typeof value !== 'string') return '';
    let result = '', bytes = 0;
    for (const character of value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim()) {
        const point = character.codePointAt(0);
        const width = point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4;
        if (bytes + width > maximum) break;
        result += character;
        bytes += width;
    }
    return result;
}

function validSettings(value) {
    if (!object(value) || Object.keys(value).sort().join(',') !== 'notifiedResults,repository,schemaVersion' ||
        value.schemaVersion !== 1 || repositories.indexOf(value.repository) === -1 ||
        !Array.isArray(value.notifiedResults) || value.notifiedResults.length !== 2) return null;
    // SDK arrays deliberately have no prototype. Read their bounded indices;
    // methods such as .every()/.slice() are unavailable on incoming values.
    const results = [];
    for (let index = 0; index < 2; index++) {
        const key = value.notifiedResults[index];
        if (key !== null && !(typeof key === 'string' &&
            /^[1-9][0-9]{0,15}\.[1-9][0-9]{0,15}$/.test(key))) return null;
        results.push(key);
    }
    return {schemaVersion: 1, repository: value.repository, notifiedResults: results};
}

function settings() {
    return {schemaVersion: 1, repository, notifiedResults: notifiedResults.slice()};
}

function sameSettings(first, second) {
    return first !== null && second !== null && JSON.stringify(first) === JSON.stringify(second);
}

function saveSettings() {
    if (saving || desiredSettings === null) return;
    if (sameSettings(desiredSettings, savedSettings)) {
        storageHint = false;
        queueRender();
        return;
    }
    const value = desiredSettings;
    saving = true;
    island.storage.set('settings', value).then(() => {
        saving = false;
        savedSettings = value;
        storageHint = !sameSettings(desiredSettings, savedSettings);
        queueRender();
        if (storageHint) saveSettings();
    }, () => {
        saving = false;
        storageHint = true;
        queueRender();
        // Retry only on another user action or Host refresh, never recursively.
    });
}

function queueSettings() {
    desiredSettings = settings();
    storageHint = !sameSettings(desiredSettings, savedSettings);
    saveSettings();
}

function readSettings() {
    const admittedRevision = revision;
    const admittedNotifications = notificationRevisions.slice();
    island.storage.get('settings').then(value => {
        const valid = validSettings(value);
        savedSettings = valid;
        if (valid !== null) {
            for (let index = 0; index < 2; index++) {
                if (notificationRevisions[index] === admittedNotifications[index]) {
                    notifiedResults[index] = valid.notifiedResults[index];
                }
            }
        }
        if (revision === admittedRevision && admittedRevision === 0 && valid !== null) {
            if (repository !== valid.repository) chooseRepository(valid.repository, false);
        }
        if (desiredSettings !== null) queueSettings();
        storageHint = value !== null && valid === null || desiredSettings !== null &&
            !sameSettings(desiredSettings, savedSettings);
        queueRender();
    }, () => { storageHint = true; queueRender(); });
}

function text(content) { return {type: 'text', content}; }

function button(actionID, title, accessibilityLabel, selected) {
    return {type: 'button', actionID, accessibilityLabel,
        label: {type: 'text', content: title, color: selected ? 'accent' : 'primary'}};
}

function runLabel(value) {
    if (!value) return '暂无构建';
    if (value.status === 'completed') {
        return value.conclusion === 'success' ? '构建成功' : value.conclusion === 'cancelled' ? '已取消' :
            value.conclusion === 'skipped' || value.conclusion === 'neutral' ? '构建结束' : '构建失败';
    }
    return value.status === 'in_progress' ? '构建中' : '排队中';
}

function symbol(value) {
    if (!value) return 'hammer';
    if (value.status !== 'completed') return value.status === 'in_progress' ? 'hammer.fill' : 'clock';
    return value.conclusion === 'success' ? 'checkmark.circle.fill' :
        value.conclusion === 'cancelled' || value.conclusion === 'skipped' || value.conclusion === 'neutral'
            ? 'minus.circle' : 'xmark.circle.fill';
}

function compact(value) {
    return {type: 'hStack', children: [{type: 'icon', symbolName: symbol(value)}, {type: 'spacer'},
        text(!value ? '待查' : value.status !== 'completed' ? value.status === 'in_progress' ? '构建' : '排队' :
            value.conclusion === 'success' ? '成功' : value.conclusion === 'cancelled' ? '取消' :
                value.conclusion === 'neutral' || value.conclusion === 'skipped' ? '结束' : '失败')]};
}

function presentation() {
    const status = runLabel(run);
    return {
        role: 'tool', compactPolicy: 'automatic', title: 'GitHub', subtitle: repository + ' · ' + status,
        symbolName: symbol(run), showsCompact: false,
        minimal: {type: 'icon', symbolName: symbol(run)}, compact: compact(run),
        expanded: {type: 'vStack', children: [
            text('GitHub · ' + repository + (storageHint ? ' · 未保存' : '')),
            text('CI · ' + status + ((linkHint || hint) ? ' · ' + (linkHint || hint) : '')),
            text(pull ? 'PR #' + String(pull.number) + ' · ' + pull.title : 'PR · 暂无打开的 PR'),
            {type: 'hStack', children: [
                button('repo.checkout', 'checkout', '选择 actions/checkout', repository === repositories[0]),
                button('repo.cli', 'cli/cli', '选择 cli/cli', repository === repositories[1])
            ]},
            {type: 'hStack', children: [button('refresh', '刷新', '刷新状态', false),
                button('open.build', '构建', '打开构建', false), button('open.pr', 'PR', '打开 PR', false)]}
        ]}
    };
}

function queueRender() {
    if (!published || renderQueued) return;
    renderQueued = true;
    const task = uiWork.then(() => {
        renderQueued = false;
        const links = {build: run && run.url, pr: pull && pull.url};
        return island.activity.update({id: dashboardID, presentation: presentation()}).then(() => {
            dashboardLinks = links;
        });
    });
    uiWork = task.catch(() => { renderQueued = false; });
}

function buildPresentation(value) {
    const status = runLabel(value);
    return {title: status, subtitle: repository + ' · ' + value.name, symbolName: symbol(value),
        minimal: {type: 'icon', symbolName: symbol(value)}, compact: compact(value),
        expanded: {type: 'vStack', children: [text(status), text(repository + ' · ' + value.name),
            button('open.build', '打开构建', '打开构建', false)]}};
}

function endBuild() {
    if (activeBuild === null) return Promise.resolve();
    const previous = activeBuild;
    activeBuild = null;
    return island.activity.end(previous.id).catch(() => {});
}

function updateBuild(value, selectedRepository) {
    const task = uiWork.then(() => {
        if (repository !== selectedRepository || run !== value) return;
        if (value === null) return endBuild();
        const index = repositories.indexOf(selectedRepository);
        const key = String(value.id) + '.' + String(value.attempt);
        const id = 'build.' + repositoryKeys[index] + '.' + key;
        const completed = value.status === 'completed';
        if (completed && notifiedResults[index] === key) return;
        const unchanged = activeBuild && activeBuild.id === id && activeBuild.status === value.status &&
            activeBuild.conclusion === value.conclusion;
        if (unchanged) return;
        const sameBuild = activeBuild && activeBuild.id === id;
        const cleanup = !sameBuild || completed ? endBuild() : Promise.resolve();
        return cleanup.then(() => {
            if (repository !== selectedRepository || run !== value) return;
            const request = {id, presentation: buildPresentation(value)};
            if (sameBuild && !completed) return island.activity.update(request).then(() => {
                activeBuild = {id, status: value.status, conclusion: value.conclusion, url: value.url};
            });
            request.priority = 'normal';
            request.lifecycle = {policy: completed ? 'transient' : 'progress'};
            request.actions = [{id: 'open.build', title: '打开构建'}];
            return island.activity.publish(request).then(() => {
                activeBuild = {id, status: value.status, conclusion: value.conclusion, url: value.url};
                if (completed) {
                    notifiedResults[index] = key;
                    notificationRevisions[index] += 1;
                    queueSettings();
                }
            });
        });
    });
    uiWork = task.catch(() => {});
    return uiWork;
}

function header(headers, name) {
    for (const key of Object.keys(headers)) if (key.toLowerCase() === name) return headers[key];
    return null;
}

function rateDelay(headers) {
    const retry = header(headers, 'retry-after');
    const reset = header(headers, 'x-ratelimit-reset');
    let delay = normalDelay;
    if (retry !== null && /^[0-9]{1,10}$/.test(retry)) delay = Math.max(delay, Number(retry) * 1000);
    else if (retry !== null) {
        const date = Date.parse(retry);
        if (Number.isFinite(date)) delay = Math.max(delay, date - Date.now());
    }
    if (reset !== null && /^[0-9]{1,12}$/.test(reset)) delay = Math.max(delay, Number(reset) * 1000 - Date.now());
    return Math.max(normalDelay, Math.ceil(delay));
}

function fetchJSON(url) {
    return island.network.fetch(url, {method: 'GET', timeoutMs: 10000, headers: {
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10',
        'User-Agent': 'DynamicIsland-GitHub-Plugin'
    }}).then(response => {
        const exhausted = header(response.headers, 'x-ratelimit-remaining') === '0';
        if (response.status === 429 || response.status === 403 &&
            (exhausted || header(response.headers, 'retry-after') !== null)) {
            throw {kind: 'rate', delay: rateDelay(response.headers)};
        }
        if (!response.ok) throw {kind: response.status === 403 ? 'access' : 'api'};
        return response.json().then(value => ({value, rateDelay: exhausted ? rateDelay(response.headers) : 0}));
    });
}

function parseRun(value, selectedRepository) {
    if (!object(value) || !Array.isArray(value.workflow_runs) || value.workflow_runs.length > 1) throw {kind: 'data'};
    if (value.workflow_runs.length === 0) return null;
    const first = value.workflow_runs[0];
    if (!object(first) || !integer(first.id) || !integer(first.run_attempt) ||
        ['queued', 'requested', 'waiting', 'pending', 'in_progress', 'completed'].indexOf(first.status) === -1 ||
        first.status === 'completed' && ['success', 'failure', 'neutral', 'cancelled', 'skipped', 'timed_out',
            'action_required', 'stale', 'startup_failure'].indexOf(first.conclusion) === -1) throw {kind: 'data'};
    const url = 'https://github.com/' + selectedRepository + '/actions/runs/' + String(first.id);
    const validURL = first.html_url === url || first.html_url === url + '/attempts/' + String(first.run_attempt);
    return {id: first.id, attempt: first.run_attempt, status: first.status,
        conclusion: first.status === 'completed' ? first.conclusion : null,
        name: shortText(first.name, 48) || 'GitHub Actions', url: validURL ? first.html_url : null};
}

function parsePull(value, selectedRepository) {
    if (!Array.isArray(value) || value.length > 1) throw {kind: 'data'};
    if (value.length === 0) return null;
    const first = value[0];
    if (!object(first) || !integer(first.number) || typeof first.title !== 'string') throw {kind: 'data'};
    const url = 'https://github.com/' + selectedRepository + '/pull/' + String(first.number);
    return {number: first.number, title: shortText(first.title, 64) || '未命名 PR',
        url: first.html_url === url ? url : null};
}

function failure(error) {
    failures = Math.min(5, failures + 1);
    cooldown = error && error.kind === 'rate' ? error.delay :
        Math.min(maximumDelay, normalDelay * Math.pow(2, failures - 1));
    cooldownRevision += 1;
    const code = error && error.code;
    hint = error && error.kind === 'rate' ? 'GitHub 限流' : error && error.kind === 'access' ? 'API 访问受限' :
        code === 'permissionNotGranted' || code === 'permissionDenied' || code === 'permissionRevoked' ? '网络未授权' :
        code === 'networkTransportFailed' || code === 'networkTimeout' ? '离线，稍后重试' :
        error && error.kind === 'data' || code === 'quotaExceeded' || code === 'invalidResponse' ||
            code === 'networkResponseTooLarge' || code === 'networkInvalidResponse' ? '数据超出限制' : 'API 请求失败';
    queueRender();
}

function scheduleRefresh() {
    if (scheduled) return;
    scheduled = true;
    const waitingRevision = cooldownRevision;
    const waitingCooldown = cooldown;
    const waitingChunk = Math.min(maximumDelay, waitingCooldown || normalDelay);
    island.scheduler.requestRefresh(waitingChunk).then(() => {
        scheduled = false;
        // A cooldown raised after admission must receive its whole wait. The
        // old pending Host request cannot shorten rate-limit backoff.
        if (waitingRevision !== cooldownRevision) { scheduleRefresh(); return; }
        if (waitingCooldown) {
            cooldown = Math.max(0, waitingCooldown - waitingChunk);
            if (cooldown) { scheduleRefresh(); return; }
        }
        return refresh().then(scheduleRefresh);
    }).catch(() => { scheduled = false; });
}

function refresh() {
    if (cooldown) { queueRender(); return Promise.resolve(); }
    if (inFlight !== null) return inFlight;
    const selectedRepository = repository;
    const selectedRevision = revision;
    linkHint = '';
    hint = '正在读取';
    queueRender();
    if (desiredSettings !== null) saveSettings();
    const base = 'https://api.github.com/repos/' + selectedRepository;
    inFlight = fetchJSON(base + '/actions/runs?per_page=1&page=1&exclude_pull_requests=true').then(response => {
        if (selectedRevision !== revision) return;
        run = parseRun(response.value, selectedRepository);
        queueRender();
        return updateBuild(run, selectedRepository).then(() => {
            if (response.rateDelay) throw {kind: 'rate', delay: response.rateDelay};
            if (selectedRevision !== revision) return;
            return fetchJSON(base + '/pulls?state=open&sort=updated&direction=desc&per_page=1').then(result => {
                if (selectedRevision !== revision) return;
                pull = parsePull(result.value, selectedRepository);
                if (result.rateDelay) throw {kind: 'rate', delay: result.rateDelay};
                hint = '';
                failures = 0;
                queueRender();
            });
        });
    }).catch(error => { if (selectedRevision === revision) failure(error); }).then(() => {
        inFlight = null;
        scheduleRefresh();
        if (selectedRevision !== revision && !cooldown) return refresh();
    });
    return inFlight;
}

function chooseRepository(value, persist) {
    if (repository === value) return;
    repository = value;
    revision += 1;
    run = null;
    pull = null;
    hint = cooldown ? hint : '正在读取';
    linkHint = '';
    if (persist) queueSettings();
    queueRender();
    const task = uiWork.then(endBuild);
    uiWork = task.catch(() => {});
    if (published) void refresh();
}

function openLink(event, kind) {
    if (event.value.type !== 'none' || typeof event.activation !== 'string' ||
        event.activityID !== dashboardID && (kind !== 'build' || !activeBuild || event.activityID !== activeBuild.id)) return;
    const url = event.activityID === dashboardID ? dashboardLinks[kind] : activeBuild && activeBuild.url;
    if (!url) { linkHint = '暂无可打开链接'; queueRender(); return; }
    // The fresh activation is consumed immediately. Neither a blocked fetch
    // nor a pending Storage write is allowed to sit in front of Open.
    return island.links.open({url, activation: event.activation}).catch(() => {
        linkHint = '无法打开，请检查授权';
        queueRender();
    });
}

function onStart() {
    const registrations = [
        island.actions.on('repo.checkout', event => {
            if (event.activityID !== dashboardID || event.value.type !== 'none') return;
            revision += 1;
            if (repository === repositories[0]) { queueSettings(); return; }
            chooseRepository(repositories[0], true);
        }),
        island.actions.on('repo.cli', event => {
            if (event.activityID !== dashboardID || event.value.type !== 'none') return;
            revision += 1;
            if (repository === repositories[1]) { queueSettings(); return; }
            chooseRepository(repositories[1], true);
        }),
        island.actions.on('refresh', event => {
            if (event.activityID !== dashboardID || event.value.type !== 'none') return;
            return refresh();
        }),
        island.actions.on('open.build', event => openLink(event, 'build')),
        island.actions.on('open.pr', event => openLink(event, 'pr'))
    ];
    readSettings();
    uiWork = Promise.all(registrations).then(() => island.activity.publish({id: dashboardID,
        lifecycle: {policy: 'persistent'}, presentation: presentation(), actions: [
            {id: 'repo.checkout', title: 'actions/checkout'}, {id: 'repo.cli', title: 'cli/cli'},
            {id: 'refresh', title: '刷新'}, {id: 'open.build', title: '打开构建'}, {id: 'open.pr', title: '打开 PR'}
        ]})).then(() => { published = true; queueRender(); void refresh(); }).catch(() => {
        island.log('GitHub initialization failed', 'error').catch(() => {});
    });
}

function onStop() {}
