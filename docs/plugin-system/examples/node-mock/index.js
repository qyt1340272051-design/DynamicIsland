'use strict';

// The test Host explicitly advances this local fixture. It requires no
// network access, timers, image materialization, or action callbacks.
function mockNodePresentation(progress) {
  const completed = progress === 1;
  const percentage = String(Math.round(progress * 100)) + '%';
  const title = completed ? 'Node Mock 构建完成' : 'Node Mock 构建中';
  const color = completed ? 'success' : 'accent';
  const symbol = completed ? 'checkmark.circle' : 'hammer';
  return {
    title: title,
    subtitle: '纯本地声明式布局',
    symbolName: symbol,
    progress: progress,
    minimal: {type: 'text', content: percentage, color: color},
    compact: {
      type: 'hStack',
      children: [
        {type: 'icon', symbolName: symbol},
        {type: 'text', content: '构建 ' + percentage, color: color}
      ]
    },
    expanded: {
      type: 'vStack',
      children: [
        {type: 'text', content: title},
        {type: 'text', content: '纯本地声明式布局 · ' + percentage, color: 'secondary'},
        {type: 'progress', value: progress, style: 'linear', color: color}
      ]
    }
  };
}

function mockNodeReportFailure(error) {
  const code = error && typeof error.code === 'string' ? error.code : 'unknown';
  return island.log('node.error:' + code, 'warning').catch(function () {});
}

globalThis.onStart = function () {
  // Lifecycle functions return undefined; Host calls run in a handled chain.
  void island.activity.publish({
    id: 'build',
    priority: 'normal',
    lifecycle: {policy: 'progress'},
    presentation: mockNodePresentation(0.1),
    actions: []
  }).then(function () {
    return island.log('node.ready', 'info');
  }).catch(mockNodeReportFailure);
};

globalThis.mockNodeProgress = function (progress) {
  // Supplying presentation replaces it completely, including all three forms.
  return island.activity.update({
    id: 'build',
    presentation: mockNodePresentation(progress)
  }).then(function () {
    return island.log('node.progress:' + String(progress), 'info');
  }).catch(mockNodeReportFailure);
};

globalThis.mockNodeEnd = function () {
  return island.activity.end('build').then(function () {
    return island.log('node.ended', 'info');
  }).catch(mockNodeReportFailure);
};

globalThis.onStop = function () {
  // The Host revokes the session and removes its owned Activities.
};
