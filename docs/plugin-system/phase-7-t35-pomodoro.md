# Phase 7 — T35 Pomodoro 官方插件

日期：2026-10-14，更新于 2026-10-19。直接依赖 T24–T34 均已 verified；T31 的真实后台空闲证据已提交。T35 状态为 `verified`，总体迁移顺序见[准备记录](t35-migration-preparation.md)，阶段复核见[Phase 7 统一检查](phase-7-acceptance.md)。

## 当前进度与验收边界

官方 JS 包的计时、预设、完成 Activity、Storage 和一次 Scheduler 对账均已实现；3C 已删除全部 Pomodoro 专用生产 Swift，保留秒表、倒计时和通用 Host 能力。[迁移 CI](evidence/t35-pomodoro-migration-20261016.json)与[退出修复 CI](evidence/t35-quit-fix-20261016.json)保留当时的 888 total / 887 passed / 1 skipped / 0 failures；[退出取消恢复验证](evidence/t35-quit-cancellation-20261016/result.json)为 890 total / 889 passed / 1 skipped / 0 failures。历史 [0.2.1 完成布局验证](evidence/t35-completion-layout-20261016/result.json)为 **892 total / 891 passed / 1 skipped / 0 failures**，普通 Release build passed。

普通 Release 隔离副本已完成实际 `.dip` 导入、权限拒绝 / 撤销 / 明确授权、设置保存、真实新进程恢复预设且不自动开始，以及菜单 / 动画退出的 PID 消失验证。首次退出卡住后撤回的重启结论及后续修复均保留在[部分验收证据](evidence/t35-pomodoro-ui-20261016/result.json)和文末记录中。

0.2.0 的实际计时、旧页面和设置验收保留原版本范围，旧版完成摘要因相机遮挡未被接受；0.2.1 已修正 compact / expanded 两种布局，并[实际升级与独立重审授权](evidence/t35-v021-ui-20261017/result.json)。2026-10-17 的[自然完成漏拍记录](evidence/t35-v021-final-20261017/result.json)继续保留，缺口已由下述本日实机补齐，不能把旧版画面或离屏测试替代为新版实机证据。

## 2026-10-19 最终实机验收通过

[本轮结果](evidence/t35-manual-20261019/result.json)：独立普通 Release / PID 80223 中，通过真实 UI 开始十五分钟计时，在 Start 前后采样界限之后 **900.836–900.93 秒**首次观察到完成 AX。[连续捕获](evidence/t35-manual-20261019/capture.json)在内存连续采集 2459 帧，归档 7 个选帧及全部 69 帧完成 AX 时间，只有一个完成区间。最早 AX 帧尚未绘制完成提示；可见性只由后续实际像素确认：[早期](evidence/t35-manual-20261019/completion-early.jpg)、[中段](evidence/t35-manual-20261019/completion-middle.jpg)、[末段](evidence/t35-manual-20261019/completion-last.jpg)均显示左侧完成图标、右侧两字「完成」位于物理相机两侧，提示随后正常消失，未观察到自动重开。

[正常退出与保留数据](evidence/t35-manual-20261019/cleanup.json)确认 Command-Q 后 PID 80223 消失、Staging 为空，0.2.1 包、启用状态、storage 批准以及十五分钟 completed 设置均保留。没有使用私有 countdown 入口、改时钟或修改生产 App。结合既有公开 API / 迁移 / 设置 / 旧页面证据，原任务内最后的完成提示和清理缺口已关闭，T35 标为 verified。

[Host 来源边界](evidence/t35-manual-20261019/host-provenance.json)明确：本轮是历史独立普通 Release 与完全相同的当前 0.2.1 插件包；历史精确干净构建 commit 未盖章。八项 Host 源 hash 对应 checkpoint 0b96cab，当前相关渲染几何与 countdown 源码保持相同，但 App、JSBridge、Activity Runtime / Manager 后续已有扩展，因此本次不等同于当前 HEAD 二进制的全量产品验收。当前代码的自动回归另见[完整 CI](evidence/t40-registry-ui-20261018/result.json)与[六项真实输入补验](evidence/native-input-20261019/result.json)。

## 历史实施与延期记录

以下保留各子步骤当时的状态、失败、修复和继续位置；其中「in progress」「待补拍」及历史 PID 不代表当前状态。最终结论以上述 2026-10-19 实机记录为准。

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

## 历史完成边界（子步骤 2C1 完成时）

以下为官方包实施前的迁移顺序；第 3 项的官方包实现与第 4 项中的 Swift 删除，现已分别由 3A / 3B 和 3C 完成，当前剩余实测范围见开头。

1. 通用工具角色、按实例选择及 Host 几何已完成，见下方子步骤 1B。
2. 通用 Host 倒计时记录、公开 API、一次性启动凭证和声明式秒级显示均已实现，后台刷新下限保持原值。
3. 完成 JS 官方包的开始、暂停、继续、结束、预设及存储权限处理。
4. 删除生产番茄钟专用 Swift；从 `.dip` 安装并完成真实 UI / 计时、旧功能回归验收。

当时子步骤 1A / 1B 与 2A–2C1 已完成工具选择、计时和显示底座，官方插件与完整迁移尚未实现，原生番茄钟仍保留，因此不能将 T35 标为 verified。后续实现与原生删除结果见 3A–3C；当前验收仍未全部完成。

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

## 子步骤 2C2：自动 compact 与原生页面共存

已增加显式 opt-in compactPolicy、Host 展示上下文和统一 compact 几何；旧工具保持手动选择，自动工具不覆盖展开后的音乐 / 拖盘 / 原生计时。队列、动作和生命周期仍走唯一 currentSnapshot。详见[合约](t35-countdown-api.md#子步骤-2c2自动-compact-工具与共享安全几何)。

CI **868 total / 864 passed / 4 skipped / 0 failures**，普通 Release build passed。新增 33 项测试；[原始两翼截图与证据](evidence/t35-compact-policy-20261015/result.json)确认 210pt 中间相机区没有四种时间宽度的字形，不声称实机或普通 Release UI 已验收。公开 10 秒示例已采用 automatic，真实 VM 的 in-flight resume / 完成排序回归通过。接下来是官方 Pomodoro 包、Storage / Scheduler 验证与专用 Swift 删除 / 实际安装计时验收；T35 不提前 verified。

## 子步骤 3A：官方 Pomodoro 计时 / 预设 / 通知闭环

新增[官方验证包](examples/pomodoro/README.md)，ID com.dynamicisland.pomodoro，版本 0.1.0，仅用公开 Plugin API。实现默认 25 分钟与 15 / 25 / 45 / 60 预设、开始 / 暂停 / 继续 / 结束、compact 两翼时间与 expanded time / progress / 控件，完成另发单次 transient Activity，不使用系统通知权限或 JS timer。运行时忽略预设变更；暂停后切预设先停止旧记录回 idle，与现原生语义对齐。动作和完成通过 Promise FIFO、fresh Host get 与 generation 去重处理。

权限暂为空，此子步骤明确不含 Storage / Scheduler；不是最终发行包。onStart 同步返回，只读取当前 Host 记录恢复同一计时，没有记录时回 idle，不靠存储或完成回调自动开始。

7 项新增真实 Validator / JavaScriptCore VM / Router 集成测试，连同 3 项公开示例回归为 **10 passed / 0 failures**；[证据与源码 SHA256](evidence/t35-pomodoro-3a-20261015.json)。四预设和完成边界使用可控 Host 时间，不冒充实机 15 分钟验收。上一步完整 Host CI 868 total / 864 passed / 4 skipped、Release build passed；本笔仅包与测试，未重复声称新的完整 CI 或产品 UI。

### 继续位置

下一子步骤 3B：Storage 明示授权、拒绝 / 撤销不阻塞计时、非法设置回退、重启只恢复设置不自动重开；通过公开 Scheduler 做一次有界对账，保持 30 / 60 秒下限。随后完成实际 .dip 安装、逐项授权、普通 Release UI / 真实 15 分钟计时，再删除 Model/View/DEBUG/Provider 与预设动画中的全部 Pomodoro 专用 Swift。保留秒表、倒计时和共享时间格式化。T35 仍 in progress，T36 pending。

本轮在 5 小时额度已用 91% 时收尾。没有推送、发布、打 tag、制作 DMG 或改写记忆。

## 子步骤 3B：设置持久化与单次对账

官方验证包更新为 0.2.0，声明 `storage.local` 权限及 Storage / Scheduler capability。安装、启用均不批准存储；Host 仍逐项确认，代码或 Manifest 改变后旧授权不适用。设置仅占 `settings` 一个 key，精确 schema 为 `{schemaVersion:1, selectedMinutes:15|25|45|60, lastSession:idle|running|paused|completed}`。缺失、错误类型、多余字段、未知版本或非法值回默认 25 分钟，不主动覆盖原值。上一轮状态只作元数据，重启读取设置后等待开始，不能重建 Host 计时记录或自动继续。

动作和完成时生成最新设置，最多一个在途写和一个合并草稿。存储链独立于计时动作与渲染；失败保留草稿，等待新动作或唯一 refresh 重试，不无限重试。拒绝、撤销、读写错误显示「设置未保存」，不计为插件故障。设置变化在动作时保存，不依赖资源已撤销的 onStop。

每个执行只请求一次 `requestRefresh(30000)`，由 Host 保留后台 30 秒、低功耗 60 秒下限和合并规则。对账重新读取 Host 记录，不重新开始、继续或安排下一次 refresh。初次未获存储权限时，只有尚未接受任何用户动作才能采用一次延迟重读；单调 user revision 防止用户改回默认后被旧设置覆盖。睡眠恢复的新 VM 可有自己的一次请求，旧执行待办已撤销。

集成发现慢磁盘会占住原 Transport FIFO，消耗开始 / 继续动作的 5 秒凭证。因此 Host 将存储与交互分为两个 FIFO，存储 set/get 顺序保留，共用 64 项准入容量（包括已出队、等待 MainActor 或磁盘的请求）。两队列都保留执行、权限和最终副作用检查；跨队列的数据依赖应 await Promise。阻塞磁盘的真实 Router 测试覆盖开始 / 暂停 / 继续 / 结束及 Activity 回复、存储 FIFO 和撤销未提交写入。

定向 Pomodoro / Storage / Bridge 测试 64 passed / 0 failures。首轮容量测试发现出队但未处理的两条请求可能绕过排队计数，已按全部在途准入计数修正并重跑通过。完整 CI 和普通 Release 构建的最终结果见本节后续证据；本节尚不代表 T35 完整迁移或实机验收完成。

3B 完整 `./Scripts/ci.sh`：**892 total / 891 passed / 1 skipped / 0 failures**，普通 Release build passed。此前锁屏跳过的三项 AppKit 鼠标测试本轮均通过；唯一 skip 为显式截图矩阵生成。[CI 与源码 SHA256](evidence/t35-pomodoro-3b-20261016.json)已保存。接下来删除专用 Swift，再在隔离的普通 Release 副本中完成实际安装、分项授权、UI 和真实计时验收。

## 子步骤 3C：删除专用 Swift

已删除生产 Pomodoro Provider、预设动画，以及 Model / View / compact 颜色 / DEBUG 入口中的所有专用状态和分支。生产 Swift 中 `pomodoro` / `番茄` 零命中；不按官方包 ID 特判。秒表、倒计时、共享格式化、Host 倒计时和工具仲裁继续保留。原生完成 / ACK / 锁盘 / hover 抑制与 transient 抢占回归改用内置倒计时覆盖；删除仅依赖被移除实现的 Provider 和预设动画测试，截图矩阵去掉已删除的原生页面，现为 12 状态 × 8 屏幕配置。历史 Phase 3 截图数量仍是当时的实际结果。

复核补齐了 Transport 满队列回复边界：每请求 UUID 准入在回复前释放，dispatch 返回后幂等清理，防止消费者收到已完成回复后立即提交下一条却被旧计数误拒。新增同一回复调用栈的满队列回补测试。

完整 `./Scripts/ci.sh` 为 **888 total / 887 passed / 1 skipped / 0 failures**，普通 Release build passed；唯一 skip 为显式截图矩阵生成。[源码和 CI 证据](evidence/t35-pomodoro-migration-20261016.json)已保存。实际 .dip 导入、授权和普通 Release UI / 真实计时验收正在独立沙盒副本中进行，T35 保持 in progress。

## 普通 Release 部分验收与退出修复（2026-10-16）

使用独立 Bundle ID `com.rong5.dynamic-island.t35-pomodoro.20261016` 的普通 Release 副本，保留 Sandbox / hardened runtime / JIT 和原 Release entitlements；未增加测试注入权限，也未注册 .dip 默认处理程序。实际从管理页导入 0.2.0 包，安装后停用、存储待授权，启用仍不授权。实际拒绝存储后开始 / 暂停 / 结束正常；运行中撤销存储后暂停 / 继续正常。随后逐项确认本地设置权限，60 分钟预设写入独立存储并显示 `1:00:00`。展开的时间、进度、预设和按钮完整可见。

首次点击动画退出后岛体淡出，但 PID 99942 仍存活；用户指出尚未重启，随后进程启动时间确认了该失败。已撤回该次重启验收标记。采样显示动画 Task 同步进入 NSApplication terminateLater 的嵌套事件循环，后续 MainActor 插件清理 Task 无法运行。活动监视器确认窗口触发 CUA 截图错误，用户协助强制退出了确切隔离 PID；原 App PID 66831 未被停止。

修复为两阶段退出：首次返回 terminateCancel，让当前 MainActor job 返回并完成既有 Coordinator 清理；仅清理成功后批准第二次 terminateNow，清理失败保留原错误与重试入口。没有跳过暂存包清理或放宽权限。修正版完整 CI **888 total / 887 passed / 1 skipped / 0 failures**，普通 Release build passed；[退出修复证据](evidence/t35-quit-fix-20261016.json)。实际菜单退出后 PID 1059 消失；再次启动的 PID 1244 中，番茄钟恢复为 **15 分钟、准备专注、15:00**，即使存储 lastSession 为 running 也不自动开表。再点击原动画退出按钮，PID 1244 同样消失。

[实际 AX、原始截图、签名与进程记录](evidence/t35-pomodoro-ui-20261016/result.json)保留成功与失败范围。截至该次退出修复，真实 15 分钟自然到期、最终 compact 物理刘海与旧页面回归尚未完成；非法设置已有 12 类 VM 自动化验证，普通 Release 错误设置截图尚未补齐。此处保留当时边界，后续进度见文末最终实机验收记录。

### 历史继续位置（退出修复后）

以下保留当时的继续位置；当前进度见文末。

修正版隔离 App 位于 `/Users/rong5/Applications/Dynamic Island T35 Pomodoro.app`，已退出，独立插件数据和授权保留，当前设置为 15 分钟。启动后先确认新 PID；请用户物理悬停展开，选择番茄钟，开始真实 15 分钟计时并记录开始 / 到期实际时间。验证 compact 两翼、原生秒表 / 倒计时、音乐 / 拖盘与收起重选；补齐到期通知和不自动重开。确认上述验收后再更新 T35 状态。旧卡住副本与完整采样保留在 `/tmp/dynamic-island-t35-pomodoro-ui-20261016`，不要再启动其中 `stalled-app.app`。

按用户先前的额度要求，本轮在 5 小时额度接近用完时收尾。未推送、发布、打 tag、制作 DMG 或改写记忆。

## 退出被取消后的岛体恢复（2026-10-16）

继续审查发现，清理失败会取消退出并保留安装预览，但岛体局部的退出 / 缩放 / 淡出状态此前没有复位。Host 现在在退出被取消时发送内部通知，IslandView 无动画恢复三项状态，并取消仍未结束的退出动画 Task，避免后续旧任务再次淡出或发起退出。公开 initializer、插件 API 与权限策略保持原合约。

新增两项真实 NSHostingView 渲染和鼠标事件测试：先看到完全淡出的像素，再取消退出，原 View 恢复像素和音乐 / 拖盘点击，且可再次退出；动画途中取消则等待超过原 670ms，证明旧任务不再晚到退出。定向 6 项通过，完整 CI **890 total / 889 passed / 1 skipped / 0 failures**，普通 Release build passed。唯一 skip 仍为显式截图矩阵生成。截图为原始测试 PNG，已目视检查；不把离屏测试当作普通 Release 产品验收。

普通 Release 副本还实际打开待安装预览，在受控目录身份不匹配下请求菜单退出：Host 拒绝清理替换目录，保留原暂存包与预览，显示 cleanupFailed 并禁用安装。恢复原身份后，重试取消成功；原已安装插件继续运行且授权保留，再次退出成功、Staging 为空。[完整 CI、原始测试截图与实际故障记录](evidence/t35-quit-cancellation-20261016/result.json)已保存。该实际故障场景使用标准菜单，动画取消的显示 / 点击恢复由上述真实渲染测试覆盖。

## 0.2.0 历史实机验收（2026-10-16）

新版隔离副本 PID 11953 已实际确认：合法 Host namespace 中仅 selectedMinutes 类型非法的 settings，启动后回到 **25 分钟、准备专注、设置未保存**；用户动作前，文件字节保持原样。随后选择 15 分钟，并于 **2026-10-16T10:27:43.345Z** 通过真实界面开始计时。

同一 PID 中，文件只读观察在 **10:42:43.637672Z** 首次记录 completed；以点击前 / 后采样时刻计算，分别经过 **900292 ms / 900282 ms**。到 **10:44:12Z** 仍为 completed，收起后计时图标和时间消失，没有自动重开。这证明了本轮实际 900 秒自然到期及后续保持完成状态。

完成提示的首帧截图在 **10:42:50.896Z** 才取得，比 completed 观察晚 **7.258 秒**，画面只见收起的空刘海，没有捕获短时提示。因此不将该截图或存储 completed 状态当成实际完成 Activity 可见性验收。后续第二轮已补录，但暴露了下文记录的相机遮挡问题。

物理 compact 两翼已确认，时间实际由 **04:41 → 04:31**。内置秒表的开始 / 暂停 / 重置、内置倒计时调整为 4 分钟后的开始 / 暂停 / 重置，以及音乐 / 空拖盘切换均已通过；切回番茄钟时显示 **13:30**，计时连续。原始记录由[最终实测证据](evidence/t35-pomodoro-final-20261016/result.json)汇总。

该轮结束时，完成提示补录和重新展开恢复尚未完成；随后用户物理重新展开已确认选择清除，第二轮也已捕获旧版提示，但其遮挡问题未被接受。当前待办以文末 0.2.1 继续位置为准。


## T35 范围统一检查（2026-10-17 历史）

本表保留 2026-10-17 当时范围；其补拍 / 清理缺口已于[2026-10-19 最终验收](evidence/t35-manual-20261019/result.json)关闭，当前阶段结论见[Phase 7 统一检查](phase-7-acceptance.md)。当时本表仅覆盖 T35，不表示 Phase 7 已全部完成。0.2.0 的第二轮提示补录、重新展开恢复与 PID 11953 正常退出已记录；旧提示因相机遮挡未通过。0.2.1 已实际升级并重新审核授权，真实自然完成一轮并正常退出，当时仅待新版自然到期安全两翼提示补拍。用户选择留待下次，T35 当时 in progress；T36 自动开发已完成，实际验收当时仍 in progress。

| 类别 | 结论与证据 | 验收范围 |
| --- | --- | --- |
| 旧功能 | 0.2.0 隔离 Release 的秒表开始 / 暂停 / 重置、4 分钟倒计时调整 / 开始 / 暂停 / 重置、音乐 / 空拖盘切换通过；返回番茄钟时 13:30 连续。物理重新展开恢复内置倒计时 4:00，明确重选后才显示番茄钟已完成。见[实际 UI](evidence/t35-pomodoro-final-20261016/result.json)。 | 旧版提示补录已完成但有遮挡；仍待 0.2.1 自然到期的安全两翼提示。 |
| 架构 | 专用生产 Swift 已删除，官方包只使用公开 Activity / Node / Action / Storage / Scheduler / countdown；选择、窗口、几何、截止和显示 tick 仍由 Host 持有。见[迁移](evidence/t35-pomodoro-migration-20261016.json)与[合约](t35-countdown-api.md)。 | 不接受 T36、SDK 或整个 Phase 7。 |
| 并发 | 实例 / execution / owner / generation、一次性 activation、完成 receipt ACK 拒绝旧回调；Storage / 交互双 FIFO 共用 64 项在途准入。慢写、撤销和满队列回补测试通过。见[3B](evidence/t35-pomodoro-3b-20261016.json)。 | 单机实测与自动化各自保留范围。 |
| 性能 | 可见运行叶共享一个秒级显示 Task；静态、hidden、paused、invalid、completed 和 shutdown 释放需求。真实 NSHostingView 验证单任务和最终释放。见[显示节点](evidence/t35-countdown-node-20261015/result.json)。 | 本轮未新增 CPU / 内存 / 帧率量化。 |
| 能耗 | 无每 VM Timer 或 JS 每秒 tick；每执行一次 requestRefresh，后台 30 秒 / 低功耗 60 秒下限保留。集中 Scheduler 继承 [T31 双 15 分钟真实后台测量](evidence/t31-background-20261014.md)。 | T31 是既定工作负载，本轮未测 Pomodoro 专属耗电。 |
| 安全 | storage.local 必须明确批准，启用不授权；实际拒绝 / 撤销仍可计时。非法 selectedMinutes 回 25 分钟 idle，动作前原字节不变。清理失败拒删替换目录、保留 review 并禁用安装。见[实际 UI](evidence/t35-pomodoro-final-20261016/result.json)与[清理恢复](evidence/t35-quit-cancellation-20261016/result.json)。 | 畸形输入、包事务及权限竞态继承既有自动化。 |
| 隐私 | 只保存预设和 lastSession 元数据，不申请网络、系统通知或额外敏感权限；固定失败提示和诊断边界继承 T27 / T32。 | 普通 KV 是本地 JSON，不能保存秘密。 |
| 兼容 | 共享 Host 屏幕 / 面板 resolver；真实物理刘海两翼 04:41 → 04:31 可见，离屏四宽度相机区检查通过。见[compact](evidence/t35-compact-policy-20261015/result.json)和[实际 UI](evidence/t35-pomodoro-final-20261016/result.json)。 | 本轮未重跑多屏、无刘海设备、合盖、低电量、Reduce Motion 全矩阵，继承既有 Host 设备 / 生命周期结果。 |
| 测试 | 最新 0.2.1 完整 CI 892 total / 891 passed / 1 skipped / 0 failures，普通 Release build passed。见[完成布局验证](evidence/t35-completion-layout-20261016/result.json)。退出取消恢复的 890 项 CI 作为[历史证据](evidence/t35-quit-cancellation-20261016/result.json)保留。 | 唯一 skip 为显式截图矩阵生成；未宣称本轮生成 12×8 新截图。 |
| 回滚 | 停用 / 卸载 / 升级 / 退出撤销旧执行并释放资源，设置不自动恢复业务计时；实际 cleanupFailed 可恢复重试。0.2.0 的[清理记录](evidence/t35-pomodoro-final-20261016/cleanup.json)保留；0.2.1 本轮 PID 32762 已正常退出、Staging 为空、安装包 / 设置 / 授权保留，见[本轮清理](evidence/t35-v021-final-20261017/cleanup.json)。 | 下次补拍须重新核对新 PID，结束后再正常退出归档；用户原 App 和默认 .dip handler 保留。 |


## 第二轮复现与 0.2.1 修复（2026-10-16 历史记录）

用户物理重新展开后恢复内置倒计时 4:00；明确重选番茄钟显示本轮已完成 00:00 / 100%，选择清除验收通过。第二轮于 10:49:04.308Z 开始，连续抓帧在 11:04:05.265Z 捕获真实 completion。原 0.2.0 的居中摘要落在相机区域，不能接受为安全可见提示。

0.2.1 仅通过公开节点增加 compact 的图标 / spacer / 两字「完成」，并显式提供 expanded 完整标题和副标题，避免 expanded 回退为简短 compact。真实 VM 完成测试保留单次通知 / generation / 不自动重开断言；两项真实 Renderer 像素测试确认实际 312pt 和历史 210pt 相机区零字形、两翼有内容，旧摘要对照正确检测中心字形。原始 PNG 已目视检查。

首轮修正测试夹具对只读 Reduce Motion 环境的写入，第二轮修正截图输出为沙盒临时目录，未扩大权限。最终完整 CI 为 **892 total / 891 passed / 1 skipped / 0 failures**，普通 Release build passed，见[证据](evidence/t35-completion-layout-20261016/result.json)。

当时实际副本安装 0.2.0，已正常菜单退出，PID 11953 消失，Staging 为空，隔离 App / Installed / 授权数据保留，见[清理记录](evidence/t35-pomodoro-final-20261016/cleanup.json)。新包位于 `/tmp/dynamic-island-t35-completion-layout-20261016/pomodoro-0.2.1.dip`。当时的继续计划为从管理 UI 升级并重新审核 / 明确授权改变后的代码，再完成实际自然到期两翼提示验收；不能把旧版本画面或离屏测试当作新版本实机验收。

当时按用户要求，在 5 小时额度已用 96% 时收尾。

## 0.2.1 升级后继续位置（2026-10-17 历史记录）

本轮已通过真实管理 UI 升级至 0.2.1，确认安装后仍停用，启用后 storage 仍待授权；随后在新版代码审核中明确允许存储权限，没有继承旧版批准。实际升级与授权记录已归档为[阶段证据](evidence/t35-v021-ui-20261017/result.json)，不代替最终计时验收。

当时等待用户物理悬停后开始计时。尚未验收的范围为 **0.2.1 实机自然到期的安全两翼完成提示**及**最终进程清理**。提示必须来自实际安装的 0.2.1 代码；旧版漏帧、实际遮挡和离屏像素验证均不能替代该项。当时 T35 保持 in progress，T36 pending。

本轮[实际升级与授权证据](evidence/t35-v021-ui-20261017/result.json)已保存。当时隔离副本 PID 17040 收起，等待物理悬停后选择番茄钟并点击开始；尚未启动最后一轮计时。当时原 App PID 66831 保留。

## 首次人工步骤延期（用户安排，2026-10-17 历史记录）

用户要求先跳过需要本人操作的部分，已登记到[统一人工清单](MANUAL_ACCEPTANCE.md)：当时 T35 为 1 组 / 2 个指针动作，最后一轮计时未开始。当时不再等待悬停；隔离副本已通过标准菜单请求退出，实际进程结果见[升级证据](evidence/t35-v021-ui-20261017/result.json)。T35 未验收状态保留，T36 按用户这次依赖例外先推进可自动完成的开发。

## 本轮自然完成与补拍延期（2026-10-17 历史继续位置）

用户配合展开后，实际 0.2.1 / PID 32762 于 08:52:03.808–08:52:03.833Z 通过 UI 点击开始；同一进程于 09:07:04.764569Z 保存 completed，实际经过约 900.93–900.955 秒。运行中的 compact 图标和时间位于物理刘海两侧，结束后回到空闲且无自动开表。助手抓帧启动晚，未留下短暂完成提示，不能将该项标为通过。[本轮证据](evidence/t35-v021-final-20261017/result.json)明确保留缺口。

捕获函数已预先准备，并用空闲界面完成短时抓帧验证；下次应为新一轮建立独立 Start 时间、截止时间和帧缓存，到期前至少两分钟开始连续短段捕获，每段重新绑定实际 App。用户当时明确回复「留待下次」，当轮没有启动补跑。副本已于 09:42:29.606Z 请求正常 Cmd+Q，随后确认 PID 32762 消失、Staging 为空，0.2.1 安装三文件、15 分钟 completed 设置和存储批准保留；原 App PID 21458 当时仍运行，见[清理记录](evidence/t35-v021-final-20261017/cleanup.json)。当时下次计划为从[人工清单 M01](MANUAL_ACCEPTANCE.md)恢复并核对新 PID，T35 当时继续 in progress。

后续：本节保留的补拍与正常退出待办已由[2026-10-19 实机结果](evidence/t35-manual-20261019/result.json)和[清理](evidence/t35-manual-20261019/cleanup.json)完成；T35 当前为 verified，不再要求重复本历史计时。
