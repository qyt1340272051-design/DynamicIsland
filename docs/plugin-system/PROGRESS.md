# Plugin System Development Progress

本表追踪 [插件系统开发计划](DevelopmentPlan.md) 中的 T01–T40。Phase 0 是准备阶段；Phase 1–9 是九个实施阶段。任务名称与前置依赖以计划原文的「任务总表」为准。

0.6.0 是当前开发版本；目前不将它擅自对应到计划中的 Plugin Alpha、Plugin Beta 或 Plugin 1.0 验收门槛。版本范围应在相应任务和验收结果明确后确定。

## 状态与验收规则

- `pending`：尚未开始。
- `in progress`：已有审计、设计、实现或验证工作，但尚未满足计划原文的完成标准。
- `verified`：满足计划原文对应任务的完成标准，并在本表的「验收证据」列链接可审查的证据。证据至少说明实现或审计产物、执行的验证及结果；涉及 UI、性能、能耗或设备行为的任务还应记录相应实测环境和结果。仅有代码或一次构建成功不足以将任务标为 `verified`。

依赖列中的 `Txx–Tyy` 表示该范围内的全部任务；`T14 基础` 沿用原计划表述。每个阶段结束时，按计划的「每个阶段的统一检查清单」复核旧功能、架构、并发、性能、能耗、安全、隐私、兼容、测试和回滚，并链接阶段验收记录。未满足前置阶段的验收门槛时，不进入后续阶段的正式验收。

## Phase 0 — 准备阶段：项目审计、分支与基线

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T01 | 项目架构审计 | 无 | `verified` | [Phase 0 基线记录](phase-0-baseline.md)记录了真实依赖图、职责边界、迁移调用点、多屏约束及审计结论。 |
| T02 | 开发分支与基线测试 | T01 | `in progress` | [Phase 0 基线记录](phase-0-baseline.md)记录开发分支、自动化基线和重复检查清单；真实启动、空闲资源及设备场景待测。 |

## Phase 1 — Activity Engine

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T03 | IslandActivity | T01 | `in progress` | 纯数据模型与测试开发中，待满足三类 Activity 构造和序列化验收。 |
| T04 | ActivityPriority | T03 | `pending` | 待补。 |
| T05 | ActivityLifecycle | T03 | `pending` | 待补。 |
| T06 | ActivityManager | T03–T05 | `pending` | 待补。 |
| T07 | Priority Queue | T06 | `pending` | 待补。 |
| T08 | Activity Scheduler | T07 | `pending` | 待补。 |

## Phase 2 — IslandNode、Renderer 与动作路由

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T09 | IslandNode | T03 | `pending` | 待补。 |
| T10 | DesignTokens | T09 | `pending` | 待补。 |
| T11 | Presentation Model | T09 | `pending` | 待补。 |
| T12 | IslandRenderer | T09–T11 | `pending` | 待补。 |
| T13 | ActionRouter | T12 | `pending` | 待补。 |

## Phase 3 — 内置功能迁移与 API 自测

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T14 | Music Provider | T06–T13 | `pending` | 待补。 |
| T15 | Volume Provider | T14 基础 | `pending` | 待补。 |
| T16 | Battery Provider | T14 基础 | `pending` | 待补。 |
| T17 | Activity 压力与回归测试 | T14–T16 | `pending` | 待补。 |

## Phase 4 — Plugin Core

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T18 | PluginManifest | T17 | `pending` | 待补。 |
| T19 | PluginValidator | T18 | `pending` | 待补。 |
| T20 | PluginManager | T18–T19 | `pending` | 待补。 |
| T21 | Plugin Lifecycle | T20 | `pending` | 待补。 |

## Phase 5 — JavaScriptCore Runtime

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T22 | JavaScriptCore Runtime | T20 | `pending` | 待补。 |
| T23 | JS Bridge | T22 | `pending` | 待补。 |
| T24 | JS → Activity | T23 | `pending` | 待补。 |
| T25 | JS → IslandNode | T23 | `pending` | 待补。 |
| T26 | JS Action Bridge | T23 | `pending` | 待补。 |
| T27 | Plugin Storage | T23 | `pending` | 待补。 |

## Phase 6 — 权限、安全、能耗与稳定性

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T28 | PermissionManager | T23 | `pending` | 待补。 |
| T29 | NetworkBroker | T28 | `pending` | 待补。 |
| T30 | File/Clipboard Broker | T28 | `pending` | 待补。 |
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
