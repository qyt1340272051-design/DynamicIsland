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

## 2026-10-19 自动收尾（历史）

当前 **34 项 verified、6 项 in progress**。T08 / T10 的后续证据已归并；T02、T11、T37、T38、T39、T40 保留各自未通过门槛。用户最新要求「现在不方便，先跳过人工操作」，下次集中处理[人工清单 M03–M05](MANUAL_ACCEPTANCE.md)。普通 Release 隔离副本已安装启用五个无额外权限示例，现已正常退出并保留状态。

本轮完整 CI 1070 passed / 2 skipped / 0 failures，普通 Release 构建通过；随后新增的独立作者原包 Host 集成另跑 8 项全通过，SDK 归档审阅修复后 Python 40 项及类型检查通过。各批次分别留存，不合并成一次全量结果。SDK 与官方插件公开发布、正式 Registry 目录及公网安装尚未执行。 [提交前检查](evidence/final-review-20261019/README.md)已核对当前源码摘要、最新 SDK、结构化证据及本轮本地链接。

## 2026-10-19 恢复人工验收（历史）

用户要求「来完成人工操作部分」。[M03](t02-t37-manual-acceptance-20261019.md)已关闭 T02 / T37；[2026-10-20 第三轮 M04](t11-manual-acceptance-20261020.md)完成真实收起 minimal → compact、重新展开和停止，T11 标为 verified。当前共 **37 项 verified、3 项 in progress**；[M05](t39-manual-retry-20261020.md)已完成协助功能复测，实际 Hello 显示已点击 3 次并正常退出；新作者仅按文档完成的原门槛继续保留，T38 / T40 的公开发布门槛仍保留。本轮没有修改生产源码、扩大权限或公开发布。

## 2026-10-20 SDK 正式发布（T38 发布时）

用户要求开始下一步任务后，[T38 SDK 1.0.0](t38-sdk-release-20261020.md)已正式公开，并通过三构件匿名下载、摘要、53 源文件和真实 Quick Start 打包验证。当时 **38 项 verified / 2 项 in progress**；T39 保留新开发者无指导构建安装体验，T40 保留官方插件包与目录发布、真实网络安装。补充 U01 已独立验收。SDK 标签只推送 SDK 专用源码树，主程序 0.6.0 安装包另行处理。

## 2026-10-20/21 官方插件与 Registry 公开（T40 发布时）

[T40 发布与公网验收](t40-registry-publication-20261020.md)及[结构化结果](evidence/t40-publication-20261020/result.json)已关闭原 T40：`plugins-0.6.0` prerelease 四资产匿名 HTTP 200 / 字节摘要一致；仅修改 Registry 两个文件的 PR #3 通过必需 Test and build 后正常 squash 合入 main，merge `7193cdc5021b603abd3a046fed74b027d07c177a`。真实生产 Host 分别通过固定 SHA 目录与默认 main 官方 URL 的网络下载 / 安装，默认来源明确为 `defaultSource=true`；安装后停用 / requested、逐项测试临时授权、VM 预设 KV、新 Host 对象图的磁盘恢复及 Staging 清空均已核对。Registry 回归 29 total / 28 passed / 1 skipped / 0 failures，跳过项为锁屏原生 AppKit 输入，Release 构建通过。

普通 Release 发现页已实测初始离线、点击刷新显示两个公开条目并正常退出；本轮 GUI 安装未完成。Host 对象图恢复不记作 App 进程重启，本轮没有新增真实 GitHub 数据 / Open 结论，既有物理验收按原范围保留。当前 **39 项 verified / 1 项 in progress**；T39 的独立新作者人工门槛按当前安排先跳过并保留，不新增强制人工作业。主程序 0.6.0 安装包与整体 Plugin 1.0 验收继续分别管理。

## 2026-10-21 App 0.6.0 beta.2 公开

[App 发布与公开构件核验](app-0.6.0-beta.2-release-20261021.md)已完成：PR #5、main 和 beta.2 标签的完整检查均为 1087 passed / 5 skipped / 0 failures，Release 构建通过；标签流水线公开三个未公证 prerelease 资产。三个文件匿名 HTTP 200 下载，DMG 实际摘要、App 0.6.0/build4、双架构、签名与 entitlement 独立核验通过，只读挂载后正常卸载。beta.1 源码标签及失败记录保持原样，SDK 1.0.0 源码未改。

此前真实目录 GUI 安装缺口已另行关闭：普通 Release build3 的全新隔离副本完成两个官方包的真实下载、预览和显式停用安装，权限均 requested，正常退出。它与公开 beta.2 DMG 的只读核验分别记录。当前仍为 **39 verified / 1 in progress**；T39 独立新作者、九项硬件 Beta 场景和干净 Mac 首次安装继续待人工，按用户安排先跳过。本次为 App 开发预览发布，不代表整体 Plugin 1.0 验收完成。

## 2026-10-22 当前设备部分验收与 CI 补验（首批）

用户恢复当前设备可做的人工验收后，原样公开 App 0.6.0 / build4 已在 Mac16,12 单内建屏启动，并完成[部分实机观察](evidence/beta-device-20261022/README.md)：悬停与收起、用户确认当前分辨率秒表两侧显示正常、秒表暂停 / 继续 / 重置、真实一分钟倒计时自然完成与确认收起、岛内音量控件和外部键盘调节同步。音量最终恢复 0 和静音，倒计时恢复原 5 分钟预设且未运行。随后用户拖入合成文件，已补验名称 / 大小 / 副本摘要、锁定控件切换和单项移除，保留原两项临时文件并恢复未锁定状态；清空 / AirDrop 与物理锁定保持未验证。音乐暂不播放，显示配置等仍未完成，DI-B01 保持 pending；本轮不关闭 T39、其他硬件或干净 Mac 安装门槛。

main 精确提交 `3ce61ecb73d7b07ae6525180af4901ab656dc69f` 的[一次主动 CI 补验](evidence/main-ci-20261022/README.md)已完成：1092 total / 1087 passed / 5 skipped / 0 failures，Release 构建通过；事件为 `workflow_dispatch`，自动 push 缺失原因未确诊。新增 U02 全分辨率自适应仅列后续计划，目标版本待定；当前仍为 **39 verified / 1 in progress**。

## 2026-10-22 当前设备补充观察与主分支收尾（第二批）

[补充实机记录](evidence/beta-device-followup-20261022/README.md)确认默认 1470×956、实际切换 1280×832／菜单栏自动隐藏并恢复原设置；B02 的物理全屏／Space 仍未验证。文件托盘补齐锁定保持观察和合成单项 AirDrop 打开／取消，清空仍跳过以保留既有两项文件。公开 build4 完成两款官方插件真实 GUI 安装、逐项拒绝／临时授权／撤销；番茄钟 15 分钟预设、暂停／继续／结束及另一轮真实自然完成态，GitHub 仓库切换／刷新、系统浏览器网页打开及撤销后拒绝均有记录。用户确认番茄钟两侧完整与菜单隐藏／显示；岛内和原生菜单两种正常退出、真实重启及撤销／停用持久化通过。短暂 compact 完成提示本轮漏拍，未记录为调度延迟或新通过。

两个插件最终停用、四项权限全部撤销，音量 0／静音，计时未运行，显示设置恢复默认及原菜单栏模式。DI-B01／B02 均保持 pending，九项硬件场景、干净 Mac 与 T39 门槛未关闭；仍为 **39 verified / 1 in progress**，U02 pending／目标版本待定，未修改 App 或冻结 SDK。

首批证据 PR #7 已正常合并为 `8b3a184a9d5e24134f5f10edd566c0e577f20597`，其现成 [main push CI](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39725742204)为 **1092 total / 1087 passed / 5 skipped / 0 failures**，Release 构建通过。本轮只读获取既有成功结果，未 dispatch／重跑；不据此推断旧提交缺失 push 记录的原因。

## 2026-10-22 物理滑杆与发布包七项菜单补验（第三批）

[本轮记录](evidence/beta-controls-20261022/README.md)补齐真实鼠标滑杆：用户操作后实际捕获 0.09551376104354858／10%，恢复 0／静音。六款已有无额外权限样本通过正式流程临时安装并启用，用户确认七项菜单底部选择后停半秒再返回仍展开；助手另行捕获实际七项菜单、底部工具“已点击 0 次”和按钮更新至 1。用户回复后的首图为 compact，未把它当作物理返回的连续证明。样本已全部停用卸载，安装数恢复原两项且四项权限仍撤销；未播放音乐或更改显示设置／托盘文件。

原样公开 build4 的物理 HUD、音乐、安全托盘清空、完整正常离开／重开序列，以及 B02／其他硬件／干净 Mac／T39 仍保留；**39 verified / 1 in progress**，九项硬件场景 pending，U02 pending／目标版本待定。上批 PR #8 合并提交 `a65390d69be73be5168c9be30d0848f8e2a328e7` 的现成 main push CI 39733641959 为 1092 total / 1087 passed / 5 skipped / 0 failures，Release 构建通过；本轮未 dispatch／重跑，不扩大为本批提交结果。

## 2026-10-22 B02 非默认缩放、全屏与 Space 验收（公开 build4）

[本轮 B02 记录](evidence/b02-nondefault-20261022/README.md)完成原样公开 App 0.6.0 / build4 在 Mac16,12 单内建刘海屏、1280×832／菜单栏“始终”自动隐藏的场景验收。用户在复制报告前确认自动位置正常且展开／收起无遮挡；新报告记录1280×832、安全区顶部28 pt、compact156×28及容器(380,592,520,240)。原生全屏可见性和另一个已有普通桌面切换／返回由用户确认，另一次静态原生全屏的完整2560×1664物理截图保存了两侧计时。报告入口会先refresh，App窗口捕获和物理截图、概括反馈和独立测量分别记录。

DI-B02 标为 **passed**，设备矩阵现为 **1 passed / 8 pending**。分辨率已恢复1470×956（默认），菜单栏恢复“仅在全屏幕视图下”，秒表暂停后重置00:00.0；已退出全屏、关闭未改动的合成文档和设置窗口，未新建桌面。未修改App或冻结SDK，未播放音乐、调整音量、变更权限或处理托盘文件。DI-B01剩余检查、其他硬件、干净Mac和T39仍保留；原计划仍为 **39 verified / 1 in progress**，U02 pending／目标版本待定。

上批 PR #9 合并提交 `e4ee3308739b9fef20781cbc6ba0ecb7ef1b1dc5` 的现成 [main push CI 39782298192](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39782298192)已只读确认成功；未dispatch／重跑，不将该结果记作本批提交检查。

## 2026-10-23 U02 分辨率适配开始实施（当前）

用户授权开始 [U02](u02-resolution-adaptation-plan-20261022.md)，目标为 **App 0.6.0 / 未发布开发 build5**，状态为 **in progress**。新增 `IslandDisplayLayout`：以有效 auxiliary 刘海高度 / 32 为参考，按屏幕预算等比限制；Host 设计画布、内容、文字 / 图标和裁切统一变换，实际 compact 相机间隔反归一至设计坐标，Controller 悬停预算同步使用相同参数。`backingScaleFactor` 不作布局倍率。两小时八字符 `02:00:00` 的计时两翼扩展由 126 调整至 150 设计 pt，保留相机间距检查；诊断新增 `layout_scale`。

当前定向 v2 **57 total / 56 passed / 1 skipped / 0 failures** 已通过。首轮全量 **1114 total / 3 skipped / 4 failures** 均来自既有测试的旧 126 pt 预算预期；已修正预期并保留像素检查，完整第二轮 **1115 total / 1112 passed / 3 skipped / 0 failures** 及 Release 构建通过。原生控件专项三档/15点命中通过；普通 Release 隔离 U02 副本已启动。三档模拟对照区分 1470／1280 的已知几何与 1710 的合成几何；132张图已生成，独立抽查14张未见裁切；用户已确认跨分辨率大小统一，新增四项待办并要求本轮停止；后续结果集中追加于[实施记录](u02-resolution-adaptation-20261023.md)。

本轮用户原始显示设置为 2560×1664，已由用户切到 1470×956，最终须恢复本轮原始 2560×1664。系统设置读取工具遇到 SCStream 错误，后续可能需要用户协助确认；这与历史公开 build4 的恢复设置记录分别保留。公开 build4 / DI-B02 的通过证据不改写为 build5 结果；设备矩阵仍为 **1 passed / 8 pending**，T39、其他硬件与干净 Mac 门槛保留，原计划仍为 **39 verified / 1 in progress**，SDK 1.0.0、Runtime / 权限及已发布标签和资产未改。

[PR #10](https://github.com/qyt1340272051-design/DynamicIsland/pull/10)已按正常保护规则合并为 `0858c2a2f698af60cb6836f8e88b5f9ca4369517`，其 exact-head [pull_request CI 39793426412](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39793426412)成功；它验证的是上批 B02 文档 / 证据提交，不代表当前 U02 新提交的 GitHub 检查结果。

## 2026-10-23 U02 实机反馈与本轮停止点

用户已确认不同分辨率下显示大小统一，同时报告四项待修：收起两翼过宽、展开整体偏大、高分辨率内容模糊和膨胀动画顶部缝隙。[U02-07至U02-10](u02-followup-todo-20261023.md)均为pending；按用户要求本轮停止继续实现，保留代码、测试和[开发检查点](evidence/u02-resolution-20261023/README.md)。U02保持in progress，原39/40与已发布build4设备结果不变。最终显示设置和暂停计时状态下轮继续前重新确认，不记为已恢复或已完成清理。

## Phase 0 — 准备阶段：项目审计、分支与基线

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T01 | 项目架构审计 | 无 | `verified` | [Phase 0 基线记录](phase-0-baseline.md)记录了真实依赖图、职责边界、迁移调用点、多屏约束及审计结论。 |
| T02 | 开发分支与基线测试 | T01 | `verified` | [Phase 0 清单](phase-0-baseline.md)与[真实基线](t02-t08-acceptance-20261019.md)保留普通 Release 启动 / 退出、300 秒静置和 303.534 秒量化采样；历史设备场景按来源独立归并。[本轮 M03](t02-t37-manual-acceptance-20261019.md)补齐菜单隐藏 / 显示：用户确认消失与恢复，恢复实际 UI 另行捕获；隐藏 AX 超时不冒充截图证明。旧资源数值仍是修正前冻结起点，不扩大为新 UI 或重构前后对照。 |

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
| T11 | Presentation Model | T09 | `verified` | [纯数据三形态](../../DynamicIsland/Core/Activity/IslandActivity.swift)、[Host 回退策略](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift)与正式 IslandView 的右翼 minimal 已实现，[24 项定向与受控几何记录](t10-t11-acceptance-20261019.md)通过。[2026-10-20 M04 实机](t11-manual-acceptance-20261020.md)第三轮完成真实按钮开始、609 条连续收起观察中的右侧时间 → 左图标 / 右时间、重新展开时的计时 / 进度连续和真实停止。opaque 实例 / generation 绑定由未改的真实包源码与正式 Host 契约证明，未冒充 UI 读取；AX / 像素出现时间及未新增设备矩阵的范围分别保留。 |
| T12 | IslandRenderer | T09–T11 | `verified` | [受限 SwiftUI 映射](../../DynamicIsland/IslandUI/IslandRenderer.swift)、[12 类节点/三态/152、190、200 pt 壳尺寸测试](../../DynamicIslandTests/IslandRendererTests.swift)和 [Phase 2 验证记录](phase-2-renderer-action-router.md)；`./Scripts/ci.sh` 220 tests、1 skipped、0 failures、Release build passed。 |
| T13 | ActionRouter | T12 | `verified` | [实例绑定与生命周期校验](../../DynamicIsland/IslandUI/ActionRouter.swift)、[路由及旧实例 / 权限测试](../../DynamicIslandTests/ActionRouterTests.swift)、[DEBUG 渲染入口](../../DynamicIsland/Core/Activity/ActivityDebugPanel.swift)与 [Phase 2 历史验证记录](phase-2-renderer-action-router.md)；当时 CI 同上。历史原生计时适配器及其闭环测试已在 T35 迁移时删除，当前公开插件的暂停 / 继续 / 停止闭环见 [Pomodoro VM / Router 集成测试](../../DynamicIslandTests/PomodoroPluginTests.swift)与[迁移记录](phase-7-t35-pomodoro.md)。 |

[2026-10-20 Phase 2 统一检查](phase-2-acceptance-20261020.md)已归并 T09–T13 的分项完成标准、后续普通 Release 实机及十项阶段检查。历史自动 / 设备结果与本次观察分别保留，未新增性能或设备矩阵声明。

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
| T37 | SuperIsland Adapter | T35 | `verified` | [六类 View](phase-8-t37-view-conversion.md)、[同 VM 模块](phase-8-t37-module-runtime.md)、[Host 请求](t37-presentation-requests.md)与[兼容详情](t37-compatibility-details.md)已实现。按用户选定范围交付[三个原创兼容子集示例](t37-independent-examples.md)，真实 Validator / VM / Router 集成及[完整回归](evidence/final-regression-20261019/result.json)通过；[本轮 M03 实机](t02-t37-manual-acceptance-20261019.md)完成按钮、0–100% 进度、跨工具隔离、停用菜单移除与再启用初值。旧动作拒绝 / critical 抢占沿用明确自动证据；原样上游许可和能力差距保留为限制，不宣称完整兼容。 |

## Phase 9 — SDK、文档与插件生态

| ID | 任务 | 前置依赖 | 状态 | 验收证据 |
| --- | --- | --- | --- | --- |
| T38 | DynamicIsland SDK | T36 | `verified` | [SDK 1.0.0 正式发布](t38-sdk-release-20261020.md)：[sdk-v1.0.0](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/sdk-v1.0.0) 的 SDK 专用源码标签、85,192-byte ZIP、SHA-256 与清单已公开；未推送 Host 开发分支。仓库 SDK 40 passed、类型正例 / 47 项预期错误、15 页 / 9 块 / 34 链接通过；正式 Host 契约 8 passed，独立 SDK 38 passed / 2 repo-only skipped，重打字节一致。三份公开资产匿名 HTTP 200 / 摘要 / 53 文件校验及下载后的实际 Hello 打包通过。有限 API / 兼容与版本策略已冻结，两个官方插件实战依赖满足；T39 新作者体验和 App 0.6.0 安装包分别保留，T40 按独立公网证据验收。 |
| T39 | 开发者文档与模板 | T38 | `in progress` | [13 主题手册](../../SDK/docs/README.md)及[T39 记录](phase-9-t39-developer-docs.md)已实现；[SDK 1.0.0](t38-sdk-release-20261020.md)公开构件的 15 页 / 9 源码块 / 34 本地链接通过。用户首轮 zsh 卡点与成功输出 / 路径说明已修正，[2026-10-20 M05](t39-manual-retry-20261020.md)保留打包解释、预览定位协助，正确 Hello 已安装启用、实际计数 3 次并正常退出。AI 独立离线编写与 Host 自动闭环、用户协助复测均不代替新作者无指导门槛；使用发布 SDK 的独立构建安装及约十分钟目标按当前安排先跳过并保留。T38 前置已满足。 |
| T40 | Plugin Registry | T38 | `verified` | [公开发布与真实网络验收](t40-registry-publication-20261020.md)、[结构化结果](evidence/t40-publication-20261020/result.json)：`plugins-0.6.0` prerelease 四资产匿名 HTTP 200 / 摘要一致，Registry 两文件 PR #3 通过必需检查后正常合入 main。生产 Host 的固定 SHA 与默认 main 官方 URL 网络安装分别 1 passed / 0 skipped / 0 failures；核对停用 / requested、逐项测试临时授权、VM 预设 KV、新 Host 对象图磁盘恢复及 Staging 清空。Registry 回归 29 total / 28 passed / 1 skipped / 0 failures（锁屏原生 AppKit 输入），Release 构建通过。普通 Release 发现页初始离线、刷新后两公开条目已截图；本轮 GUI 安装与 App 进程重启未作为通过项，不新增强制人工门槛。历史完整回归及[本地发布准备](t40-release-preparation-20261019.md)保留原范围。 |

[Phase 9 统一检查](phase-9-acceptance.md)已归并 T38 的稳定 SDK 发布和 T40 官方包 / 公开目录 / 真实网络 Host 安装证据；仅 T39 保持 `in progress`，独立新作者人工门槛按当前安排先跳过并保留。SDK 1.0.0 与主 App、整体 Plugin 1.0 发布验收分别管理。

## 用户补充待办

以下项目独立于原 T01–T40；原计划当前为 39 项 verified / 1 项 in progress，补充 U01 已 verified，U02 正在实施。

| ID | 任务 | 状态 | 安排与验收 |
| --- | --- | --- | --- |
| U01 | 工具菜单越界与展开保持 | `verified` | [实现与验收记录](u01-tool-menu-20261020.md)：第三版固定 2 秒返回宽限、原 30Hz `.common` 采样及到期物理位置复核。96 项定向、普通 Release / 签名通过；用户确认底部工具返回保持与正常离开重开清理，日志佐证到期 inside=true。本轮实测 End / Return 访问最底部、按钮更新、Esc / 点外取消及音乐 / 拖盘 / 内置计时切换通过，副本正常退出、Staging 为空。范围为当前设备实际七项菜单；两次自动滚轮未观察内容变化，不单独记滚轮通过，前两轮失败和唯一根因未确诊的记录保留。 |
| U02 | 全分辨率自适应 | `in progress` | [计划与实施状态](u02-resolution-adaptation-plan-20261022.md)：2026-10-23 用户授权 App 0.6.0 / 开发 build5，已实现 Host 统一布局变换、相机间隔反归一、Controller 命中同步及 layout_scale 诊断。定向 v2 57 total / 1 skipped / 0 failures；首轮全量旧计时预算预期已修，全量第二轮1115 total / 3 skipped / 0 failures及Release通过，132图生成/14图抽查与原生控件专项通过，本轮真机对照进行中，详见[实施记录](u02-resolution-adaptation-20261023.md)。公开 build4 / B02 来源、原 T01–T40 与独立人工门槛保留；当前不标 verified。 |
