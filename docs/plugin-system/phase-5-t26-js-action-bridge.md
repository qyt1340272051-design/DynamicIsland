# Phase 5 — T26 JS Action Bridge 实现与验收

日期：2026-10-10。范围：将正式 IslandRenderer 的 Button、Toggle、Slider 交互交给对应插件的当前 JavaScript handler，支持 handler 内再次 publish / update，并在停止后丢弃旧动作。最终验收结果见末尾表格。

## 注册与数据契约

`island.actions.supported` 为 true。namespace 与方法的 `apiVersion` 仍为 `1.0.0`，未增加原生对象或执行入口。

```javascript
island.actions.on('pause', event => {
    // event.activityID 是插件的本地 ID，事件及其 value 均冻结。
    return island.activity.update({
        id: event.activityID,
        presentation: {title: '已暂停'}
    });
}).catch(error => { /* 处理 registration 错误 */ });

island.actions.off('pause').catch(error => { /* 处理取消错误 */ });
```

- `on(actionID, handler)` 接受一个函数，返回 Promise；成功值为 null。同一 actionID 的新注册替换旧 handler；每会话最多 128 项。
- `off(actionID)` 幂等，返回 Promise；JS 私有表立即移除 handler，Host 按 Bridge FIFO 取消注册。
- 注册必须声明 `actions.handle`。actionID 非空、最多 80 UTF-8 bytes，只允许 ASCII 字母、数字、`.`、`_`、`-`。Host 再次独立校验参数。
- callback 只存于创建它的 VM 私有 Map。Host 注册表只存 actionID 和不透明 registrationID，每次替换生成新 registrationID；排队中的旧注册事件不能调用新 handler。
- `on` 先安装 JS handler 再发请求，失败仅回滚仍属于该 registrationID 的条目，避免旧失败覆盖后续注册。

Host → JS 事件为冻结的 null-prototype 纯数据对象：

```javascript
{
    activityID: 'controls',
    actionID: 'enabled',
    value: {type: 'toggle', value: true}
}
```

| 来源 | value |
| --- | --- |
| Button | `{type: 'none'}` |
| Toggle | `{type: 'toggle', value: boolean}` |
| Slider 连续更新 | `{type: 'slider', value: number}` |
| Slider 编辑结束 | `{type: 'sliderCommit', value: number}` |

Slider 数值必须有限且在 `0...1`，不接受任意对象、路径、函数或自由 payload。Host Event JSON 最多 1 KiB。本地 activityID 来自可信 namespaced Activity，最多 80 UTF-8 bytes，使用相同有限标识符字符集；source、执行 token 和 Activity instanceToken 不交给 JS。

## 生命周期与异步投递

每个 Runtime 的 onStart 创建独立 [`PluginActionSession`](../../DynamicIsland/Plugins/PluginActionSession.swift)，通过已有 PluginExecutionContext 注册源 handler。Host Bridge 的 actionSession 必须绑定同一个 context 对象。ActionRouter 初次校验当前展示 Activity、source、原 instanceToken、动作声明、source enablement 和 Host authorizer。

原 instanceToken 随 RoutedActivityAction 传入 Host session；不会在点击后按 ID 查询新 token。事件进入有界 VM 队列，在工作线程准备投递时异步回到 MainActor，再检查当前会话、原 Activity 实例、可见状态、动作声明、Host authorizer 和当前 registrationID。authorizer 是可重入 Host 回调，其返回后再核对注册和撤销状态。

再检查是交付准入点。其后已准入 / 开始的 JS callback 无法强制中断；停止会同步撤销 session、transport 和 worker，并在工作线程调用 JS 前再检查撤销。已结束后同 ID 重发的 Activity、已替换 handler、旧 Runtime 或失效 source 不能通过旧 token 重新获得授权。未注册动作直接丢弃。

Worker 同时最多保留 64 个待交付 / 待再检查动作，逐个进行 MainActor 再检查以保持 FIFO；超限丢弃新动作。没有 MainActor → VM 同步等待、信号量或 queue.sync。handler 的 Bridge 请求继续异步串行回到 MainActor，可安全更新同一 Activity。

ActionRouter 的 handled 表示已调用源 dispatcher，不是 JS callback 完成确认；插件异步投递仍可能因容量或随后失效而被丢弃。验收通过具体模型变化和成功日志确认完成。

disable、unload、suspend、stop、shutdown、启动失败和直接 teardown 均撤销旧 session。resume / restart 创建新 VM 与新注册表，必须再次 on 注册。Activity 仍为可序列化数据，不保存 closure。

## Callback 失败与容量

同步 throw 和真实 Promise 拒绝会记录固定 error 日志 `Action handler failed.`；不读取异常对象的 message、stack、then、toString 或其他 getter。失败不停止其他插件，当前 Runtime 后续合法交互仍可执行。

真实 Promise 返回可用于 handler 内 await Host 操作；通过捕获的 Promise intrinsics 识别和处理。普通返回值忽略，不通过读取任意对象的 then 来同化。每 VM 最多保留 64 个未完成真实 Promise callback；超限事件丢弃，记录固定 `Action handler limit exceeded.` 日志。日志请求自身的拒绝也被处理。

真实 Promise 的原生 then 使用 JavaScript 标准 constructor / species 语义；插件对自己返回 Promise 设置的相关 getter 仍在自己的工作线程执行。若其阻止观察器安装，Host 释放待完成额度，插件需自行处理这类被修改 Promise 的拒绝。该兼容边界不影响普通对象 then getter 的拒绝同化，也不会把对象传给 MainActor。

上述额度约束注册、投递队列和异步 callback 数量，不提供对无限循环、进程级 OOM 或 JavaScriptCore 崩溃的强制中断保证；调度及 Watchdog 按 T31/T32 推进。

## 实际示例与验证

[`examples/action-mock`](examples/action-mock/README.md) 提供正式 Manifest 与入口，先注册 handler，再发布同一个 persistent `controls` Activity，包含暂停按钮、开关和进度 Slider。三个回调内返回正式 `activity.update` Promise 并记录成功日志，无网络、定时器或文件权限。

[`PluginActionBridgeTests`](../../DynamicIslandTests/PluginActionBridgeTests.swift) 共 18 项，覆盖严格参数 / capability / 会话绑定、事件冻结与四种 payload FIFO、handler 替换和取消、128 注册 / 64 请求历史 / 64 投递 / 64 异步 callback 边界、重入更新、原实例过期 / 隐藏 / 结束重发 / 删除动作声明、停止重启、可重入 authorizer、固定错误日志及跨插件隔离。

实际示例复制到临时受控容器，经正式 PluginValidator 后加载。测试窗口使用同一 NSHostingView 的 480 × 200 pt Host canvas，公开 NSEvent mouseDown / mouseUp 经 AppKit 事件队列触发正式 SwiftUI Button、Toggle、Slider Binding 和编辑结束回调。每项等待具体成功日志并核对 Core 模型、createdAt 与 instanceToken；第二次 typed commit 等待新增日志数量，避免误用前一次完成信号。示例画面已人工查看，位置与实际控件匹配。

本机同进程 AX 遍历没有提供虚拟 Button，因此最终验收使用公开鼠标事件路径。失败的 AX 实验记录保留在 `/tmp/dynamic-island-t26-action-ax-retry/TestResults.xcresult`；最终 CI 和 Release 均执行鼠标控件测试，无新增 skip。VoiceOver 与真实刘海设备视觉验收独立追踪。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| T26 定向测试 / 实际控件 | 18 项全部包含于最终 CI / Release；实际鼠标控件单项通过。 | `/tmp/dynamic-island-t26-action-mouse/TestResults.xcresult`；最终完整结果见下列两行。 |
| 完整 CI 与普通 Release build | 471 项：470 passed、1 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t26-final-ci-v2/TestResults.xcresult`、`/tmp/dynamic-island-t26-final-ci-v2.log`。 |
| Release 定向回归 | 91 passed、0 skipped、0 failures：T26 18、Bridge 23、Runtime 29、Node 20、生产 factory 1。 | `/tmp/dynamic-island-t26-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t26-release-tests.log`。 |
| 普通 Release 签名 | `codesign --verify --deep --strict` 通过，flags `0x10002(adhoc,runtime)`；Sandbox / allow-jit 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t26-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t26-release-entitlements.plist`。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。唯一 CI skip 为沿用原配置的截图矩阵生成。Release XCTest 仅对 `/tmp/dynamic-island-t26-release-derived` 的临时 build-for-testing Host 注入测试 entitlement 并加 disable-library-validation 后 ad hoc 重签，普通 Release App 与项目生产 entitlement 无此测试例外。

T26 标记 `verified`：Button、Toggle、Slider 更新及编辑结束均已从正式 SwiftUI 经 Router、当前会话和 VM handler 回传，再在 callback 内更新同一 Activity；失效 / 超额动作被丢弃，失败与插件来源隔离。
