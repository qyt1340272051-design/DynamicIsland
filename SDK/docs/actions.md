# Actions

按钮的 `actionID` 必须同时对应三个位置：`island.actions.on` 注册的处理器、Activity `actions` 声明、节点树的 button。Manifest 需要 `actions.handle` 和相应 Activity / UI 能力。最多八个唯一动作声明。

Hello 的完整入口见 [Lifecycle](lifecycle.md)：先等待 `actions.on('increment', increment)`，再发布包含相同 ID 的 Activity。处理器核对 `event.activityID` 和 `event.value.type`；并用 updating 标志避免重复点击导致旧更新覆盖新值。回调可以返回真实 Promise，Host 生命周期钩子则必须同步返回。

Host 根据当前呈现实例重新校验动作。工具必须被选择、按钮确实提交且可交互；旧实例按钮不能控制停用后新建的同 ID 活动。不要把 UI 更新成功之前取得的新数据提前用作按钮目标。

`event.activation` 可能缺省；符合条件的真实用户动作才取得短时、一次性票据。链接打开、倒计时 start / resume 需要它。收到后立即提交，不能先等网络或存储，更不能缓存或伪造。类型品牌只帮助编写代码，Host 再做运行时检查。

以下函数适合作为已声明并呈现的 `open` 按钮处理器，需要 `links.open` capability 和单独批准的同名 permission。还需调用者注册 handler 并在 Activity 声明 / UI 使用该 ID；它不是完整插件。实际例子只打开一个固定页面，缺少 activation 时不产生打开行为：

<!-- sdk-source: snippets/open-link.js -->
```js
/// <reference path="../../types/island.d.ts" />
'use strict';

/** @param {DynamicIsland.ActionEvent} event @returns {Promise<null>} */
function openGitHubRepository(event) {
    if (!event.activation) return Promise.resolve(null);
    // Submit the activation immediately; do not await storage or a fetch first.
    return island.links.open({url: 'https://github.com/cli/cli', activation: event.activation});
}
```

当前链接 Host 政策只允许 `https://github.com`，不允许任意浏览器跳转。正式 GitHub 示例还把缓存 URL 绑定到已呈现的构建 / PR，校验其仓库与编号。不要直接打开外部 JSON 的任意字符串。
