# Phase 3 — T17 Activity 压力与回归验证记录

日期：2026-09-29。范围：T17 Activity 压力与回归测试的自动化部分。状态保持 `in progress`；本记录不会把模拟测试当作真实多屏、睡眠唤醒、系统服务或动画性能验收。

## 压力场景与状态不变量

- 使用可控 `ActivityClock` 在同一时间点模拟 100 个 Activity 的 publish、update、end，覆盖单实例更新、抢占、逐层恢复及最终排空。每次 update 保留原实例令牌，结束全部短时事件后恢复原 Music 实例。
- 同一秒注入多个不同 source 和不同优先级的事件，验证 critical → important → normal → background 的顺序稳定；被抢占 Activity 恢复时继续使用原实例及更新后的内容。
- 默认策略下连续注入 100 个 normal transient，队列仍限制为 8 个；绝对过期与 8 秒排队年龄到达后均能清理，critical 仍可及时展示。
- 反复改期只保留一个 Scheduler 截止时间；最后一个 Activity 结束后取消截止。后台调用通过 `@MainActor` 写入口串行化，压力结束后 `current` 与 `currentSnapshot` 同时为空。
- Manager 增加只读内部诊断快照，测试直接核对 Activity、实例令牌、展示截止、首次展示时间、source 限频记录及 Scheduler 截止是否回到预期基线。

## 压力测试发现并修复的问题

`ActivityManager` 原先会为每个展示过的 source 永久保留 `lastPresentedAt`，即使该 source 没有配置限频且对应 Activity 已经结束。插件使用大量一次性 source 时，这个字典会持续增长。

现在只为 `minimumIntervalBySource` 中配置了正间隔的 source 记录最后展示时间。100 个一次性 source 逐一发布和结束后，Activity、令牌、展示时钟、source 记录及调度截止均归零；已配置 source 的限频语义保持不变。

回归矩阵还发现截图生成器为 104 张图片分别创建临时 `NSWindow`，运行到第 101 个时触发 AppKit 活跃窗口数量警告。生成器现在复用一个离屏窗口并在矩阵结束后关闭；复跑 104 张图片通过，警告不再出现，抽查内容也没有因窗口复用而串图。

## 自动化回归范围

- [ActivityStressTests](../../DynamicIslandTests/ActivityStressTests.swift)：7 项测试，覆盖 100 Activity 完整生命周期、同 ID 高频 update、同秒多 source、多级抢占恢复、normal 队列容量/过期/老化、集中调度改期、100 个后台并发入口及性能采样。
- `ActivityManagerTests`：100 个一次性 source 结束后无残留的回归测试。
- `IslandActivityRuntimeTests`：Music、Volume、Battery 的正式 Runtime 抢占和恢复，以及 Activity 暂时覆盖计时完成或文件托盘时旧状态不丢失。
- `run-stability-matrix.sh`：Space、全屏、隐藏菜单栏、合盖模型、屏幕选择/移除、wake 通知和 Music 权限拒绝回归。
- `ci.sh`：全部单元/集成测试、Release 构建、发布配置及 Beta 矩阵校验。
- `generate-screen-matrix.sh`：8 种屏幕配置 × 13 种状态，共 104 张静态截图；用于检查 Host 外壳边界和内容裁切。

## 执行结果

- 聚焦压力、Manager 与 Runtime 回归：19 tests、0 failures。
- `./Scripts/run-stability-matrix.sh`：49 tests、0 failures。
- `./Scripts/generate-screen-matrix.sh`：1 test、0 failures，生成 104 张截图；抽查 MacBook Pro 14 与外接 1080p 的 Music、Volume、Battery critical 和 Pomodoro，没有发现裁切或越界。
- `./Scripts/ci.sh`：278 tests、1 skipped、0 failures；Release build passed。

## 性能与能耗记录边界

自动化压力测试使用 `XCTClockMetric`、`XCTCPUMetric` 和 `XCTMemoryMetric` 记录测试进程中 100 Activity 完整周期的指标，用于后续同环境重复比较。采样环境为 Mac16,12、arm64、macOS 26.6.2、Xcode 26.6：

| 指标 | 5 次聚焦运行结果 |
| --- | --- |
| 单调时钟 | 平均 0.007 s；样本 0.006686–0.007771 s |
| CPU time | 平均 0.007 s；样本 0.006782–0.007064 s |
| CPU cycles | 平均 24,285.250 kC |
| 测试进程峰值物理内存 | 平均 16,463.459 kB |
| 物理内存增量 | 平均 6.554 kB，但相对标准差 200%，只记录，不作为门禁 |

同一用例在最终全量 CI 中为 0.007 s 单调时钟、0.007 s CPU time；测试进程峰值物理内存为 51,689.107 kB，因为此前已经载入完整测试套件。当前没有 Phase 0 的同机真实 App 基线，因此本轮不设置机器相关阈值，也不把上述测试进程指标解释成 App 空闲资源或 SwiftUI/Core Animation 帧率。

下列项目仍须在同一台真实 Mac 上补测，完成前 T17 和 Phase 3 均不标记为 `verified`：

1. Release App 冷启动并静置 5 分钟，记录 CPU、内存、wakeups 和 Energy Impact；再运行 100 事件 burst 并观察内存是否回落。
2. 使用 Core Animation 或 Instruments 记录 compact/expanded、Music/Volume/Battery 抢占与恢复期间的 FPS 和 hitch，人工检查是否闪烁。
3. 在刘海屏、无刘海屏、混合缩放外接屏上切换主屏、热拔插和合盖，并重复窗口定位与 hover 验收。
4. 执行真实睡眠/唤醒，并交错 Apple Music 播放与权限、CoreAudio 连续调节、IOKit 充放电通知、Space/全屏/隐藏菜单栏。

Phase 0 尚未记录真实设备性能基线，因此当前不能给出“无性能回退”的结论，也不能进入 Phase 4 的正式验收。
