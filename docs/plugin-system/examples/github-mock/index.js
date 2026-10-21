'use strict';

// Pure local fixture. The test Host advances progress explicitly, so this
// example needs neither network access nor a plugin timer API.
function mockPresentation(progress) {
  return {
    title: progress === 1 ? 'GitHub Mock 构建完成' : 'GitHub Mock 构建中',
    subtitle: '纯本地模拟',
    symbolName: 'hammer',
    progress: progress
  };
}

function mockReportFailure(error) {
  const code = error && typeof error.code === 'string' ? error.code : 'unknown';
  return island.log('mock.error:' + code, 'warning').catch(function () {});
}

globalThis.onStart = function () {
  // Runtime lifecycle functions return undefined. Host requests run in this
  // handled Promise chain rather than returning a Promise from onStart.
  void island.activity.publish({
    id: 'build',
    priority: 'normal',
    lifecycle: {policy: 'progress'},
    presentation: mockPresentation(0.1),
    actions: []
  }).then(function () {
    return island.log('mock.ready', 'info');
  }).catch(mockReportFailure);
};

globalThis.mockBuildProgress = function (progress) {
  return island.activity.update({
    id: 'build',
    presentation: mockPresentation(progress)
  }).then(function () {
    return island.log('mock.progress:' + String(progress), 'info');
  }).catch(mockReportFailure);
};

globalThis.mockEnd = function () {
  return island.activity.end('build').then(function () {
    return island.log('mock.ended', 'info');
  }).catch(mockReportFailure);
};

globalThis.onStop = function () {
  // Host lifecycle cleanup revokes the session and ends owned Activities.
};
