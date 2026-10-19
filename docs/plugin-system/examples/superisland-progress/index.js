// Independently authored SuperIsland protocol example. No upstream implementation.
(function () {
  'use strict';
  let step = 0;
  let intent = '未发送';
  SuperIsland.registerModule({
    compact: function () {
      return View.hstack([View.icon('chart.bar.fill'), View.text('步骤 ' + step + '/4')]);
    },
    expanded: function () {
      return View.vstack([
        View.text('手动步骤 ' + step + '/4'),
        View.progress(step, {total: 4}),
        View.text('展示意图：' + intent),
        View.hstack([
          View.button(View.text('下一步'), 'increment'),
          View.button(View.text('归零'), 'reset')
        ]),
        View.hstack([
          View.button(View.text('请求展示'), 'reveal'),
          View.button(View.text('撤回请求'), 'dismiss')
        ])
      ]);
    },
    onAction: function (actionID) {
      if (actionID === 'increment') step = Math.min(step + 1, 4);
      if (actionID === 'reset') step = 0;
      if (actionID === 'reveal') {
        intent = '已请求';
        SuperIsland.island.activate(false);
      }
      if (actionID === 'dismiss') {
        intent = '已撤回';
        SuperIsland.island.dismiss();
      }
    }
  });
}());
