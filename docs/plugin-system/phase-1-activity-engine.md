# Phase 1：Activity Engine 设计与验收记录

依据 [开发计划的 T03–T08](DevelopmentPlan.md)；逐项状态以 [进度表](PROGRESS.md) 为准。本文记录当前实现与尚未完成的验收，不代表 Phase 1 已整体完成。`./Scripts/ci.sh` 通过：188 项测试、1 项按设计跳过、0 失败，Release 构建通过。

## 数据边界：T03–T05

- [IslandActivity](../../DynamicIsland/Core/Activity/IslandActivity.swift) 是 `Codable`、`Sendable` 的纯数据值，包含稳定 `id`、`source`、`priority`、`lifecycle`、`presentation`、创建/过期时间和 action ID。`ActivitySource` 区分 built-in、plugin、external；模型不保存 SwiftUI/AppKit View 或可执行闭包。当前 `ActivityPresentation` 仅是文字、图标名和进度摘要，Phase 2 再引入 IslandNode。
- [ActivityPriority](../../DynamicIsland/Core/Activity/ActivityPriority.swift) 只有 background、normal、important、critical 四级，并给内置场景提供默认映射；排序依次考虑优先级、可中断性、当前展示、创建时间、ID。插件请求优先级的 Host 降级和权限边界属于后续阶段，当前不可把枚举本身视为已完成的插件授权。
- [ActivityLifecycle](../../DynamicIsland/Core/Activity/ActivityLifecycle.swift) 将 queued、presented、background、dismissed、ended 状态与 transient、persistent、progress、critical 策略分开。`dismissed` 隐藏但保留数据，`ended` 结束数据生命周期；非法转换抛错。
- [模型、排序和生命周期测试](../../DynamicIslandTests/IslandActivityTests.swift) 分别覆盖纯数据构造与编码；[优先级测试](../../DynamicIslandTests/ActivityPriorityTests.swift) 和 [生命周期测试](../../DynamicIslandTests/ActivityLifecycleTests.swift) 覆盖确定性顺序及状态转换。T03–T05 的既有验收记录见进度表。

## 单写入口与队列：T06–T07

- [ActivityManager](../../DynamicIsland/Core/Activity/ActivityManager.swift) 在 `@MainActor` 上提供 `publish`、`update`、`dismiss`、`end`，并以只读 `current` 发布当前 Activity。相同 ID 的再次 `publish` 转为更新；更新保留首次入库的创建时间、生命周期状态与策略。Manager 校验 ID、source 所有权、策略及过期时间；跨 source 不能更新、隐藏或结束别人的 Activity。状态变化记录 source、ID、前后状态及原因。后台调用者须跨到主 actor。
- [ActivityQueue](../../DynamicIsland/Core/Activity/ActivityQueue.swift) 过滤已过期或非候选状态，再按有限优先级和稳定的同级规则排序。Manager 将被抢占的当前 Activity 转为 background；短暂 Activity 结束后，仍有效的 persistent Activity 可恢复。不可中断的当前 Activity 保持展示，直至结束或受显示时长策略处理。
- [Manager 测试](../../DynamicIslandTests/ActivityManagerTests.swift) 覆盖同 ID 更新、所有权冲突、dismiss/end、过期拒绝、后台入口和重复发布抑制；[队列测试](../../DynamicIslandTests/ActivityQueueTests.swift) 覆盖抢占、嵌套恢复及计划中的 Music → GitHub → AirPods → Battery Critical → Music 顺序。T06 **尚未完成计划验收**：还没有 Debug Provider 发布/更新/结束 Activity 并让实际 UI 只观察 Manager 输出的闭环。T07 的代码和单元验收记录见进度表。

## 集中调度：T08

- [ActivityScheduler](../../DynamicIsland/Core/Activity/ActivityScheduler.swift) 通过可注入的 `ActivityClock` 管理一项最近截止时间的唤醒任务；改期会取消旧任务。它只调度 Activity 展示，不负责插件后台刷新或业务轮询。Manager 汇总绝对过期、展示截止、队列年龄、节流及 debounce 的下一次唤醒时间。
- transient 有展示时长，critical 有最长展示时长；普通切换受 debounce 和最短驻留时间约束，important/critical 可及时抢占。普通 transient 排队数量与排队年龄有限额；可配置每 source 的最短展示间隔。同 ID `update` 不隐式重置展示倒计时。
- Host 可用 `renewTransientPresentation` 显式续展正在展示的 transient；调用需匹配 source，单次续展和总连续展示时间均有上限。无效的零值、负值或非有限展示时长归一为短的正时长，避免 Activity 永久占屏。
- [调度测试](../../DynamicIslandTests/ActivitySchedulerTests.swift) 使用注入时钟推进截止时间，覆盖自动返回、绝对过期、critical 限时、20 个普通事件、source 限频、显式续展、无效时长及未来 `createdAt`；另有真实时钟自动唤醒测试。T08 **尚未完成计划验收**：需在真实 UI 接入后观察快速事件是否闪烁，并与 Phase 0 基线比较空闲 CPU/内存及能耗。

## 后续验收边界

Phase 1 的 Manager→Debug Provider→UI 观察闭环、真实动画闪烁和能耗仍待验证。Music、Volume、Battery 的实际 Provider 迁移及多屏、睡眠唤醒、压力回归属于 [Phase 3 的 T14–T17](DevelopmentPlan.md)，目前不能用 Phase 1 单元测试代替这些验收。
