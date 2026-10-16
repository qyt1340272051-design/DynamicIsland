# T35 — Pomodoro 迁移准备

日期：2026-10-14。本页记录初始审计和迁移顺序；已实现接口以[公开合约](t35-countdown-api.md)为准。T31 的[实际后台空闲验收](evidence/t31-background-20261014.md)已关闭，T24–T34 直接依赖均已 verified，可以开始实施。

实施进度见 [T35 记录](phase-7-t35-pomodoro.md)。子步骤 1A / 1B 已实现 showsCompact、工具角色、实例选择与共享几何，自动化及实际普通 Release UI 验收完成；通用 Host 倒计时与点击凭证 API 已完成，见[公开合约](t35-countdown-api.md)；声明式节点与可见共享秒级显示也已完成。下文候选表保留原始设计背景，以公开合约为准。

## 必须迁移的生产代码

初始审计时，生产番茄钟位于 `IslandTimerToolsModel` / `IslandTimerToolsView`，使用原生 100 ms ticker；`PomodoroActivityProvider` 只用于 DEBUG。2026-10-16 的 3C 已删除这些专用实现和分支，生产 Swift 零命中，见 [迁移证据](evidence/t35-pomodoro-migration-20261016.json)。下列清单保留迁移范围，实际 .dip / UI / 计时验收完成后才能接受 T35。

- 移除 `PomodoroActivityProvider.swift`、`IslandPomodoroPresetAnimation.swift` 和 DEBUG 番茄钟入口。
- 从计时 Model/View、IslandView 移除 `.pomodoro`、专用预设、状态、动作及颜色分支。
- 保留秒表、倒计时、共享时间格式化、`alarm.fill` 计时入口与 Host 窗口动画。
- 当前原生番茄钟没有持久化设置需要迁移。插件设置使用公开 Storage API，仅申请 `storage.local`，遵守拒绝、撤销及代码改变后重新确认规则。

状态与设置应在动作发生时保存。生命周期在调用 `onStop` 前已关闭资源准入，不能依赖 `onStop` 保存；`onStart` / `onStop` 也不能返回异步 Promise。

## 公共能力缺口

| 缺口 | 最小方案候选 | 主要修改面 |
| --- | --- | --- |
| idle 工具入口与展示选择 | 暴露已有 `showsCompact`，增加通用工具角色和用户选择入口；按 Activity instance token 选择，idle 工具不抢占音乐；动作仍校验当前实例。 | Activity / Converter / Manager / Runtime / 计时页 / IslandView。 |
| expanded 内容高度仍取决于旧计时 tab | 共用 Host 尺寸 resolver，为工具选择现有受限壳尺寸；View、Panel 和 hover 使用同一结果，不按插件 ID 定制。 | VisualStyle / PresentationPolicy / IslandView / PanelController。 |
| 后台刷新最少 30 秒、低功耗最少 60 秒 | 研究通用 countdown primitive 与声明式时间节点。Host 持有单调截止和可见秒级显示，JS 负责业务；普通 refresh 保留合并规则。 | Scheduler / Bridge / Bootstrap / ActionSession / Runtime / Lifecycle / Node / Renderer。 |

精确倒计时不能简单开放任意 `waitUntil`，否则插件可以每秒重登记而绕过 T31。候选方案要求 start / resume 消耗真实 Action 的一次性 activation，限制每插件和全局计时记录；完成回调不能自行重开一秒倒计时。只为可见运行节点启用共享渲染 tick，不给每个 VM 一个 Timer，也不向 VM 每秒发 tick。

上述新增 namespace、字段、capability 和节点名称尚未冻结。实施时先复核现有 Bridge / Scheduler / 生命周期契约，选取最小公共接口；不能给官方番茄钟特殊私有接口，或把现有秒级显示和完成时机降为 30 / 60 秒刷新。

## 实施顺序与验收

1. 通用工具选择和几何：旧实例、卸载、替换时拒绝；音乐、拖盘、秒表和倒计时仍可进入；瞬时事件后恢复；真实刘海无裁切、Reduce Motion 有效。
2. 通用计时能力：暂停冻结、继续准确、停止和新 generation 拒绝旧完成；后台及低功耗不延迟截止状态；墙钟调整不影响计时。睡眠期间不绕过执行准入，恢复后交付完成，不复活旧 VM / lease。
3. JS 官方插件：开始、暂停、继续、结束，15 / 25 / 45 / 60 分钟预设，compact / expanded、设置保存；完成后发布通知 Activity，不申请尚未支持的系统通知权限。
4. 删除全部专用 Swift 后，从 `.dip` 安装、分项授权、启用并真实完成计时；验证重启恢复、非法存储回退、权限拒绝 / 撤销和旧内置功能回归。

T35 仅在以上实现、自动化和真实 UI 验收完成后标记 verified。本页不提前接受 T36 或兼容 / SDK / Registry 工作。
