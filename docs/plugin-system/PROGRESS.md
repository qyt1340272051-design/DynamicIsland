# Plugin System Development Progress

本表追踪 [插件系统开发计划](DevelopmentPlan.md) 中的 T01–T40。Phase 0 是准备阶段；Phase 1–9 是九个实施阶段。任务名称与前置依赖以计划原文的「任务总表」为准。

0.6.0 是当前开发版本；目前不将它擅自对应到计划中的 Plugin Alpha、Plugin Beta 或 Plugin 1.0 验收门槛。版本范围应在相应任务和验收结果明确后确定。

## 状态与验收规则

- `pending`：尚未开始。
- `in progress`：已有审计、设计、实现或验证工作，但尚未满足计划原文的完成标准。
- `verified`：满足计划原文对应任务的完成标准，并在本表的「验收证据」列链接可审查的证据。证据至少说明实现或审计产物、执行的验证及结果；涉及 UI、性能、能耗或设备行为的任务还应记录相应实测环境和结果。仅有代码或一次构建成功不足以将任务标为 `verified`。

依赖列中的 `Txx–Tyy` 表示该范围内的全部任务；`T14 基础` 沿用原计划表述。任务开始与验收前必须满足任务总表列出的直接前置依赖；每个阶段结束时，按计划的「每个阶段的统一检查清单」复核旧功能、架构、并发、性能、能耗、安全、隐私、兼容、测试和回滚，并链接阶段验收记录。后续任务通过不会自动关闭仍为 `in progress` 的旧任务，其额外证据缺口继续在原任务中独立追踪。

## Phase 0 — 准备阶段：项目审计、分支与基线

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T01 | 项目架构审计 | 无 | `verified` | [Phase 0 基线记录](phase-0-baseline.md)记录了真实依赖图、职责边界、迁移调用点、多屏约束及审计结论。 |
| T02 | 开发分支与基线测试 | T01 | `in progress` | [Phase 0 基线记录](phase-0-baseline.md)记录开发分支、自动化基线和重复检查清单；真实启动、空闲资源及设备场景待测。 |

## Phase 1 — Activity Engine

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T03 | IslandActivity | T01 | `verified` | [纯数据模型](../../DynamicIsland/Core/Activity/IslandActivity.swift)与 [Music/Battery/Download 构造和 Codable 测试](../../DynamicIslandTests/IslandActivityTests.swift)；`./Scripts/ci.sh` 170 tests、1 skipped、0 failures、Release build passed。 |
| T04 | ActivityPriority | T03 | `verified` | [有限优先级及默认映射](../../DynamicIsland/Core/Activity/ActivityPriority.swift)、[确定性排序测试](../../DynamicIslandTests/ActivityPriorityTests.swift)；同上 CI。 |
| T05 | ActivityLifecycle | T03 | `verified` | [状态转换与行为策略](../../DynamicIsland/Core/Activity/ActivityLifecycle.swift)、[dismiss/ended/恢复/过期测试](../../DynamicIslandTests/ActivityLifecycleTests.swift)；同上 CI。 |
| T06 | ActivityManager | T03–T05 | `verified` | [单写入口](../../DynamicIsland/Core/Activity/ActivityManager.swift)、[DEBUG Provider 与只读观察窗口](../../DynamicIsland/Core/Activity/ActivityDebugPanel.swift)、[同一 NSHostingView 的发布/更新/结束渲染测试](../../DynamicIslandTests/ActivityDebugPanelTests.swift)；`./Scripts/ci.sh` 190 tests、1 skipped、0 failures、Release build passed。 |
| T07 | Priority Queue | T06 | `verified` | [确定性队列](../../DynamicIsland/Core/Activity/ActivityQueue.swift)和 [抢占/恢复测试](../../DynamicIslandTests/ActivityQueueTests.swift)；同上 CI。 |
| T08 | Activity Scheduler | T07 | `in progress` | [集中截止任务](../../DynamicIsland/Core/Activity/ActivityScheduler.swift)与 [过期、续展、正时长、20 事件、自动唤醒测试](../../DynamicIslandTests/ActivitySchedulerTests.swift)；同上 CI。实际岛体 UI 闪烁和空闲能耗待接入后实测。 |

## Phase 2 — IslandNode、Renderer 与动作路由

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T09 | IslandNode | T03 | `verified` | [受限数据节点与 JSON 校验](../../DynamicIsland/IslandUI/Schema/IslandNode.swift)、[计时/构建/音乐树及恶意输入测试](../../DynamicIslandTests/IslandNodeTests.swift)；6 项定向测试通过。 |
| T10 | DesignTokens | T09 | `in progress` | [有限 Host token 与几何映射](../../DynamicIsland/IslandUI/DesignTokens.swift)、[编码/对比度/尺寸测试](../../DynamicIslandTests/IslandDesignTokensTests.swift)；Renderer 已共用 Host 字体、颜色、间距和尺寸，但正式岛体的视觉与可访问性实测待 T14–T17。 |
| T11 | Presentation Model | T09 | `in progress` | [纯数据三形态](../../DynamicIsland/Core/Activity/IslandActivity.swift)、[Host 降级与高度/复杂度策略](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift)、[旧 JSON/计时三态测试](../../DynamicIslandTests/ActivityPresentationTests.swift)；同一 NSHostingView 的三态渲染测试通过。正式岛体的 Timer 平滑切换待 T14–T17 实测。 |
| T12 | IslandRenderer | T09–T11 | `verified` | [受限 SwiftUI 映射](../../DynamicIsland/IslandUI/IslandRenderer.swift)、[12 类节点/三态/152、190、200 pt 壳尺寸测试](../../DynamicIslandTests/IslandRendererTests.swift)和 [Phase 2 验证记录](phase-2-renderer-action-router.md)；`./Scripts/ci.sh` 220 tests、1 skipped、0 failures、Release build passed。 |
| T13 | ActionRouter | T12 | `verified` | [实例绑定与生命周期校验](../../DynamicIsland/IslandUI/ActionRouter.swift)、[真实计时模型适配器](../../DynamicIsland/Core/Activity/PomodoroActivityProvider.swift)、[路由](../../DynamicIslandTests/ActionRouterTests.swift)及[暂停/继续/停止闭环测试](../../DynamicIslandTests/PomodoroActivityProviderTests.swift)、[DEBUG 渲染入口](../../DynamicIsland/Core/Activity/ActivityDebugPanel.swift)与 [Phase 2 验证记录](phase-2-renderer-action-router.md)；同上 CI。 |

## Phase 3 — 内置功能迁移与 API 自测

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T14 | Music Provider | T06–T13 | `verified` | [正式 Music Activity Provider 与 Runtime](../../DynamicIsland/Core/Activity/MusicActivityProvider.swift)、[Provider/动作/抢占/封面测试](../../DynamicIslandTests/MusicActivityProviderTests.swift)、[验证记录](phase-3-t14-music-provider.md)及[用户确认的 Phase 3 真机验收](phase-3-acceptance.md)；Music 权限、真实控制、封面更新、鼠标拖动和 VoiceOver 验收完成。 |
| T15 | Volume Provider | T14 基础 | `verified` | [固定 ID、debounce、回声抑制、音乐恢复与视觉矩阵验证记录](phase-3-t15-volume-provider.md)及[用户确认的 Phase 3 真机验收](phase-3-acceptance.md)；真实 Core Audio 连续调节、输出设备变化、动画和 Reduce Motion 验收完成。 |
| T16 | Battery Provider | T14 基础 | `verified` | [IOKit 事件服务、迟滞与生命周期验证记录](phase-3-t16-battery-provider.md)、[Provider 测试](../../DynamicIslandTests/BatteryActivityProviderTests.swift)、[Service 测试](../../DynamicIslandTests/BatteryServiceTests.swift)及[用户确认的 Phase 3 真机验收](phase-3-acceptance.md)；真实电池组合、回调、沙盒和睡眠唤醒验收完成。 |
| T17 | Activity 压力与回归测试 | T14–T16 | `verified` | [100 Activity 压力、并发、性能采样及回归记录](phase-3-t17-activity-stress-regression.md)和[用户确认的 Phase 3 真机验收及统一检查](phase-3-acceptance.md)；CI 278 tests、1 skipped、0 failures，稳定性矩阵 49 tests 通过，104 张截图生成并抽查；真实多屏、睡眠唤醒、系统服务交错与 Release App 验收完成。 |

## Phase 4 — Plugin Core

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T18 | PluginManifest | T17 | `verified` | [V1 模型、严格解析、SemVer、JSON Schema 和验证记录](phase-4-t18-plugin-manifest.md)，以及 [15 项定向测试](../../DynamicIslandTests/PluginManifestTests.swift)；`./Scripts/ci.sh` 292 passed、1 skipped、0 failures，Release build passed。 |
| T19 | PluginValidator | T18 | `verified` | [静态目录校验、不可变入口快照与安全边界记录](phase-4-t19-plugin-validator.md)，以及 [14 项定向测试](../../DynamicIslandTests/PluginValidatorTests.swift)；`./Scripts/ci.sh` 306 passed、1 skipped、0 failures，Release build passed。 |
| T20 | PluginManager | T18–T19 | `verified` | [actor 串行管理、受控目录、状态持久化及回滚](../../DynamicIsland/Plugins/PluginManager.swift)、[14 项发现/启停/恢复/并发/重载/卸载/安全测试](../../DynamicIslandTests/PluginManagerTests.swift)和 [T20 验收记录](phase-4-t20-plugin-manager.md)；`./Scripts/ci.sh` 334 passed、1 skipped、0 failures，Release build passed。 |
| T21 | Plugin Lifecycle | T20 | `verified` | [六状态机、执行凭证、Runtime 合约与 Manager 生命周期验收](phase-4-t21-plugin-lifecycle.md)、[6 项状态测试](../../DynamicIslandTests/PluginLifecycleTests.swift)、[7 项环境测试](../../DynamicIslandTests/PluginLifecycleEnvironmentTests.swift)、[14 项集成测试](../../DynamicIslandTests/PluginLifecycleBridgeTests.swift)及 [Phase 4 统一检查](phase-4-acceptance.md)；`./Scripts/ci.sh` 361 passed、1 skipped、0 failures，Release build passed。实际 JS 执行按 T22 接入。 |

## Phase 5 — JavaScriptCore Runtime

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T22 | JavaScriptCore Runtime | T20 | `verified` | [独立 VM/Context、工作线程、最小 island、异常与 teardown 验收](phase-5-t22-javascript-runtime.md)、[29 项 Runtime 测试](../../DynamicIslandTests/PluginRuntimeTests.swift)及[生产 factory 测试](../../DynamicIslandTests/IslandActivityRuntimeTests.swift)；CI 391 passed、1 skipped、0 failures、Release build passed；Release 定向 30 passed，实际签名核验通过。 |
| T23 | JS Bridge | T22 | `verified` | [受控 Promise API、严格双层验证、简单 Activity、日志及隔离内存 KV 验收](phase-5-t23-js-bridge.md)、[23 项 Bridge 测试](../../DynamicIslandTests/PluginJSBridgeTests.swift)与生产 factory 测试；CI 414 passed、1 skipped、0 failures、Release build passed；Release 定向 53 passed，普通 App 签名核验通过。 |
| T24 | JS → Activity | T23 | `verified` | [受限转换、Host 降级、部分更新、动作元数据与按插件限频验收](phase-5-t24-js-activity.md)、[18 项 Activity Bridge 测试](../../DynamicIslandTests/PluginActivityBridgeTests.swift)及[真实 GitHub Mock 包](examples/github-mock/README.md)；CI 432 passed、1 skipped、0 failures、Release build passed；Release 定向 42 passed，普通 App 签名核验通过。 |
| T25 | JS → IslandNode | T23 | `verified` | [严格节点转换、三形态布局、capability/动作引用与渲染验收](phase-5-t25-js-island-node.md)、[20 项节点 Bridge 测试](../../DynamicIslandTests/PluginIslandNodeBridgeTests.swift)及[真实 Node Mock 包](examples/node-mock/README.md)；CI 452 passed、1 skipped、0 failures、Release build passed；Release 定向 44 passed，普通 App 签名核验通过。 |
| T26 | JS Action Bridge | T23 | `verified` | [会话注册、实例 / generation 绑定、有界回调与实际 SwiftUI 控件验收](phase-5-t26-js-action-bridge.md)、[18 项动作 Bridge 测试](../../DynamicIslandTests/PluginActionBridgeTests.swift)及[真实 Action Mock](examples/action-mock/README.md)；CI 470 passed、1 skipped、0 failures，Release build passed；Release 定向 91 passed，普通 App 签名通过。 |
| T27 | Plugin Storage | T23 | `verified` | [按插件隔离的持久化 KV、异步 FIFO、原子提交与会话撤销](phase-5-t27-plugin-storage.md)、[17 项存储测试](../../DynamicIslandTests/PluginStorageTests.swift)及 [Phase 5 统一检查](phase-5-acceptance.md)；CI 486 passed、2 skipped、0 failures，Release build / 签名通过；Release 定向合计 125 passed、1 skipped（锁屏真实鼠标单项）。 |

## Phase 6 — 权限、安全、能耗与稳定性

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T28 | PermissionManager | T23 | `verified` | [四态授权、包 review scope、绑定插件 / 权限的可撤销 lease](phase-6-t28-permission-manager.md)及 [17 项权限测试](../../DynamicIslandTests/PluginPermissionManagerTests.swift)；CI 503 passed、2 skipped、0 failures，Release build / 签名通过；Release 定向 107 passed。生产默认 requested，批准 UI / 持久化按 T33 扩展。 |
| T29 | NetworkBroker | T28 | `verified` | [有界 HTTPS fetch、Host 政策、可撤销准入及非阻塞 completion](phase-6-t29-network-broker.md)和 [12 项网络测试](../../DynamicIslandTests/PluginNetworkBrokerTests.swift)；CI 515 passed、2 skipped、0 failures，普通 Release build / 签名通过；Release 定向 154 passed、1 skipped（锁屏鼠标单项）。 |
| T30 | File/Clipboard Broker | T28 | `verified` | [系统文本选择、剪贴板读写分权、数据 DTO 与会话撤销](phase-6-t30-file-clipboard-broker.md)及 [17 项资源测试](../../DynamicIslandTests/PluginUserResourceBrokerTests.swift)；CI 533 passed、1 skipped、0 failures，普通 Release build / 签名通过；Release 定向合计 113 passed、0 skipped。选择器使用 Host fixture、剪贴板使用私有命名实例，未声称真实系统选择器交互验收。 |
| T31 | PluginScheduler | T22 | `pending` | 待补。 |
| T32 | Crash Watchdog / Logging | T22 | `pending` | 待补。 |

## Phase 7 — 安装、管理与官方验证插件

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T33 | Extensions Settings UI | T20 | `pending` | 待补。 |
| T34 | .dip Installer | T19、T28 | `pending` | 待补。 |
| T35 | Pomodoro 官方插件 | T24–T34 | `pending` | 待补。 |
| T36 | GitHub 官方插件 | T35 | `pending` | 待补。 |

## Phase 8 — SuperIsland Compatibility

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T37 | SuperIsland Adapter | T35 | `pending` | 待补。 |

## Phase 9 — SDK、文档与插件生态

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T38 | DynamicIsland SDK | T36 | `pending` | 待补。 |
| T39 | 开发者文档与模板 | T38 | `pending` | 待补。 |
| T40 | Plugin Registry | T38 | `pending` | 待补。 |
