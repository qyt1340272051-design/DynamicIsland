# Activity

Activity 是插件向 Host 提交的内容和生命周期。Host 决定展示位置、优先级和交互，不向插件开放窗口尺寸、鼠标状态或展开控制。`publish` 成功只表示活动已接纳，不能据此判断当前屏幕一定可见。

`presentation.role` 默认为 `status`，适合短暂状态；`tool` 出现在展开后的工具列表，需要 persistent 或 progress 生命周期。Hello 是 persistent tool，由用户选择后展示，`showsCompact: false` 隐藏收起内容。要在业务运行时参与 compact 展示，可使用工具的 `compactPolicy: 'automatic'` 和有效 compact 布局；仍由 Host 仲裁，不能强占其他活动。

| 生命周期 policy | 使用方式 |
| --- | --- |
| `transient`（默认） | 一次结果 / 状态提示，时长由 Host 决定。 |
| `persistent` | 工具或长期状态，结束时显式 `end`，停用时 Host 也会清理。 |
| `progress` | 进行中的工作；结束旧实例再发布 transient 结果。 |

同一实例不能改变 lifecycle policy。`update` 是顶层补丁，但 `presentation` 一旦提供就整体替换，不能只补它的 title；请同时提交需要保留的 role、节点与显示选项。优先级仅 `background` / `normal`，省略使用 Host 默认。

下面是可复用的函数片段，需与自己的同步 `onStart` / 按钮逻辑结合。Manifest 需要 `activity.publish`、`activity.update`、`activity.end`、`ui.islandNode`；此例不需要资源权限。先等待 `publishReading()` 成功，再调用 update / end，并处理 Promise 拒绝。

<!-- sdk-source: snippets/activity.js -->
```js
/// <reference path="../../types/island.d.ts" />
'use strict';

/** @returns {Promise<DynamicIsland.ActivityReceipt>} */
function publishReading() {
    return island.activity.publish({
        id: 'reading', lifecycle: {policy: 'persistent'},
        presentation: {role: 'tool', title: '读数', showsCompact: false,
            expanded: {type: 'text', content: '等待更新'}}
    });
}

/** @param {number} value @returns {Promise<DynamicIsland.ActivityReceipt>} */
function updateReading(value) {
    if (!Number.isFinite(value) || value < 0 || value > 1) {
        return Promise.reject({code: 'invalidReading', message: 'Expected 0...1.'});
    }
    return island.activity.update({id: 'reading', presentation: {
        role: 'tool', title: '读数', showsCompact: false,
        expanded: {type: 'progress', value: value, color: 'accent'}
    }});
}

/** @returns {Promise<null>} */
function endReading() {
    return island.activity.end('reading');
}
```

Activity ID 是插件内本地标识，长 1–80 个 ASCII 字母、数字、点、下划线或连字符。`publish` / `update` 返回 `{id}`，`end` 返回 `null`。通过稳定 ID 更新同一业务实例，不要每秒发布新实例。结束后旧按钮失效，再用相同 ID 发布也会产生新实例。

倒计时由 `island.countdown` 管理，节点引用 Host 返回的 generation；开始和继续需要真实动作 activation。请参考[类型契约](../types/island.d.ts)及仓库中的官方 Pomodoro 实现；仅保存“运行中”设置不能在 App 重启后自动开表。
