# Plugin System Development Progress

本表追踪 [插件系统开发计划](DevelopmentPlan.md) 中的 T01–T40。Phase 0 是准备阶段；Phase 1–9 是九个实施阶段。任务名称与前置依赖以计划原文的「任务总表」为准。

0.6.0 是当前开发版本；目前不将它擅自对应到计划中的 Plugin Alpha、Plugin Beta 或 Plugin 1.0 验收门槛。版本范围应在相应任务和验收结果明确后确定。

## 状态与验收规则

- `pending`：尚未开始。
- `in progress`：已有审计、设计、实现或验证工作，但尚未满足计划原文的完成标准。
- `verified`：满足计划原文对应任务的完成标准，并在本表的「验收证据」列链接可审查的证据。证据至少说明实现或审计产物、执行的验证及结果；涉及 UI、性能、能耗或设备行为的任务还应记录相应实测环境和结果。仅有代码或一次构建成功不足以将任务标为 `verified`。

依赖列中的 `Txx–Tyy` 表示该范围内的全部任务；`T14 基础` 沿用原计划表述。任务开始与验收前必须满足任务总表列出的直接前置依赖；每个阶段结束时，按计划的「每个阶段的统一检查清单」复核旧功能、架构、并发、性能、能耗、安全、隐私、兼容、测试和回滚，并链接阶段验收记录。后续任务通过不会自动关闭仍为 `in progress` 的旧任务，其额外证据缺口继续在原任务中独立追踪。

## 2026-10-17 人工验收安排调整（历史）

用户明确要求「需要我操作的部分先跳过,统计好下次我再来处理」。因此仅将需要物理指针 / 设备配合的门槛延期到[统一人工清单](MANUAL_ACCEPTANCE.md)，允许后续任务先推进可自动完成的开发与验证；本条是用户对上述开始依赖规则的本次例外。原依赖列与未通过任务的状态保留，不能以跳过代替验收。当时共 2 组 / 最多 3 个指针动作（T35 两步，T36 一步）；T35 的 0.2.1 已自然完成一轮约 900.9 秒，但短暂完成提示漏拍，用户选择「留待下次」后副本[正常退出并保留数据](evidence/t35-v021-final-20261017/cleanup.json)。当时 T35 / T36 实机门槛延期，T39 新作者首次安装走查另行保留；后续结果见下段。

## 2026-10-19 Phase 7 集中人工验收完成

[T35 / M01](evidence/t35-manual-20261019/result.json)已捕获真实十五分钟自然到期的安全两翼提示、正常消失与不自动重开；[T36 / M02](evidence/t36-manual-20261019/result.json)已通过真实导入、三项独立授权、公开 CI / PR、仓库切换 / 刷新及系统浏览器 Open。两个独立副本均正常退出且 Staging 为空；[六项真实输入补验](evidence/native-input-20261019/result.json)为 6 passed / 0 skipped / 0 failures。T35、T36 标为 verified，任务内延期门槛已关闭，完整范围见[Phase 7 统一检查](phase-7-acceptance.md)。本次实机使用已记录身份的历史独立普通 Release，不能称为当前 HEAD 二进制验收；相关源码与后续自动回归分别保留。T39 新作者体验、T37 上游兼容、T38 稳定发布及 T40 公网安装门槛仍独立追踪。

## 2026-10-19 本轮收尾

当前 **34 项 verified、6 项 in progress**。T08 / T10 的后续证据已归并；T02、T11、T37、T38、T39、T40 保留各自未通过门槛。用户最新要求「现在不方便，先跳过人工操作」，下次集中处理[人工清单 M03–M05](MANUAL_ACCEPTANCE.md)。普通 Release 隔离副本已安装启用五个无额外权限示例，现已正常退出并保留状态。

本轮完整 CI 1070 passed / 2 skipped / 0 failures，普通 Release 构建通过；随后新增的独立作者原包 Host 集成另跑 8 项全通过，SDK 归档审阅修复后 Python 40 项及类型检查通过。各批次分别留存，不合并成一次全量结果。SDK 与官方插件公开发布、正式 Registry 目录及公网安装尚未执行。 [提交前检查](evidence/final-review-20261019/README.md)已核对当前源码摘要、最新 SDK、结构化证据及本轮本地链接。

## Phase 0 — 准备阶段：项目审计、分支与基线

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T01 | 项目架构审计 | 无 | `verified` | [Phase 0 基线记录](phase-0-baseline.md)记录了真实依赖图、职责边界、迁移调用点、多屏约束及审计结论。 |
| T02 | 开发分支与基线测试 | T01 | `in progress` | [Phase 0 基线记录](phase-0-baseline.md)保留分支与清单；[本日真实基线](t02-t08-acceptance-20261019.md)已完成普通 Release 启动、菜单和退出、300 秒静置及 303.534 秒量化采样，平均单核 CPU 1.4387%、物理内存峰值 27.49 MiB。功能 / 设备场景采用 Phase 3 历史真实验收；当前只剩菜单隐藏 / 显示确认。采样是本轮修正前冻结起点，不冒称新 UI 或重构前后对照。 |

## Phase 1 — Activity Engine

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T03 | IslandActivity | T01 | `verified` | [纯数据模型](../../DynamicIsland/Core/Activity/IslandActivity.swift)与 [Music/Battery/Download 构造和 Codable 测试](../../DynamicIslandTests/IslandActivityTests.swift)；`./Scripts/ci.sh` 170 tests、1 skipped、0 failures、Release build passed。 |
| T04 | ActivityPriority | T03 | `verified` | [有限优先级及默认映射](../../DynamicIsland/Core/Activity/ActivityPriority.swift)、[确定性排序测试](../../DynamicIslandTests/ActivityPriorityTests.swift)；同上 CI。 |
| T05 | ActivityLifecycle | T03 | `verified` | [状态转换与行为策略](../../DynamicIsland/Core/Activity/ActivityLifecycle.swift)、[dismiss/ended/恢复/过期测试](../../DynamicIslandTests/ActivityLifecycleTests.swift)；同上 CI。 |
| T06 | ActivityManager | T03–T05 | `verified` | [单写入口](../../DynamicIsland/Core/Activity/ActivityManager.swift)、[DEBUG Provider 与只读观察窗口](../../DynamicIsland/Core/Activity/ActivityDebugPanel.swift)、[同一 NSHostingView 的发布/更新/结束渲染测试](../../DynamicIslandTests/ActivityDebugPanelTests.swift)；`./Scripts/ci.sh` 190 tests、1 skipped、0 failures、Release build passed。 |
| T07 | Priority Queue | T06 | `verified` | [确定性队列](../../DynamicIsland/Core/Activity/ActivityQueue.swift)和 [抢占/恢复测试](../../DynamicIslandTests/ActivityQueueTests.swift)；同上 CI。 |
| T08 | Activity Scheduler | T07 | `verified` | [集中截止任务](../../DynamicIsland/Core/Activity/ActivityScheduler.swift)与 [20 事件 / critical 等测试](../../DynamicIslandTests/ActivitySchedulerTests.swift)覆盖策略；[归并验收](t02-t08-acceptance-20261019.md)将 Phase 3 用户已确认的真实百事件压力、抢占 / 恢复动画对应原完成标准。本日真实空闲计数及独立复算另行归档，不将历史定性动画写成本日帧率或功耗对照。 |

## Phase 2 — IslandNode、Renderer 与动作路由

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T09 | IslandNode | T03 | `verified` | [受限数据节点与 JSON 校验](../../DynamicIsland/IslandUI/Schema/IslandNode.swift)、[计时/构建/音乐树及恶意输入测试](../../DynamicIslandTests/IslandNodeTests.swift)；6 项定向测试通过。 |
| T10 | DesignTokens | T09 | `verified` | [统一 token](../../DynamicIsland/IslandUI/DesignTokens.swift)与[对比度 / 尺寸测试](../../DynamicIslandTests/IslandDesignTokensTests.swift)保持 Host 视觉词汇；[本日归并](t10-t11-acceptance-20261019.md)核对两款官方插件真实截图的一致字体、按钮和间距，并引用 Phase 3 已确认的 VoiceOver / Reduce Motion。原始截图与来源 hash 保留，不声称新做全系统外观矩阵。 |
| T11 | Presentation Model | T09 | `in progress` | [纯数据三形态](../../DynamicIsland/Core/Activity/IslandActivity.swift)、[Host 策略](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift)已补明确 minimal 回退；正式 IslandView 将 minimal 放在相机安全右翼，保留同实例 Renderer 与计时解析。修正测试时序与几何像素筛选后，定向 24 passed / 0 skipped / 0 failures，原始图标距相机边缘 12pt，见[记录](t10-t11-acceptance-20261019.md)。真实倒计时三态及连续物理界面验收继续保留。 |
| T12 | IslandRenderer | T09–T11 | `verified` | [受限 SwiftUI 映射](../../DynamicIsland/IslandUI/IslandRenderer.swift)、[12 类节点/三态/152、190、200 pt 壳尺寸测试](../../DynamicIslandTests/IslandRendererTests.swift)和 [Phase 2 验证记录](phase-2-renderer-action-router.md)；`./Scripts/ci.sh` 220 tests、1 skipped、0 failures、Release build passed。 |
| T13 | ActionRouter | T12 | `verified` | [实例绑定与生命周期校验](../../DynamicIsland/IslandUI/ActionRouter.swift)、[路由及旧实例 / 权限测试](../../DynamicIslandTests/ActionRouterTests.swift)、[DEBUG 渲染入口](../../DynamicIsland/Core/Activity/ActivityDebugPanel.swift)与 [Phase 2 历史验证记录](phase-2-renderer-action-router.md)；当时 CI 同上。历史原生计时适配器及其闭环测试已在 T35 迁移时删除，当前公开插件的暂停 / 继续 / 停止闭环见 [Pomodoro VM / Router 集成测试](../../DynamicIslandTests/PomodoroPluginTests.swift)与[迁移记录](phase-7-t35-pomodoro.md)。 |

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
| T31 | PluginScheduler | T22 | `verified` | [集中刷新、三种策略与会话取消](phase-6-t31-plugin-scheduler.md)；[真实前台判定修正](evidence/t31-foreground-policy-20261014.md)后 CI 702 passed、1 skipped、0 failures，普通 Release build / 签名通过。[20 个真实后台插件、同进程两组各约 15 分钟验收](evidence/t31-background-20261014.md)：每项 14 次 INFO、无 WARNING / ERROR，CPU 1.560% → 1.944%，归属 CPU 功率 1.695 → 3.087 mW；原始计数、完整 AX 页及单机空闲场景边界已保存。 |
| T32 | Crash Watchdog / Logging | T22 | `verified` | [会话 / 包绑定的 60 秒隔离窗口、持久化、隐私日志及诊断 / 重启窗口](phase-6-t32-crash-watchdog-logging.md)；新增 45 项 Watchdog / diagnostics / persistence / UI / 实际 JS 集成测试，CI 597 passed、1 skipped、0 failures，普通 Release build / 签名通过；Release 定向 131 passed。无限循环 VM 的强制抢占不在本任务能力范围内。 |

[Phase 6 统一检查](phase-6-acceptance.md)已完成；真实系统选择器、多设备及电池 / 低功耗 / 长期内存等边界仍单独保留，不关闭早期未验收任务。

## Phase 7 — 安装、管理与官方验证插件

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T33 | Extensions Settings UI | T20 | `verified` | [管理页与持久化分项授权验收](phase-7-t33-extensions-settings.md)；模型 / 存储 / 并发定向 91 passed，原生 UI 3 passed，完整 CI 647 passed、1 skipped、0 failures，普通 Release build / 签名通过；Release 定向合计 149 passed。Discover 按计划后置。 |
| T34 | .dip Installer | T19、T28 | `verified` | [.dip 格式](dip-format.md)与[验收记录](phase-7-t34-installer.md)：App 内导入 / 预览 / disabled 安装 / 实际启停卸载通过；解包 17、事务 19、UI model 12、UI 2，CI 698 passed、1 skipped、0 failures，Release 150 passed。[正常应用目录的 Finder 冷启动与预览取消验收通过](evidence/t34-finder-20261014.md)，临时构建目录的候选差异已查明，原 App 与默认设置保留。 |
| T35 | Pomodoro 官方插件 | T24–T34 | `verified` | [公开 API 迁移与分项验证](phase-7-t35-pomodoro.md)已完成，全部 Pomodoro 专用生产 Swift 已删除；计时 / 预设 / Storage / Scheduler、拒绝 / 撤销、重启只恢复设置、旧页面与收起重选见历史证据。0.2.1 已[升级并独立重审授权](evidence/t35-v021-ui-20261017/result.json)，[2026-10-19 真实最终验收](evidence/t35-manual-20261019/result.json)在开始后 900.836–900.93 秒首次观察到完成 AX，并用后续实际绘制帧确认左图标 / 右「完成」安全两翼、单次提示正常消失且不重开；[正常退出](evidence/t35-manual-20261019/cleanup.json)确认 PID 80223 消失、Staging 为空并保留 completed 设置 / 授权。实际 Host 为历史独立普通 Release，非当前 HEAD，见[来源边界](evidence/t35-manual-20261019/host-provenance.json)。 |
| T36 | GitHub 官方插件 | T35 | `verified` | [公共 Links API](t36-links-api.md)及[公开 API 插件](phase-7-t36-github.md)只使用公开 Host 能力；[历史自动验证](evidence/t36-github-20261017/result.json)完整 CI 919 passed / 7 skipped / 0 failures、Release build passed，真实匿名 API 选测 1 passed / 0 skipped / 0 failures。[2026-10-19 实机验收](evidence/t36-manual-20261019/result.json)通过真实导入、安装后停用 / 三项待授权、逐项批准再启用、公开 CI / PR 五行、仓库切换 / 刷新、Safari 实际构建 / PR 目标、撤销失败提示与重新批准后的新点击；[退出归档](evidence/t36-manual-20261019/cleanup.json)确认 PID 82621 消失、Staging 为空，仓库与三项授权保留。Host 为[历史独立普通 Release](evidence/t36-manual-20261019/preflight.json)，不等同于 HEAD；T35 前置已满足。 |

[Phase 7 统一检查](phase-7-acceptance.md)已归并 T33–T36 的自动、历史 UI 与本日实机证据，阶段任务均 verified。历史独立 Host / 当前源码与设备、性能、能耗范围分别保留，不扩大为当前 HEAD 全量产品或 0.6.0 发布验收。

## Phase 8 — SuperIsland Compatibility

2026-10-19 用户已明确选定本版范围：交付兼容子集，用独立编写的简单插件完成实机验收。[原创示例](t37-independent-examples.md)按该范围验证；原样上游的许可与能力差距继续列为限制，不将其冒称已解决。

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T37 | SuperIsland Adapter | T35 | `in progress` | [六类 View](phase-8-t37-view-conversion.md)、[显式模式](phase-8-t37-manifest-profile.md)、[同 VM 模块](phase-8-t37-module-runtime.md)、[Host 展示请求](t37-presentation-requests.md)及[兼容详情](t37-compatibility-details.md)均已实现并保留历史自动证据。本日按用户选定范围新增[三个原创示例](t37-independent-examples.md)，真实源码通过 Validator / VM / Router 集成，覆盖共享动作名隔离、同实例更新、停用旧动作与 critical 抢占；完整回归见[本日结果](evidence/final-regression-20261019/result.json)。三个包已在普通 Release 隔离副本实际导入、安装后停用并分别启用，无额外权限；工具界面与真实按钮验收待完成。原样上游许可 / 能力差距继续作为限制，不计入本版通过范围。 |

## Phase 9 — SDK、文档与插件生态

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T38 | DynamicIsland SDK | T36 | `in progress` | [历史实验草案](phase-9-t38-sdk-draft.md)之后已完成[SDK 1.0.0 发布候选复核](t38-stability-review-20261019.md)：有限 API / 版本策略、完整许可、可重复独立 ZIP、源文件摘要、离线工具 / 模板与脱仓库验证。当前 SDK Python 40 passed、类型及 47 项预期错误通过；[完整回归](evidence/final-regression-20261019/result.json)中正式 Host SDK / 文档契约通过。随后将独立 AI 作者原始双按钮包送入正式 Host，含既有契约共[8 项通过](t38-independent-host-20261019.md)，验证同实例与生命周期。归档扫描错误已修正，最新候选摘要及历史区别见[最终分发证据](evidence/t38-final-audit-20261019/result.json)。T35 / T36 实机前置已满足，正式公开发布仍保留；AI 自动结果不替代真人或物理界面。 |
| T39 | 开发者文档与模板 | T38 | `in progress` | [13 主题手册](../../SDK/docs/README.md)及[T39 记录](phase-9-t39-developer-docs.md)保留 15 页 / 9 个源码块 / 33 条链接与正式 Host 契约。本日用户首轮 zsh 卡点已修正，[协助功能复测通过](evidence/t39-manual-20261019/result.json)，未冒称首轮独立成功。全新上下文 AI 作者仅按独立 SDK 在 137.7 秒完成 Hello 与原创双按钮包的离线校验 / 打包，未读 App Swift，见[独立资料走查](evidence/t39-independent-20261019/result.json)；其 README receipt 歧义已修正。AI 离线结果不计作真人十分钟安装体验；修正版无额外指导复测及 T38 发布门槛仍保留。 |
| T40 | Plugin Registry | T38 | `in progress` | [目录核心](phase-9-t40-registry-core.md)与[发现 UI](phase-9-t40-registry-ui.md)已完成，复用正式解包 / 安装 / 权限流程；[本日完整回归](evidence/final-regression-20261019/result.json)为 1070 passed / 2 skipped / 0 failures，普通 Release build passed。[发布准备](t40-release-preparation-20261019.md)已生成附 MIT 许可的两款官方包、固定摘要与候选目录，独立重打字节一致。正式 [registry.json](../../Registry/registry.json)仍为空，未登记不存在的下载地址；公开 Release / 目录发布、真实网络安装与 T38 依赖继续保留。 |

[Phase 9 统一检查](phase-9-acceptance.md)已归并当前自动开发证据及剩余门槛；T38–T40 继续保持 `in progress`，不等同于稳定 SDK 或 Plugin 1.0 发布验收。
