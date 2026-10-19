// Independently authored SuperIsland protocol example. No upstream implementation.
(function () {
  'use strict';
  let count = 0;
  SuperIsland.registerModule({
    compact: function () {
      return View.hstack([View.icon('plus.circle.fill'), View.text('计数 ' + count)]);
    },
    expanded: function () {
      return View.vstack([
        View.text('已计数 ' + count + ' 次'),
        View.hstack([
          View.button(View.text('加一'), 'increment'),
          View.button(View.text('归零'), 'reset')
        ])
      ]);
    },
    onAction: function (actionID) {
      if (actionID === 'increment') count = Math.min(count + 1, 9999);
      if (actionID === 'reset') count = 0;
    }
  });
}());
