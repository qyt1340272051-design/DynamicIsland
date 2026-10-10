# Phase 5 — T24 JS → Activity 实现与验收

日期：2026-10-10。范围：将插件传入的 `id`、`priority`、`lifecycle`、`presentation`、`actions` 转换为 IslandActivity；增加独立更新接口、Host 降级策略、source namespace 与写入频率限制。完成标准是正式 JavaScript Runtime 中的 GitHub Mock 能发布并更新同一构建 Activity。

## 数据边界与 API 版本

[`PluginActivityConverter`](../../DynamicIsland/Plugins/PluginActivityConverter.swift) 是纯 Swift、`nonisolated`、`Sendable` 的数据转换层，输入是经 [`PluginBridgeJSON`](../../DynamicIsland/Plugins/PluginBridgeJSON.swift) 解析后的 JSON 值，不接收 JavaScriptCore 对象或可执行回调。它独立校验字段形状、类型、UTF-8 容量与枚举，再由 [`PluginJSBridge`](../../DynamicIsland/Plugins/PluginJSBridge.swift) 检查 capability、当前会话和 Host 限制，进入正式 ActivityManager。

`island.apiVersion`、`island.activity.apiVersion` 与每个方法的 `apiVersion` 保持 `"1.0.0"`。T23 的合法 `publish({id, presentation})` 与 `end(id)` 仍可使用；新增可选字段和 `activity.update`。所有方法继续返回 Promise，成功结果只含数据；失败是冻结、空原型的 `{code, message}` 对象。`onStart` / `onStop` 仍必须同步返回 `undefined`。

| 方法 | 请求 | 结果与 capability |
| --- | --- | --- |
| `island.activity.publish(payload)` | 必需 `id`、`presentation`；可选 `priority`、`lifecycle`、`actions`。 | 完整发布/已有 ID 的完整 upsert；成功 `{id}`；要求 `activity.publish`。 |
| `island.activity.update(patch)` | 必需 `id`；至少提供 `priority`、`lifecycle`、`presentation`、`actions` 中一个。 | 更新已有 Activity；成功 `{id}`；要求 `activity.update`。 |
| `island.activity.end(id)` | 该插件的本地 ID 字符串。 | 结束已有 Activity；成功 `null`；要求 `activity.end`。 |

`publish` 使用发布默认值，不因同 ID 已存在而保留省略的可变字段：未给 priority 使用 `normal`，未给 lifecycle 使用 `transient`，未给 actions 使用空数组。Core 对已有 Activity 继续保留其创建时间与生命周期状态，并要求生命周期策略相同；重发已有 `progress` Activity 时须继续提供 `lifecycle: {policy: "progress"}`。变更已有事件的数据应使用 `update`，这样省略的字段会被保留。

`update` 是顶层部分补丁；其 `presentation` 一旦提供，就是完整摘要替换，必须含 title，省略的 subtitle、symbolName、progress 会被清空。省略 presentation 时原摘要保持。提供 `actions: []` 清空动作；省略 actions 时原动作保持。只传 `{id}` 会被拒绝，更新不存在的 Activity 返回 `activityNotFound`。

## 字段校验与 Host 降级

```javascript
{
  id: "build",
  priority: "normal",
  lifecycle: {policy: "progress"},
  presentation: {
    title: "正在构建",
    subtitle: "编译中",
    symbolName: "hammer",
    progress: 0.5
  },
  actions: []
}
```

| 字段 | 规则 |
| --- | --- |
| `id` | 非空，最多 80 UTF-8 bytes，只接受 ASCII 字母、数字、`.`、`_`、`-`。 |
| `priority` | 只接受 `background`、`normal`、`important`、`critical`。Host 保留 background；其余请求实际使用 normal。高级授权策略按 T28 继续实现。 |
| `lifecycle` | 只含必需 `policy`，取值为 `transient`、`persistent`、`progress`、`critical`。Host 将 critical 降为 transient，其余保留；不接受 state 或额外字段。 |
| `presentation.title` | 必需字符串，最多 256 UTF-8 bytes，不能为空或只有空白。 |
| `presentation.subtitle` | 可选字符串，最多 256 UTF-8 bytes；可为空字符串。 |
| `presentation.symbolName` | 可选非空字符串，最多 128 UTF-8 bytes，接受与本地 ID 相同的字符及 `:`。 |
| `presentation.progress` | 可选有限数值，范围 `0...1`，不接受 NaN / Infinity。 |
| `actions` | 可选数组，最多 8 项；每项只含必需 `id`、`title`。动作 ID 与 Activity 本地 ID 相同规则；标题最多 128 UTF-8 bytes，不能为空或只有空白；同一数组内 ID 不得重复。 |

任何未知字段、错误类型、`null` 代替可选字段的指定类型、空白标题或重复动作 ID 均返回 `invalidArguments`；字符串/动作数量等容量超限返回 `quotaExceeded`。输入不接受 `source`、Host ID、创建或到期时间、生命周期 state、窗口参数、动态 Swift 类型、IslandNode Tree 或 callback。T25 再增加受控声明式布局。

source 使用当前可信 `PluginExecutionContext.source`；实际 ID 为 `plugin:<plugin ID>:<local ID>`。不同插件的相同本地 ID 不会互相覆盖，插件也不能修改内置或其他插件 Activity。创建时间来自 Host，Core 管理实际生命周期状态；`update` 保留已有 createdAt、expiresAt 和 state。更新 lifecycle 时，有效 Host policy 必须与当前 policy 相同，策略变化在进入 Core 前返回 `invalidArguments`，避免用更新重新开启已关闭状态。

progress 达到 `1` 只是数据更新，不自动结束 Activity；插件可以随后调用 `end`。每插件最多保留 16 个 Activity ID，已有 Core 队列容量和显示策略仍可能提前淘汰或隐藏 Activity。发布、更新都通过当前会话 token 检查；撤销后的旧请求与回复继续沿用 T23 的停止边界。

## 动作数据与后续动作回传

非空 actions 除发布/更新 capability 外，还要求 Manifest 声明 `actions.handle`。空 actions 数组可用于清空元数据，无需此 capability。T24 只把受校验的 `{id, title}` 数据交给 Core，不注册 JavaScript handler；`island.actions.supported` 仍为 false，合法 `actions.on/off` 请求仍拒绝 `unsupportedMethod`。正式用户点击到插件 handler 的回传按 T26 实现。

## 发布与更新频率限制

[`PluginActivityRateLimiter`](../../DynamicIsland/Plugins/PluginActivityRateLimiter.swift) 使用 Host 的单调 uptime 时钟；Bridge 支持注入时钟，以便测试确定性地推进时间。它与 Core 的显示调度限频分开：这里限制 Activity 数据写入，Core 仍负责选出当前显示。

- 一个可信 plugin ID 共享一个 token bucket，覆盖所有本地 Activity ID，publish 与 update 共同消费。
- 容量为 20 tokens，每秒补充 10 tokens；每次成功的模型写入消费 1 token。额度不足返回 `rateLimited`，不改变 Activity。
- 校验、capability、失效会话、不存在 Activity、Core 拒绝或 Activity 数量超限不扣写入额度；额度不会因 Runtime 重载、替换或换本地 ID 重置。
- `end`、日志和 Storage 不消费此写入 bucket，额度耗尽时仍可结束 Activity 或记录失败。
- 限频器最多保留 1,024 个未完全恢复的插件 bucket。每次准入尝试移除已补满的状态，超出状态容量时拒绝新 bucket；不新增定时器或后台任务。

该预算保存在同一 Host Bridge 内存中。App 进程退出后重建预算；T27 的 KV 持久化不改变当前写入限频。不同 plugin ID 的预算互相独立，Core 仍统一管理所有来源的队列与窗口行为。

## GitHub Mock 最小闭环

[`examples/github-mock`](examples/github-mock/README.md) 提供实际 Manifest 与 JavaScript 入口。它只声明发布、更新、结束 capability，没有权限声明、网络请求或定时器。

测试将仓库示例复制到独立临时受控插件容器，经过正式 PluginValidator 校验其中的包，使用真实 PluginRuntime → PluginJSBridge → PluginLifecycleBridge → ActivityManager 执行；结束后清理该容器：

1. `onStart` 发布本地 `build`、进度 `0.1`、`progress` 生命周期，成功后记录 `mock.ready`。
2. Host 在插件线程调用示例 `mockBuildProgress(0.5)`，日志确认成功，并检查同一实际 Activity 进度为 `0.5`。
3. 调用 `mockBuildProgress(1)`，检查完成标题和进度为 `1`；Activity 仍保留。
4. 调用 `mockEnd()`，日志确认成功，并检查正式 Core 已移除 Activity。

`mockBuildProgress`、`mockEnd` 是 fixture 自有函数，测试通过 Runtime 测试入口推进场景；它们不新增生产 Bridge 能力。所有 Promise 链都显式捕获失败，并尝试记录固定错误 code，避免把未处理 rejection 当作成功。此 Mock 验收不包含正式 GitHub API 集成；官方 GitHub 插件按 T36 实现。

## 自动化验收与证据

[`PluginActivityBridgeTests`](../../DynamicIslandTests/PluginActivityBridgeTests.swift) 的 18 项新增测试覆盖以下场景：

- 转换默认值、可信 namespace、priority / policy 的 Host 降级、完整 publish upsert、顶层 update 补丁与 presentation 替换语义。
- 保留创建时间、实例 token 和生命周期状态；更新 dismissed Activity 仍保持 dismissed；拒绝有效 policy 变化，且没有部分数据提交。
- 发布/更新 capability 独立检查，非空动作元数据的 `actions.handle` 门禁，动作数量、重复 ID、字段类型与 UTF-8 边界。
- 伪造 Host 字段、未知字段、错误嵌套形状、重复 JSON key、非有限数字、非法 ID 和超限数据均拒绝且无副作用。
- 使用注入时钟验证 publish / update 共享预算、拒绝不改模型、补充额度、Core 容量拒绝不扣额、end 不受此预算限制；已过期事件的 update 不能重新创建它；不同 ID 和 Runtime 替换不能重置，同一时间不同插件互不消耗预算。
- 禁用或替换执行会话后，旧 context 不能更新模型或消耗新会话预算。
- `testRealJavaScriptGitHubMockProgressUpdatesRenderSameHostInstance` 校验并执行仓库中的实际示例入口，等待每一步日志和正式 Core 状态；同一 `NSHostingView` 连接 IslandRenderer，比较 `0.1`、`0.5`、`1` 三次渲染数据并检查实例 token、创建时间、policy / state 保持，最后结束 Activity。
- 实际 JavaScript 的 update 拒绝非法参数和缺少 capability，并检查新方法的冻结状态与 API 版本。

既有 T23 Bridge / T22 Runtime / 生产 factory 测试继续回归。验收环境为 arm64 MacBook Air、macOS 26.6.2（25G83），Xcode 使用 macOS 26.5 SDK。以下是最终代码的验证结果。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| T24 转换与真实 Mock | 当前 18 项全部通过；包含实际包复制、Validator、JavaScriptCore、Core 容量失败与过期更新、三次 Renderer 渲染及结束。 | 最终完整 CI 与 Release 结果均包含当前 18 项；历史 17 项定向结果：`/tmp/dynamic-island-t24-tests-targeted-retry/TestResults.xcresult`。 |
| 完整 `./Scripts/ci.sh` | 433 total / 432 passed / 1 expected screenshot skipped / 0 failures；Release build passed。 | `/tmp/dynamic-island-t24-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t24-final-ci.log`。 |
| Release Activity + Bridge + 生产入口 | 42 passed / 0 skipped / 0 failures，包含当前 18 项 T24、23 项 T23 Bridge 和 1 项生产 factory；真实 JavaScriptCore 与 Renderer 通过。 | `/tmp/dynamic-island-t24-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t24-release-tests.log`。 |
| 普通 Release App 签名 | `codesign --verify --deep --strict` 通过；Hardened Runtime `flags=0x10002(adhoc,runtime)`，Sandbox 和 allow-jit 为 true；无测试专用 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t24-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t24-release-entitlements.plist`。 |

Release 执行验证沿用 T22/T23 的独立临时 XCTest 宿主流程：在 `/tmp/dynamic-island-t24-release-derived` 以 Release 优化、`ENABLE_TESTABILITY=YES` 与 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES` 构建；仅重签该临时宿主，保留 Hardened Runtime、Sandbox、allow-jit，并加入加载 ad hoc XCTest 所需的测试专用 `disable-library-validation`。项目权利文件与普通 Release App 没有加入该例外；本次没有生成发行包或进行公证。

最终 Debug 与 Release 结果满足 T24 原文「GitHub Mock 插件可发布并更新构建 Activity」的完成标准，进度表标记为 `verified`。

自动化 Core 状态及 Renderer 回归属于程序验收，不能替代真实刘海设备视觉验收。T25 IslandNode、T26 动作回传、T27 持久化 Storage、T28 用户权限 grant、T31/T32 调度与 Watchdog 继续各自按计划推进；本步不扩展这些任务的完成状态。
