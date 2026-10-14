let running = false;
let stopped = false;
let refreshCount = 0;
const maximumRefreshes = 40;

function safeErrorCode(error) {
    const known = ['invalidArguments', 'unsupportedVersion', 'unsupportedMethod',
        'inactiveExecution', 'capabilityRequired', 'permissionRequired',
        'quotaExceeded', 'rateLimited', 'activityNotFound', 'coreRejected',
        'storageReadFailed', 'storageWriteFailed', 'permissionNotGranted',
        'permissionDenied', 'permissionRevoked', 'stalePermissionReview',
        'invalidResponse'];
    return error && known.indexOf(error.code) >= 0 ? error.code : 'unknown';
}

function stopAfterFailure(error) {
    // Once onStop has run, pending replies belong to the closed session.
    // Its expected inactiveExecution cancellation cannot be logged there.
    if (stopped) return;
    running = false;
    island.log('t31.refreshRejected:' + safeErrorCode(error), 'error')
        .catch(function () {
            // Do not swallow a failed audit log or recursively retry it.
            // Missing audit records also invalidate this acceptance window.
            throw new Error('T31 audit log rejected');
        });
}

function requestNextRefresh() {
    if (!running || refreshCount >= maximumRefreshes) return;
    island.scheduler.requestRefresh(60000).then(function (response) {
        if (!running) return;
        refreshCount += 1;
        const policy = response.policy;
        const level = policy === 'background' ? 'info' :
            policy === 'active' || policy === 'lowPower' ? 'warning' : null;
        if (level === null) {
            stopAfterFailure({code: 'invalidResponse'});
            return;
        }
        // Production diagnostics omit the message text but preserve its level.
        // The initial debug event is the first event; subsequent levels encode
        // the returned policy. No private API or extra permission is needed.
        island.log('t31.refresh:' + String(refreshCount) + ':policy:' + policy, level)
            .then(function () {
                // A fresh Host refresh is scheduled only after the log reply.
                // Each callback returns undefined, keeping prior chains finite.
                if (running) requestNextRefresh();
            }, stopAfterFailure);
    }, stopAfterFailure);
}

function onStart() {
    running = true;
    stopped = false;
    refreshCount = 0;
    island.log('t31.initial', 'debug').then(function () {
        if (running) requestNextRefresh();
    }, stopAfterFailure);
    // Lifecycle callbacks must return undefined in the production Runtime.
}

function onStop() {
    stopped = true;
    running = false;
}
