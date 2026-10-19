# Phase 7 — 安装、管理与官方插件阶段检查

日期：2026-10-19。范围 T33–T36，四项任务均为 `verified`。用户本次恢复集中人工验收后，[M01 / T35](evidence/t35-manual-20261019/result.json)已补齐真实十五分钟自然到期的安全两翼提示、正常消失 / 不重开及退出；[M02 / T36](evidence/t36-manual-20261019/result.json)已完成真实公开网络工具页、逐项授权、仓库切换 / 刷新、系统 Open 与正常退出。Phase 7 的任务内缺口已关闭，实机二进制、自动回归、历史记录和设备 / 性能边界分别保留。

分项记录：[T33 管理与逐项授权](phase-7-t33-extensions-settings.md)、[T34 安装与事务](phase-7-t34-installer.md)、[T35 Pomodoro](phase-7-t35-pomodoro.md)、[T36 GitHub](phase-7-t36-github.md)。早期延期、漏拍、失败和恢复均保留在原证据；当前结论以本日真实记录为依据，不将历史漏拍或 completed 存储替代为可见性证据。[人工清单](MANUAL_ACCEPTANCE.md)继续追踪其他任务的用户安排。

## 统一检查

| 项目 | 已有证据 | 本轮状态与边界 |
| --- | --- | --- |
| 功能 | T33 的管理、逐项批准 / 拒绝 / 撤销和持久化，T34 的预览、安装后停用、启停卸载、升级 / 回滚及 Finder 入口已完成分项验收。T35 历史普通 Release 已验证开始 / 暂停 / 继续 / 结束、预设恢复、不自动开表、非法设置、秒表 / 倒计时 / 音乐 / 空拖盘切换与收起重选，见[历史实际 UI](evidence/t35-pomodoro-final-20261016/result.json)及[安装 / 权限 / 重启](evidence/t35-pomodoro-ui-20261016/result.json)。 | [M01](evidence/t35-manual-20261019/result.json)实际捕获 0.2.1 完成提示的安全两翼、单次正常消失 / 不重开；[M02](evidence/t36-manual-20261019/result.json)完成真实导入、逐项批准、公开 CI / PR 五行、切仓 / 刷新与 Safari 当前目标。两项均正常退出；本轮没有重新执行全部旧功能。 |
| 架构 | [T35 迁移](evidence/t35-pomodoro-migration-20261016.json)已删除 Pomodoro 专用生产 Swift；当前生产 Swift 搜索 `pomodoro` / `番茄` 无命中。两款官方包通过公开 Activity / Node / Action / Storage / Scheduler 等接口工作；倒计时及 Links 由通用 Host API 提供，选择、窗口与几何仍归 Host。见[倒计时合约](t35-countdown-api.md)与[Links 合约](t36-links-api.md)。 | 官方插件没有私有窗口或原生对象入口。后续兼容模块、SDK、Registry 的通过与否不由本阶段页面替代。 |
| 并发 | [Storage / Scheduler 集成](evidence/t35-pomodoro-3b-20261016.json)及迁移回归覆盖存储 / 交互双 FIFO、共享准入、慢写、撤销和满队列回复；owner / execution / generation、完成 receipt ACK、旧回调和动作一次性凭证均有自动覆盖。T36 覆盖仓库切换的旧响应、慢存储去重、已呈现链接绑定及权限 / 资源撤销，见[T36 自动结果](evidence/t36-github-20261017/result.json)。 | 自动化使用真实 VM / Bridge / Manager / Router，但可替换传输、opener 与 Host 时钟；不能写成真实上游网络竞态或所有系统调度已实测。 |
| 性能 | [显示节点](evidence/t35-countdown-node-20261015/result.json)验证可见运行叶共用一个秒级显示 Task，静态、隐藏、暂停、失效、完成及 shutdown 释放需求；JSON / 节点 / Activity / 请求资源保持既有上限。 | 本阶段没有新增插件专属 CPU、内存、长期增长或动画帧率量化。T02 / T08 等既有性能缺口继续独立追踪，不据此声称无性能回退。 |
| 能耗 | Pomodoro 每执行只请求一次有界对账；GitHub 默认通过集中 Scheduler 请求五分钟刷新、合并在途请求并对错误退避。没有每 VM 定时器或每秒 JS 更新。集中调度继承[T31 真实后台测量](evidence/t31-background-20261014.md)及其 30 / 60 秒策略下限。 | T31 的二十个 scheduler-only 插件和单次顺序对照只代表原负载；不等于 Pomodoro / GitHub 专属耗电，也不代表电池、低功耗或睡眠能耗实测。 |
| 安全 | T33 / T34 强制安装不运行、启用不授权、代码 / Manifest 变化重新审核；包先验证再安装，敏感 Broker 调用仍受 Host 权限 lease、会话、实例、URL 政策及资源 gate 检查。T35 已实际验证拒绝 / 撤销存储仍可计时、畸形设置回退和清理失败恢复，见[实际清理故障](evidence/t35-quit-cancellation-20261016/result.json)。 | [T36 本轮](evidence/t36-manual-20261019/result.json)确认安装后停用 / 三项待授权，逐项批准后才启用；撤销 links.open 出现固定失败，重新批准后的新点击实际切至 PR 页面。继承 Phase 6 的 DNS preflight、JavaScriptCore 无限循环 / OOM / VM 崩溃隔离边界，不新增硬 CPU 或进程隔离承诺。 |
| 隐私 | GitHub 使用公开 API 示例，不申请、读取或存储 Token；Pomodoro 只保存预设和 lastSession 元数据。固定错误与诊断边界继承 T32，不把 API 响应、任意 JS 正文或底层系统错误当成诊断输出。见[GitHub 包说明](examples/github/README.md)及[Phase 6 隐私复核](phase-6-acceptance.md)。 | 普通 KV 为本机明文 JSON，不是 secret storage。系统浏览器接管后的跳转 / 登录由浏览器处理；Host 的 Open 成功只表示系统接受请求，不保证页面加载成功。 |
| 兼容 | 共享 Host 屏幕 / 面板 resolver；T35 历史实机确认运行图标 / 时间位于物理相机两侧，四种时间宽度及 0.2.1 完成布局另有真实 Renderer 像素检查，见[自动 compact](evidence/t35-compact-policy-20261015/result.json)和[完成布局](evidence/t35-completion-layout-20261016/result.json)。 | 单台 arm64 MacBook Air 上，[本轮早期](evidence/t35-manual-20261019/completion-early.jpg)、[中段](evidence/t35-manual-20261019/completion-middle.jpg)、[末段](evidence/t35-manual-20261019/completion-last.jpg)实际完成画面确认物理相机两侧安全可见。未重新执行多屏、无刘海、外接屏拔插、真实睡眠 / 低电量及 Reduce Motion 全矩阵；相关 Host / 生命周期历史与 fixture 范围单独保留。 |
| 测试 | 分项 CI / Release / strict 签名证据见 T33–T36。后续[完整回归](evidence/t40-registry-ui-20261018/result.json)为 1060 passed / 8 skipped / 0 failures，Release 构建通过；[2026-10-19 原生输入补验](evidence/native-input-20261019/result.json)在 checkpoint 253c588 上另跑六项真实 AppKit 输入，6 passed / 0 skipped / 0 failures。 | 六项补验清除了前次锁屏输入缺口，不能合并改写成一次完整 CI 1066 passed。其余默认选测为截图矩阵和实时 GitHub API；后者在原 T36 选测中曾单独通过。本日 M01 / M02 实机与系统 Open 独立归档，不冒充当前 HEAD 的新完整 Release 实测。 |
| 回滚 | 管理、安装与生命周期已验证停用 / 卸载 / 升级 / shutdown 撤销旧执行、动作和资源；升级后停用且代码变化须重审。历史清理失败保留 review 与原暂存身份，可恢复重试；0.2.1 上轮正常退出后 PID 消失、Staging 为空并保留 Installed / 设置 / 授权，见[上轮清理](evidence/t35-v021-final-20261017/cleanup.json)。 | 本轮[T35 清理](evidence/t35-manual-20261019/cleanup.json)与[T36 清理](evidence/t36-manual-20261019/cleanup.json)分别确认正常 Command-Q 后 PID 80223 / 82621 消失，Staging 均为空，包、启用状态、各自设置和授权保留；未修改生产 App。 |

## 实机来源与当前代码的关系

本次 M01 使用[预检记录](evidence/t35-manual-20261019/preflight.json)中确认的独立 T35 App，真实开始信息见[本轮 run](evidence/t35-manual-20261019/run.json)。它是历史普通 Release 二进制，不能称作当前 HEAD 构建。[旧 run 的来源说明](evidence/t35-v021-final-20261017/run.json)明确 `hostBuildCommit` 未盖章，指向的 setup 中八项 Host 源码 hash 匹配 checkpoint `0b96cab`；`50211d9` 只是当时验收工作区检查点。

当前 Pomodoro 0.2.1 的 Manifest、JS、README 与历史安装记录 hash 一致。完成两翼修复 `60cb5ce` 只修改插件提交的 compact / expanded 树。[本日 Host 来源核对](evidence/t35-manual-20261019/host-provenance.json)确认当前 IslandView、Renderer、节点 Schema、展示策略、面板几何、视觉样式、Activity 转换与 countdown Broker / Session 的相关源码仍与该历史 checkpoint 一致。后续 Host 已扩展 Links、兼容模块及展示请求仲裁，因此只能把本次画面归属于实际记录的独立二进制；当前代码的行为由后续自动回归分别支撑，不能声称旧副本等于 HEAD。

M02 使用[本日预检](evidence/t36-manual-20261019/preflight.json)确认的原 T36 独立普通 Release，实际可执行 hash 与[原准备记录](evidence/t36-github-20261017/result.json)一致。GitHub JS / Manifest、Links Broker、ActionSession 和相关插件 / Links 集成测试与原证据一致；Host JSBridge / Bootstrap / Manifest 后来有兼容能力扩展。实机实际显示的 run key `39115930522.1` / `39184461294.1` 和 PR #1687 / #14727 来自本次公开 API；Safari 真实构建 / PR 目标见[本轮结果](evidence/t36-manual-20261019/result.json)，没有复用旧投影充当当前页面。

## 本轮完成与阶段结论

1. **M01 / T35：通过。** [连续捕获](evidence/t35-manual-20261019/capture.json)在内存连续采集 2459 帧，归档 7 个选帧及全部 69 帧完成 AX 时间，Start 后 900.836–900.93 秒首次观察到完成 AX，只有一个完成区间。最早 AX 帧尚未绘制提示，可见性仅使用后续实际像素；安全两翼、正常消失 / 不重开及清理均通过。
2. **M02 / T36：通过。** [真实网络与系统 Open](evidence/t36-manual-20261019/result.json)覆盖导入、安装后停用 / 三项待授权、独立批准、启用、五行工具、切仓 / 刷新、Safari 构建 / PR 页面、撤销失败提示及再批准后的新点击。排队 / 运行 / 完成、离线、失败、限流和旧 activation 边界另有真实 VM 集成覆盖，未宣称实机公网经历全部状态。
3. **阶段收尾：完成。** 当前 T33–T36 均 verified，Phase 7 的任务内延期已关闭。上述实机证据来自各自明确身份的历史普通 Release，与当前 HEAD 自动回归共同组成任务证据；不扩大为当前 HEAD 的全量产品实机验收。

本阶段检查不关闭 T02 / T08 / T10 / T11 的独立历史缺口，也不替代 T37 上游兼容、T38 稳定 SDK、T39 新作者体验或 T40 公开 Registry 安装验收；不构成 0.6.0 发布、tag 或 DMG 验收。
