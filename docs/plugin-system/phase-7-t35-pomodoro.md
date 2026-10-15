# Phase 7 — T35 Pomodoro 官方插件

日期：2026-10-14，更新于 2026-10-15。直接依赖 T24–T34 均已 verified；T31 的真实后台空闲证据已提交。T35 状态为 `in progress`，总体迁移顺序见[准备记录](t35-migration-preparation.md)。

## 子步骤 1A：公开 compact 可见性字段

插件的 `activity.publish` / `activity.update` presentation 现在接受已有数据模型的可选 `showsCompact` 布尔值。false 表示 compact 不显示，true 表示显示；省略保持 nil，沿用 Host 的默认显示行为。插件仍提交受限数据，最终展示由 Host 决定。

```javascript
await island.activity.publish({
  id: 'session', lifecycle: {policy: 'persistent'},
  presentation: {title: '番茄钟', showsCompact: false}
});
```

JS 在安全 snapshot 后验证 presentation 精确字段和布尔类型，再发送请求，不重新读取用户对象或调用 getter；Host Converter 独立校验。null、数字、字符串、数组、对象、未知字段及重复 JSON key 均拒绝，不做类型转换。现有 capability、执行会话、配额和限频仍适用。

update 只修改 priority 等顶层字段时保留原 presentation；提交新的 presentation 时仍整体替换，省略 showsCompact 会恢复 nil。JS API version 沿用 1.0.0：这是可选字段扩展，旧输入保持默认行为。

新增两项 Bridge 测试：Host 对错误类型的 publish / update 原子拒绝，Activity、实例及数量保持不变；真实 JavaScript 的 false 发布、true 更新、顶层 patch 保留和 presentation 替换恢复默认均到达 ActivityManager。既有测试补充默认、重复 key、未知字段与 getter 零调用检查。

## 验证

`./Scripts/ci.sh` 完整 CI 为 **705 total / 701 passed / 4 skipped / 0 failures**，普通 Release build passed；两项新增测试均通过。[汇总与源码 SHA256](evidence/t35-showscompact-20261014.json)已保存。3 项鼠标测试因当前 macOS 会话锁定跳过，另 1 项为既有截图矩阵生成；没有将跳过项宣称为本轮通过。日志 `/tmp/dynamic-island-t35-compact-20261014-ci.log`，结果 `/tmp/dynamic-island-t35-compact-20261014/TestResults.xcresult`。

## 下一步与完成边界

1. 通用工具角色、按实例选择及 Host 几何已完成，见下方子步骤 1B。
2. 通用 Host 倒计时记录、公开 API、一次性启动凭证和声明式秒级显示均已实现，后台刷新下限保持原值。
3. 完成 JS 官方包的开始、暂停、继续、结束、预设及存储权限处理。
4. 删除生产番茄钟专用 Swift；从 `.dip` 安装并完成真实 UI / 计时、旧功能回归验收。

子步骤 1A / 1B 与 2A–2C1 已完成工具选择、计时和显示底座；官方插件与完整迁移尚未实现，不能将 T35 标为 verified。原生番茄钟继续保留至完整替换验收，T36 仍 pending。

## 子步骤 1B：工具角色、实例选择与共享几何

### 公共数据与 Host 仲裁

`presentation.role` 可选，闭集为 `status` / `tool`；省略为 nil，旧 Codable 数据和显示行为沿用 status。JS 在安全快照上检查精确字段和类型，Host 独立验证最终 Activity。tool 只允许 persistent / progress；插件工具优先级强制降为 background，priority-only 更新也不能抬升。presentation 更新仍整体替换，切回 status 或省略 role 会退出工具目录。

Host 管理 `toolSnapshots` 与按 id / source / instance token 绑定的选择。未选工具不参与自动展示，用户选择可以切入工具；原有非中断 critical policy 先保留，important / critical 或 normal transient 状态仍可临时抢占，结束后恢复同一选择。暂停音乐的 showsCompact=false 不受全局过滤，原实例可恢复。普通 source rate / dwell 继续适用，显式选择仅豁免目标工具，未新增轮询或每工具 Timer。

动作仍只使用 `currentSnapshot` 经 ActionRouter；工具目录不是动作授权。旧 token、错误来源、失效 / 结束 / 过期 / 执行撤销 / 角色改变的项不能选中替代实例。失效或清除后立即移除旧工具展示，不保留 fallback / dwell。停用后重新启用需要新选择。Renderer identity 绑定 instance token，同 ID 重建会清除旧控件状态。

### 展示与交互

「计时」原位置在有工具时显示菜单，包含「内置计时」与工具项，不增加内容行。菜单捕获完整 snapshot；音乐、拖盘、内置计时、拖入文件、原生计时完成或收起岛体会同步清除工具选择。普通提示抢占保留选择。再次展开后显示内置页面，工具需重新选择。

View 与 Panel hover 共用 `runtime.expandedShellSize`；实际呈现工具时 Host 固定 480×200，扣除 chrome 后有 140 pt 内容，隐藏的原生 tab 不再决定其裁切。原生秒表 152、倒计时 / 番茄钟 190、音乐 200 的尺寸保留，Reduce Motion 关闭新增动画。

### 自动化与普通 Release 实测

新增 28 项测试：Core 工具选择 17、角色 / Bridge 7、生产 Runtime / 生命周期交互 3、几何 1。首轮编译修正了测试 fixture 的必需参数；最终 `./Scripts/ci.sh` 为 **733 total / 732 passed / 1 skipped / 0 failures**，普通 Release build passed。唯一 skip 为显式截图矩阵生成。此前因锁屏跳过的三项鼠标测试本轮均通过。[CI 及源码 SHA256](evidence/t35-tools-20261015/ci-summary.json)。

普通 Release 隔离副本保留 Sandbox / hardened runtime / JIT，无测试注入例外，strict / deep 签名验证通过。通过真实导入预览安装[无权限工具示例](examples/tool-demo/README.md)，确认安装后停用，再由管理 UI 启用。实际验证了菜单、工具 0→1 点击回传、同 VM 再选择保留计数、内置秒表 / 倒计时、音乐及空拖盘切换。工具壳 / 原生壳内容完整可见。

窗口定向自动化无法改变 Host 所读的全局鼠标位置，因此用户协助了物理悬停展开，以及移出再移回；所有菜单、按钮、安装 / 启用及退出由 CUA 操作。重新展开后的真实 AX 和截图确认显示内置倒计时，工具焦点已清除。没有把定向点击当作全局 hover 证据。

| 场景 | 实际截图 |
| --- | --- |
| 同位菜单 | [菜单](evidence/t35-tools-20261015/tool-menu.jpg) |
| 工具与 JS 按钮回传 | [工具](evidence/t35-tools-20261015/tool-selected.jpg)、[点击后](evidence/t35-tools-20261015/tool-incremented.jpg) |
| 内置计时与旧页面 | [秒表](evidence/t35-tools-20261015/native-stopwatch.jpg)、[倒计时](evidence/t35-tools-20261015/native-countdown.jpg)、[音乐](evidence/t35-tools-20261015/music-restored.jpg)、[拖盘](evidence/t35-tools-20261015/tray-restored.jpg) |
| 收起并重新展开 | [内置页恢复](evidence/t35-tools-20261015/fold-reexpanded.jpg) |

[13 个实际 AX 观察](evidence/t35-tools-20261015/ui-observations.json)、[截图来源及 SHA256](evidence/t35-tools-20261015/screenshots.json)、[完整证据索引](evidence/t35-tools-20261015/result.json)已保存，截图为本任务实际工具输出的原始 JPEG。自动化另覆盖提示抢占、禁用、过期、角色改变、旧实例动作和原生计时完成；本轮不声称实机低电池或真实 Volume 交错已复测。

验收副本已正常退出、注销并连同独立插件数据归档。原 App PID 66831 仍运行，原 Installed / Staging 为空；默认 `.dip` handler 未更改，见[清理记录](evidence/t35-tools-20261015/cleanup.json)。本子步骤没有实现倒计时 API、移除原生番茄钟或接受 T36。

## 子步骤 2A / 2B：Host 倒计时与动作凭证

已实现通用 `countdown` capability、公开 countdown namespace、精确 Duration 截止 / 暂停 / 继续、单一最近 alarm，以及真实 Action 的 5 秒一次性启动凭证。睡眠和低电池保留业务记录，恢复使用新执行上下文；完成事件经 typed FIFO 和 VM receipt ACK 投递，防止排队后暂停丢通知。审查补齐了未接收补发、factory 重入睡眠、凭证消费时资源撤销三个边界。

详见[公开合约与生命周期说明](t35-countdown-api.md)及[CI 和源码证据](evidence/t35-countdown-20261015.json)。本子步骤的 Host/API 自动化不能替代真实睡眠、低功耗、能耗或最终 Pomodoro UI 验收。下一步从通用声明式时间节点和仅可见节点的共享显示 tick 开始，再实现官方 JS 包、删除专用 Swift 及完成实际安装计时验收。T35 保持 in progress，T36 pending。

本子步骤完整 `./Scripts/ci.sh`：**795 total / 794 passed / 1 skipped / 0 failures**，普通 Release build passed。新增 62 项 countdown 测试；唯一 skip 是既有显式截图矩阵生成。首轮修正测试 helper 与诊断属性名，资源准入包装按 Void context.perform 的真实签名拆分后通过；无新增编译错误。

子步骤 2C0 已增加[Host 只读显示快照与时间格式化](t35-countdown-api.md#子步骤-2c0只读显示底座)，防止绘制时触发完成 observer。该独立提交尚未接入 Renderer；后续完整节点 / 可见共享 ticker 接入见下方 2C1。

## 子步骤 2C1：通用倒计时节点与可见显示

纯数据 countdown 节点（time / progress）、当前执行 / Activity 实例绑定解析、生产 Renderer 和 Host 共享秒级显示 clock 已接入，详见[公开合约](t35-countdown-api.md#子步骤-2c1声明式节点与可见共享显示-tick)。SDK / Host / Core 独立拒绝无效引用及多余字段，priority-only 更新不能绕过检查。静态叶不观察 tick；隐藏、暂停、失效、到期或 Runtime shutdown 释放需求。Broker 只发事件型合并失效，绘制不会结算业务状态或调用 JS observer。

新增节点、SDK、Bridge、生产 Runtime 和真实 NSHostingView 测试，验证时间 / 进度截图变化、同一 clock 一个 Task、隐藏页面与摘要回退没有残留订阅。公开无权限 countdown-demo 通过真实 VM、ActionRouter 和 Host display resolver 验证开始 / 暂停 / 继续 / 结束及收起重选；[结果和原始测试截图](evidence/t35-countdown-node-20261015/result.json)记录实际执行范围。下一步是官方 Pomodoro JS 包与完整迁移，T35 仍 in progress。

2C1 完整 `./Scripts/ci.sh`：**835 total / 831 passed / 4 skipped / 0 failures**，普通 Release build passed。新增 35 项测试，公开示例另外完成真实 10 秒自然到期并保留同 generation、无自动重开。3 项既有 AppKit 鼠标测试因会话锁定跳过，1 项为显式截图矩阵生成，未将它们宣称为本轮通过。原始时间 / 进度 / 到期与摘要回退 PNG 来自真实 Debug NSHostingView 测试并已目视检查；没有把它们当成普通 Release 产品 UI 或实机睡眠验收。
