# Phase 6 — T32 Crash Watchdog / Logging

日期：2026-10-12。依赖 T22 已验收；本任务完成并验证。

## 失败、隔离与恢复

每个插件按不可变 Manifest 和入口代码绑定 process-local Watchdog；同包普通重载 / 启停保留失败历史，包版本、代码或元数据变更创建新 scope。最多跟踪 128 个插件，每插件保留最近 3 次失败，使用单调时钟的 60 秒窗口。旧 VM 的执行 token 不能影响替换会话。

严重事件包括 Host 认定的启动失败，以及实际动作回调抛异常 / 返回 Promise 拒绝。60 秒内第 3 次立即禁用该插件的执行：关闭 storage / network / resource / refresh 的准入、注销动作并结束所属 Activity，再异步持久化 Manager 禁用状态。正常插件、内置功能与主程序继续运行。清理错误只记录诊断，不进入严重失败预算。

动作失败由 bootstrap 的私有闭包发送固定类别 `exception` / `rejection` / `limit`；没有公开 runtime SDK。普通 `island.log(..., 'error')` 不计事故，Promise 并发超额的 limit 也不计事故。Broker 明确拒绝本身不计事故，但动作回调返回未处理的 rejected Broker Promise 属于真实 actionRejection。

Manager 的 FIFO 校验当前不可变包与隔离事件，过期的异步禁用不能写入替换插件。用户重启先经 Manager disable / reload，再清除确切隔离事件并 enable；同包窗口历史保留，因此仍然出错会再次隔离。状态写入失败时保留本进程隔离和固定错误诊断，不自动恢复 Runtime。

Watchdog 覆盖可捕获异常。无限循环或无法返回的 VM 线程仍没有公开 API 的强制抢占 / 杀死能力，不能声称任意挂死恢复或硬 CPU 时间上限。

## 诊断与隐私

Host 记录插件 ID、时间、序号、级别、分类、阶段和固定错误码 / 文字。任意 JS 日志正文全部丢弃；JS exceptionHandler 不读取 thrown value 的 message / stack / toString，也不保留原始字符串异常。OSLog 同样只接收固定文字。文件路径、剪贴板正文、文件正文、URL 与 token 不进入日志展示。

诊断只保留在进程内：每插件 100 项、全局 1000 项、最多 128 个 ID，满额淘汰最旧记录。清除记录不会重置事故窗口。测试需要日志回传确认时，只在测试 VM 内保留标记，并且等待真实 Host Promise acknowledge；生产 Host 不恢复原文。

状态栏「插件诊断…」打开 Host SwiftUI 窗口，显示已安装插件的名称、版本、运行 / 错误 / 隔离状态，以及选中插件的固定诊断记录。生命周期和日志 observer 合并刷新，用户操作等待当前读取完成；重启仅记录请求，不提前宣称异步 JS 启动成功，随后失败会刷新固定错误状态。用户可刷新或明确重启，无自动循环重试、额外轮询或技术权限自动批准。完整 Extensions 管理及权限批准界面仍按 T33 提供。

## 验证

新增 45 项测试：[`PluginCrashWatchdogTests`](../../DynamicIslandTests/PluginCrashWatchdogTests.swift) 15 项；[`PluginDiagnosticsTests`](../../DynamicIslandTests/PluginDiagnosticsTests.swift) 7 项；[`PluginWatchdogPersistenceTests`](../../DynamicIslandTests/PluginWatchdogPersistenceTests.swift) 6 项；[`PluginDiagnosticsUITests`](../../DynamicIslandTests/PluginDiagnosticsUITests.swift) 7 项；[`PluginWatchdogIntegrationTests`](../../DynamicIslandTests/PluginWatchdogIntegrationTests.swift) 10 项。

覆盖窗口计数 / 包变化 / 旧 token / 确切重试、真实 JS 第三次动作异常与混合 Promise 拒绝、正常插件继续交互、普通 error 日志不能伪造事故、实际启动与清理异常、Manager 磁盘恢复 / 写失败保护 / FIFO 替换竞争、真实字符串异常与日志中的敏感内容丢弃，以及公共刷新 / 重启等待、错误状态和原生窗口渲染。旧日志正文测试迁移为 VM 内的回传确认，不恢复 Host 原文。

初次 CI 发现界面被动刷新造成用户请求提前返回，已修复操作等待与刷新合并；原始 NavigationSplitView 截图裁切也改为完整的固定侧栏布局。修复后 7 项 UI 定向通过，根任务检查原生窗口截图，确认完整的名称 / 状态 / 刷新 / 重启 / 隔离提示与日志，没有裁切。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 598 total、597 passed、1 skipped、0 failures；Release build passed；无新 Swift 编译警告。 | `/tmp/dynamic-island-t32-final-ci-v2/TestResults.xcresult`、`/tmp/dynamic-island-t32-final-ci-v2.log`。 |
| Release 定向 | 45 项新增 + Runtime 29、Action 18、Bridge 23、Lifecycle 14、生产 graph 2 = 131 passed、0 skipped、0 failures。 | `/tmp/dynamic-island-t32-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t32-release-tests.log`。 |
| 普通 Release 签名 | strict / deep 核验通过；Sandbox / allow-jit 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t32-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t32-release-entitlements.plist`。 |
| 原生窗口 / 最终图片 | 7 UI/model 定向通过，720 × 480 窗口完整渲染；随后全量与 Release 均再次通过。 | `/tmp/dynamic-island-t32-ui-render-results/TestResults.xcresult`、[已检查的窗口图片](/tmp/dynamic-island-t32-diagnostics.png)；测试另保存到 App container tmp。 |
| 调度 CPU 回归 | 10 秒基线单核心 CPU 0.258%，20 VM 0.260%，额外调度唤醒 0。 | 最终 CI 的 `T31_IDLE_CPU` 与附件；不替代长时电耗实测。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。唯一 CI skip 为原截图生成，真实鼠标控件回归通过。Release 测试注入 / library-validation 例外仅用于临时测试 Host，普通 App 无该例外。

T32 按计划完成标准 verified：真实 JS 错误插件自动停止，其他插件与主程序图继续运行；诊断 / 重启入口和持久化保护均可复核。下一独立任务 T33。

Phase 6 尚未整体验收：T31 的正式 App 多插件长时能耗证据待补，T30 的真实选择器交互也尚未手动执行；本记录不替代那些证据，不构成 0.6.0 分发发布。
