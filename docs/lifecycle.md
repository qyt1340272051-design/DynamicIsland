# Lifecycle

每次执行使用独立 JavaScriptCore VM。全局 `onStart()` / `onStop()` 必须同步返回 undefined；不要声明 async，也不要 return Promise。可以在 onStart 内启动 Promise 链，处理初始化失败。动作 / countdown 完成回调可以返回真实 Promise。

这是 Hello 的完整入口，与可打包模板逐字相同。它先注册动作，再发布 UI；每个 Promise 拒绝都有处理，停止后不再提交业务更新：

<!-- sdk-source: ../examples/hello-world/index.js -->
```js
/// <reference path="../../types/island.d.ts" />
'use strict';

const activityID = 'counter';
let count = 0;
let stopped = false;
let updating = false;

/** @param {number} value @returns {DynamicIsland.Presentation} */
function presentation(value) {
    return {
        role: 'tool', compactPolicy: 'selectedOnly', title: '你好，计数器',
        subtitle: '本次运行已点击 ' + String(value) + ' 次',
        symbolName: 'plus.circle', showsCompact: false,
        minimal: {type: 'icon', symbolName: 'plus.circle'},
        compact: {type: 'hStack', children: [
            {type: 'icon', symbolName: 'plus.circle'}, {type: 'spacer'},
            {type: 'text', content: String(value)}
        ]},
        expanded: {type: 'vStack', children: [
            {type: 'text', content: '已点击 ' + String(value) + ' 次'},
            {type: 'button', actionID: 'increment', accessibilityLabel: '增加一次',
                label: {type: 'text', content: '加一'}}
        ]}
    };
}

/** @param {DynamicIsland.ActionEvent} event @returns {void | Promise<unknown>} */
function increment(event) {
    if (stopped || updating || event.activityID !== activityID || event.value.type !== 'none') return;
    updating = true;
    const next = count + 1;
    return island.activity.update({id: activityID, presentation: presentation(next)}).then(() => {
        if (!stopped) count = next;
    }, () => {
        if (!stopped) return island.log('Counter update failed', 'warning').catch(() => {});
    }).then(() => { updating = false; });
}

/**
 * Lifecycle hooks return synchronously. Host work is fire-and-catch; do not
 * make this function async or return the initialization Promise.
 * @returns {undefined}
 */
function onStart() {
    island.actions.on('increment', increment).then(() => {
        if (stopped) return null;
        return island.activity.publish({
            id: activityID, lifecycle: {policy: 'persistent'}, presentation: presentation(count),
            actions: [{id: 'increment', title: '加一'}]
        });
    }).catch(() => {
        if (!stopped) island.log('Counter initialization failed', 'error').catch(() => {});
    });
    return undefined;
}

/** @returns {undefined} */
function onStop() {
    // Host has already revoked this execution and removes its UI/handlers.
    stopped = true;
    return undefined;
}
```

停止时 Host 已撤销旧执行并负责移除 UI、动作和资源。onStop 用于清理本地状态，不应靠它再写 Storage 或提交 Activity。异步回复还可能排队，但旧执行不能继续访问新执行。重新启用会创建新 VM，Hello 从零开始；如需持久化，使用单独授权的 Storage。

不要依赖浏览器 / Node 环境：没有 DOM、window、require、文件系统、setTimeout 或 setInterval。入口按脚本运行，不是模块加载器；在发布前合并多文件业务代码到一个可执行入口。Host scheduler 是受策略约束的一次性刷新；业务倒计时使用 Host countdown，不在 JavaScript 中维护每秒时钟。

页面收起与插件停止不同：收起可能清除工具选择，业务计时仍归 Host 管理。睡眠、低电量等环境政策可能暂停或恢复执行，不能把一次 onStart 当作一次用户“开始”动作。日志与重复故障隔离见 [Debugging](debugging.md)。
