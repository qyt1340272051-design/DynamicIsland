# Phase 6 — T31 PluginScheduler

日期：2026-10-12。依赖 T22 已验收。实现与自动化验证完成；正式 App 多插件安装后的长时能耗验收保留。

## API、策略与准入

```javascript
// The Promise completes when the Host admits this one-shot refresh.
await island.scheduler.requestRefresh(60000);
await island.activity.update({id: 'status', presentation: {title: 'Refreshed'}});
```

冻结的 `island.scheduler` namespace 提供 `apiVersion=1.0.0`、supported=true 和单次 `requestRefresh(delayMs)`；需要 `scheduler` capability，不自动授予任何 Broker 权限。参数仅接受 1000...86400000 的整数毫秒，Host 独立拒绝未知字段、伪造 owner 与过期执行 context。返回冻结 null-prototype `{policy}`。

| 策略 | 最短间隔 | 向后合并粒度 |
| --- | --- | --- |
| active | 1 秒 | 1 秒 |
| background | 30 秒 | 5 秒 |
| lowPower | 60 秒 | 15 秒 |

最短间隔是 Host 强制下限，不是准点执行保证。切换到更严格策略会从切换时刻延后现有请求；恢复 active 保留已延后的截止时间，不突发补发错过的 tick。每插件 1 项、全局 128 项，没有等待队列、每 VM Timer、100 ms 轮询或 recurring catch-up。JavaScriptCore 没有提供 setTimeout / setInterval；绕过 SDK 的无限计算仍不在调度器的抢占范围内。

所有插件共享一个最近截止时间的 Host Task，无待办时没有计时器。单调 systemUptime 是生产时钟；测试可注入时钟并手动 pump。App 活跃状态和系统 Low Power Mode 通知驱动策略，不增加轮询。ActivityScheduler 与此类独立：前者控制 Activity 过期，后者只控制插件请求的后台刷新。

ResourceAdmission 同步取消成功交付资格，MainActor 再移除该旧执行的待办；停用、卸载、睡眠、低电池生命周期暂停和直接 teardown 都覆盖。旧任务不能触发替换 VM。Bridge 的 FIFO 只等待参数与准入，刷新未到期时 storage、Activity、动作继续处理。生产 IslandActivityRuntime 共享同一个 Scheduler；App 结束停止环境 observer、生命周期和截止任务。

## 验证与能耗边界

[`PluginSchedulerTests`](../../DynamicIslandTests/PluginSchedulerTests.swift) 18 项覆盖严格解析 / JS wrapper、策略合并、配额、取消与旧会话、通知 generation、真实 JS → Core、慢刷新不挡存储 / Activity 和真实自动计时器。另加生产共享 Scheduler / shutdown 测试。中间定向 26 passed（17 项调度 + 9 项已有生产 Runtime）；全量 CI 执行 CPU 观测与新增生产测试。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 553 total、552 passed、1 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t31-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t31-final-ci.log`。 |
| 20 真实 VM 空闲 CPU | 基线 10 秒用 CPU 0.032300 秒（单核心 0.323%）；20 VM 10 秒 0.040869 秒（0.409%），差 0.086 个百分点。20 项 60 秒刷新共享 1 个 Host timer，观察窗口额外调度唤醒 0。 | 同上日志的 `T31_IDLE_CPU` 与 xcresult 附件。 |
| Release 定向 | 17 项调度 + 生产共享调度 / 原 factory 共 19 passed、0 skipped、0 failures。CPU 观测已在完整 CI 执行，没有重复采样。 | `/tmp/dynamic-island-t31-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t31-release-tests.log`。 |
| 普通 Release 签名 | strict / deep 核验通过；Sandbox / allow-jit 均为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t31-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t31-release-entitlements.plist`。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。CPU 数字来自 XCTest Host 进程的 getrusage，观察窗口内没有 VM 轮询或测试 eval；这能支持空闲 CPU 接近基线和没有额外周期唤醒，不能替代正式 App 安装多个插件后的长时 Energy Impact / 实际电耗测量。唯一 CI skip 为原截图生成，Release 测试宿主的注入 / library-validation 例外只在临时测试目录启用，普通 App 无该例外。

因此 T31 状态保留 `in progress`，不把短 CPU 观测标作完整能耗验收。后续独立任务 T32 / T33 按其直接依赖继续，T35 的范围依赖应在剩余验收关闭后复核。

2026-10-14 已执行实际安装 20 个插件的两段约 15 分钟观测，[原始计数与验收缺口](evidence/t31-energy-20261014.md)已保存。运行组日志返回非 background 策略，因此未关闭 T31；下一次先证明实际后台调度，再采样和逐插件核对整段刷新记录。T35 的[迁移准备](t35-migration-preparation.md)仅为审计方案，尚未实施。

同日后续通过 [Host 状态诊断定位并修正前台判定](evidence/t31-foreground-policy-20261014.md)：NSApp 活跃标志为 true、实际前台为其他进程时已返回 background，实际 JS 连续 INFO。全量 CI 703 total / 702 passed / 1 skipped，Release build passed；长时重测仍待完成。
