# 番茄钟官方插件 — T35 3B

包 ID：`com.dynamicisland.pomodoro`；开发者：DynamicIsland；版本：0.2.0；最低 Host：0.6.0。

本步骤在 3A 的预设、Host 倒计时与应用内完成提示之上，增加公开 Storage 和一次 Scheduler 对账。权限仅为 `storage.local`，需要用户明确批准才能保存设置；拒绝或撤销后，计时和应用内完成提示仍可使用。没有系统通知、网络或其他权限。

## 使用与行为

展开刘海，在工具菜单选择「番茄钟」。预设为 15、25、45、60 分钟，首次默认 25 分钟。点击开始、暂停、继续或结束；运行中忽略预设修改，暂停时改预设会先结束旧 Host 计时，再回到新的准备状态。结束保留当前预设，不会自动开始下一轮。

工具 Activity 的本地 ID 为 `session`，保持 persistent / tool / automatic compact 策略。运行和暂停时允许 compact 显示，准备和完成时隐藏 compact；展开布局最多五行，时间与进度都引用 Host 的精确 generation。布局使用 Host tokens，不请求窗口大小。收起或隐藏工具不会结束业务计时；重新展开时需按 Host 工具选择规则选择该工具。

Host 完成事件通过串行 Promise work 链，再调用 `countdown.get('session')` 核对当前 completed generation。工具显示完成状态，并对该 generation 发出一次本地 ID 为 `completion` 的 transient Activity：「专注完成 / 本轮专注已结束」。这是应用内 Activity 提示，不是系统通知，也没有系统通知权限；完成事件不能自动重新开表。

`onStart` 同步返回。恢复时通过公开 `countdown.get` 接回当前 Host 记录，并仅在 durationMs 对应合法预设时恢复分钟数；没有 Host 记录就回到准备状态。开始和继续首先提交真实动作的一次性 activation，之后才清理旧提示。JavaScript 不持有时钟、定时器或秒级刷新；时间、进度与到期由 Host 负责。

## 设置与一次对账

设置只使用 `settings` 一个 key，精确内容为：

```json
{"schemaVersion":1,"selectedMinutes":25,"lastSession":"idle"}
```

只接受这三个字段、schemaVersion 数字 1、分钟数 15 / 25 / 45 / 60，以及 `idle` / `running` / `paused` / `completed`。未知字段、错误类型或非法值均回到默认 25 分钟，不在启动时覆盖原值。`lastSession` 只是元数据；没有 Host 记录就显示准备状态，绝不依据设置自动开始或继续。保留的 Host 记录和合法 durationMs 优先于存储选项。

动作和完成事件将最新设置交给独立写队列：最多一个在途写和一份最新草稿，不等待写入才消费动作 activation。拒绝、撤销或 I/O 错误只在展开第一行显示「设置未保存」，不会输出 warning / error；失败不会立即循环重试，下一次动作或唯一 refresh 可重试最新草稿。初次缺失或非法设置也显示该提示，首次用户动作之后才尝试保存。

每次执行只请求一次 `requestRefresh(30000)`，不将等待加入计时动作链，也不递归安排。Host 保留后台及低功耗政策，下限分别为 30 秒和 60 秒。到期后用 fresh get 核对当前计时，并重试已有待保存草稿。初始读取失败时，只有本执行尚无任何用户改动才允许重读；即使改预设后又改回 25，也不会被晚到的旧设置覆盖。重读仍独立于动作链，落地时再次检查单调用户改动代次。

## 当前边界

这是 T35 的 **3B**，不代表整个 T35 完成：已删除旧专用 Swift 计时实现并通过完整 CI；正式 `.dip` 安装与实机 UI 验收仍在进行中。Host 倒计时记录不跨应用重启持久化；保存的 lastSession 不能恢复业务计时。仍需完整迁移和实机验收，T35 保持 in progress。
