# Action Mock — T26 验收示例

展开包 `com.example.action-mock` 提供 Button、Toggle、Slider 三种控件。Manifest 声明 Activity 发布 / 更新 / 结束、IslandNode UI 和动作处理 capability，权限数组为空。

`onStart` 同步返回 undefined；Promise 链先注册三个 handler，再发布 persistent `controls` Activity，成功日志为 `action.ready`。Host 用户交互经过 IslandRenderer → ActionRouter → 当前 PluginActionSession → VM 工作线程，回调内调用正式 `activity.update` 更新同一个 Activity。

| 控件 | 回传数据 | 更新及成功日志 |
| --- | --- | --- |
| 暂停 / 继续按钮 | `value.type: "none"` | 翻转运行状态，日志 `action.pause`。 |
| 启用示例 Toggle | `value.type: "toggle"`、布尔 value | 更新开关，日志 `action.toggle`。 |
| 示例进度 Slider | `value.type: "slider"` / `"sliderCommit"`、`0...1` value | 更新进度，日志 `action.slider` / `action.sliderCommit`。 |

handler 收到的 activityID 是本地 `controls`，Host ID 为 `plugin:com.example.action-mock:controls`。事件为冻结的纯数据；回调函数只存于插件自己的 VM。handler 返回实际 Promise，失败由 Runtime 固定错误日志处理。

停止、禁用、卸载、挂起或直接 teardown 后，旧会话的注册和待交付动作失效；重启时 `onStart` 重新注册。没有生产插件安装 UI，安装管理按 T33 推进。

自动化测试及结果见 [T26 实现与验收](../../phase-5-t26-js-action-bridge.md)。这份示例没有网络、定时器、文件或持久化存储。
