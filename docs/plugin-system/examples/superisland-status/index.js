// Independently authored SuperIsland protocol example. No upstream implementation.
(function () {
  'use strict';
  let available = true;
  SuperIsland.registerModule({
    compact: function () {
      return View.hstack([
        View.icon(available ? 'checkmark.circle.fill' : 'pause.circle.fill'),
        View.text(available ? '就绪' : '暂停')
      ]);
    },
    expanded: function () {
      return View.vstack([
        View.text('状态示例'),
        View.text(available ? '当前状态：就绪' : '当前状态：暂停'),
        View.button(View.text('切换状态'), 'increment')
      ]);
    },
    onAction: function (actionID) {
      if (actionID === 'increment') available = !available;
    }
  });
}());
