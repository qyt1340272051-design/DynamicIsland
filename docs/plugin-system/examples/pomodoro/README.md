# 番茄钟官方插件 — T35 3A

包 ID：`com.dynamicisland.pomodoro`；开发者：DynamicIsland；版本：0.1.0；最低 Host：0.6.0。

本步骤提供公开 API 的预设、Host 倒计时与应用内完成提示闭环。权限为空；只声明 Activity 发布 / 更新 / 结束、IslandNode、动作和 countdown capability。

## 使用与行为

展开刘海，在工具菜单选择「番茄钟」。预设为 15、25、45、60 分钟，首次默认 25 分钟。点击开始、暂停、继续或结束；运行中忽略预设修改，暂停时改预设会先结束旧 Host 计时，再回到新的准备状态。结束保留当前预设，不会自动开始下一轮。

工具 Activity 的本地 ID 为 `session`，保持 persistent / tool / automatic compact 策略。运行和暂停时允许 compact 显示，准备和完成时隐藏 compact；展开布局最多五行，时间与进度都引用 Host 的精确 generation。布局使用 Host tokens，不请求窗口大小。收起或隐藏工具不会结束业务计时；重新展开时需按 Host 工具选择规则选择该工具。

Host 完成事件通过串行 Promise work 链，再调用 `countdown.get('session')` 核对当前 completed generation。工具显示完成状态，并对该 generation 发出一次本地 ID 为 `completion` 的 transient Activity：「专注完成 / 本轮专注已结束」。这是应用内 Activity 提示，不是系统通知，也没有系统通知权限；完成事件不能自动重新开表。

`onStart` 同步返回。恢复时通过公开 `countdown.get` 接回当前 Host 记录，并仅在 durationMs 对应合法预设时恢复分钟数；没有 Host 记录就回到准备状态。开始和继续首先提交真实动作的一次性 activation，之后才清理旧提示。JavaScript 不持有时钟、定时器或秒级刷新；时间、进度与到期由 Host 负责。

## 当前边界

这是 T35 的 **3A**，不代表整个 T35 完成：尚未保存设置或接入 Storage，尚未接入 Scheduler，尚未删除旧专用 Swift 计时实现，也没有正式 `.dip` 安装与实机 UI 验收。预设不跨应用重启保存；Host 计时记录也不跨应用重启持久化。后续按 3B 及完整迁移计划继续，T35 保持 in progress。
