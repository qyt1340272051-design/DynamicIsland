# T31 — 实际后台插件空闲 CPU / 能耗验收

日期：2026-10-14。普通 Release 源码 `da52f69`。本轮固定前台判定修正后的二进制与外部 sampler，完成同一进程的停用 / 运行两段实测，并核对全部 20 个插件的后台刷新。因此 **T31 标为 verified**；本结论限于本页记录的空闲工作负载。

## 条件与数据来源

arm64 MacBook Air，macOS 26.6.2（25G83）。生产 Release 的隔离副本保留 Sandbox、hardened runtime、allow-jit，无 get-task-allow / disable-library-validation；严格签名检查通过。使用独立 bundle ID，移除副本文档类型声明，避免竞争 `.dip` handler。原 App PID 66831 一直保留。

20 个 audited 1.0.1 包由此前生产 Installer / Manager 安装事务创建，本轮恢复至同一隔离容器。真实管理 UI 先逐个停用，再逐个启用，保存了 [全部停用](t31-background-20261014/ui-disabled.json)与[全部运行](t31-background-20261014/ui-enabled.json)的实际 AX 状态；没有直接改写启用状态 JSON。两组均关闭管理 / 诊断窗口，compact 岛体可见，暖机后采样。运行组预检已返回 [background / 连续 INFO](t31-background-20261014/running-preflight.json)。

两段均为 PID 76335、相同进程起始时间 / executable UUID / SHA256。源码、Release、sampler 在测量前冻结；窗口内没有构建或测试。外部采样器每 5 秒读取进程计数，使用包含睡眠的 `mach_continuous_time`；Mach CPU tick 按 `125/3` timebase 换算。身份变化、计数回退、退出或采样间隔超过 15 秒均拒绝窗口。独立复算 [CPU / 能耗 / 时间边界](t31-background-20261014/counter-review.json)与原汇总一致，最大采样间隔 5.336 秒以内。

准备和结束的 `pmset` 均为 AC Power、100%、lowpowermode=0；每段仅以 `caffeinate -di` 防止空闲睡眠，没有修改电源设置。[电源记录](t31-background-20261014/measurement-setup.json)、[结束控制](t31-background-20261014/end-controls.json)、[睡眠日志复核](t31-background-20261014/sleep-wake-review.json)未发现覆盖两段测量时段的 Sleep / Wake。

## 结果

时间为 Asia/Shanghai；原始采样同时保留 UTC。

| 指标 | 20 installed / disabled | 20 enabled / running |
| --- | --- | --- |
| 测量时间 | 21:17:24–21:32:25 | 21:41:28–21:56:29 |
| 时长 / 样本数 | 901.195 秒 / 173 | 900.563 秒 / 173 |
| 平均单核心 CPU | 1.5598% | 1.9437% |
| P95 / 最大区间 CPU | 1.8259% / 1.9362% | 3.2097% / 3.6598% |
| 归属进程的 CPU 能耗 | 1.5279 J | 2.7800 J |
| 等效平均 CPU 功率 | 1.6954 mW | 3.0869 mW |
| package idle wakeups / 分钟 | 618.11 | 415.47 |
| interrupt wakeups / 分钟 | 1838.23 | 1913.20 |
| 峰值 physical footprint | 48.80 MiB | 149.19 MiB |
| 磁盘读取 / 写入 | 0 / 0 bytes | 3612672 / 0 bytes |

平均 CPU 增加 **0.3839 个百分点，相对约 24.6%**；归属 CPU 功率增加 **1.3915 mW，相对约 82.1%**。计划没有数值门限。本次工程判断依据是约 2% 的单核心平均 CPU、较小的绝对 CPU 能耗增量，以及下述完整低频后台刷新证据，接受本工作负载的空闲开销接近基线。相对能耗增长仍需保留，不能称为没有额外耗电。

运行组 footprint 从 85.42 MiB 至 94.42 MiB，期间峰值更高；不据此断言 GC 原因或长期内存稳定。package idle wakeups 下降也不能单独归因于合并机制；interrupt wakeups 增加约 75 / 分钟。

[Activity Monitor 实际 AX 行](t31-background-20261014/energy-observations.json)记录停用中段 21:21:50 的 Energy Impact 1.5、停用结束后 21:34:03 的 1.9；运行开始前 21:41:16 为 3.6、中段 21:47:34 为 5.0、结束后 21:58:01 为 2.2。这些是离散相对评分，不能当作窗口均值或换算焦耳；同一行的 12 小时历史列未用于比较。

## 全部 20 项的真实后台覆盖

[审计 fixture](t31-background-20261014/audited-fixture.js)仅调用公开 `island.scheduler.requestRefresh(60000)` 和 `island.log`：初始 DEBUG，成功 background 为 INFO，active / lowPower 为 WARNING，拒绝为 ERROR，最多 40 次。每次日志回执后再申请刷新，无 VM timer、网络、存储或额外权限。本轮采样发生在各 VM 的 40 次上限之前。

结束后从诊断 UI 逐个滚动到测量开始之前，保留 [实际工具输出](t31-background-20261014/log-exports.json)及[解码 AX 页](t31-background-20261014/decoded-log-pages.json)。部分输出将固定重复句替换为 U+0001，编码规则与原 JSON 均保留，复算验证解码再编码完全一致；没有重构或补写原始日志正文。T32 仍隐藏插件正文，策略判定仅依据经审查 fixture 的日志级别。

[窗口日志 CSV](t31-background-20261014/window-plugin-logs.csv)按插件、时间、级别及固定类别 / 代码去重，排除采样前后记录。20 项均各有 **14 条 INFO，共 280 条**，窗口中 WARNING / ERROR 为 0；相邻间隔 64–66 秒，最大 66 秒。全部采集时 running，Host 快照 background、非前台、低功耗关。[逐插件覆盖汇总](t31-background-20261014/log-coverage.json)保留首末边界。检查条件是至少 13 次且间隔 / 边界余量不超过 75 秒，用于证明实验覆盖完整，不是新设产品性能门限。

## 限制与阶段衔接

- 一台机器、一次顺序对照、每组约 15 分钟，没有重复测量或置信区间。
- 20 个同类 scheduler-only 插件且含稀疏审计日志，不代表任意网络、存储、UI 或重计算插件。
- 内核 CPU 归属能耗不包含整机、GPU、屏幕、网络或电池实际电耗。AC / lowPower=0 的本轮结果不验收低功耗、电池及睡眠唤醒的长期能耗。
- T02 / T08 等旧任务的设备、动画或长期性能缺口独立保留。不会因 T31 关闭而一并接受。

源码修正完整 CI 为 **703 total / 702 passed / 1 skipped / 0 failures**，普通 Release build passed。前台 observer、generation 失效及诊断测试详见[修正证据](t31-foreground-policy-20261014.md)。本次之后仅补证据 / 文档，没有重复 CI。[结果及文件 SHA256](t31-background-20261014/result.json)、[基线 raw JSONL](t31-background-20261014/disabled.jsonl)、[运行 raw JSONL](t31-background-20261014/running.jsonl)、对应 CSV / summary / sampler 源码均已纳入仓库；旧失败窗口仍保留为拒绝证据。

可复算证据，不需重新运行 App 或采样：在仓库根目录执行以下命令，输出目录必须不存在或为空，输入证据不会覆盖。

```sh
python3 docs/plugin-system/evidence/t31-background-20261014/analyze-evidence.py \
  --output-dir /tmp/dynamic-island-t31-evidence-review
```

验收 App 正常退出并从 LaunchServices 注销，自建副本和 20 项测试数据归档到临时目录；原 PID 66831 仍运行，原 Installed 为 0、Staging 为空。活动监视器恢复 CPU 页 / 空搜索，[清理记录](t31-background-20261014/cleanup.json)可复核。没有改变默认 handler、发布版本或生成 DMG。

T24–T34 现在均已 verified，T35 可以开始实施，仍需按[迁移准备](../t35-migration-preparation.md)完成公共能力、JS 插件、专用 Swift 删除与真实安装 / UI 验收。

计量口径参考 [Apple XNU recount](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.h)、[rusage 填充](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)和[Activity Monitor 能耗说明](https://support.apple.com/guide/activity-monitor/actmntr43697/mac)。
