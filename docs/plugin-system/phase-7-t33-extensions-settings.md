# Phase 7 — T33 Extensions Settings UI

日期：2026-10-12–13。依赖 T20 已验收；实现与验证完成。

## 管理入口与显示

状态栏「插件管理…」及 App 的 Settings 场景使用同一个 Host 模型。已安装页面提供名称、版本、开发者、运行 / 暂停 / 错误 / 隔离状态、原生 JavaScriptCore 模式与最低 Host 版本。Discover 按原计划后置；本任务不伪造在线目录或 SuperIsland 兼容能力。T34 提供导入安装流程。

V1 Manifest 增加可选 `developer` 自述文本，旧九字段包仍可解析。开发者显示不构成签名 / 身份验证；文本与 name 共用 80 个 Unicode scalar 的可打印和防控制字符规则。JSON Schema 同步，未知键仍拒绝。开发者变更进入权限与 Watchdog 指纹，不继承旧批准。

启用与停用不会批准权限。停用先关闭 Runtime / 所属 Activity / 动作及所有 Broker 会话，再保存 Manager 状态；保存失败仍保持本次执行停止并显示固定错误。卸载弹窗捕获不可变包，Manager 在串行事务中检查包仍匹配；旧确认不能移除同 ID 替换代码。成功卸载在同一 Manager 事务中清理授权与事故历史，避免未来并发安装误清理新包。插件 KV 数据保留，弹窗明确说明。

列表和权限状态通过生命周期 / 权限 observer 合并刷新，没有轮询或重复 discover。用户操作等待当前读取完成，不因被动刷新而丢弃。诊断 / 明确重启复用 T32 的 Host 界面与事故窗口。

## 权限确认与持久化

每项声明显示用途和 requested / granted / denied / revoked 状态。读取与写入剪贴板各自批准，读取确认明确说明敏感数据；通知与日历暂未实现 Broker，显示「尚未支持」并禁用批准。Grant 弹窗绑定确切 Host review scope，替换代码或声明后旧确认失败。

批准先原子保存再打开 gate，撤销 / 拒绝先关闭旧 lease 再保存。保存失败不让新批准生效；撤销保存失败仍关闭本次执行的访问并显示错误，不宣称已永久保存。正式 Manager 在启动 Runtime 前等待授权准备步骤，只有当前不可变包完全匹配的已保存决定可恢复。

授权文件是 Host 的 `State/plugin-permissions-v1.json`。指纹覆盖 Manifest 全部字段（声明排序规范化，包括 developer）与入口代码 SHA256。新 / 变化包先登记全部 requested，不把以前代码的批准自动导入；同一进程退回早先代码也不能复活批准。关闭 App 只关闭本次 lease，不把正常的已保存批准改写成撤销。

持久化由独立 actor 执行 I/O：128 个插件、每项七种已知权限、文件最多 128 KiB；严格 schema / 键 / 值 / 身份 / 指纹检查，重复键和未知字段拒绝。目录 / 文件要求用户所有且私有权限，拒绝符号链接 / 硬链接 / 非普通文件。有界读取、临时文件 fsync 和原子 rename；损坏状态不自动修复或覆盖，不承诺断电时父目录 fsync 持久保证。

准备授权期间的并发撤销不能被磁盘 grant 覆盖。各权限 decision generation 及 Host 写入 FIFO 防止旧批准交付，过期保存也不能覆盖新包记录。正常卸载移除记录；移除失败会保留本次运行的撤销与明确错误，下一次启动的磁盘恢复仍依赖成功保存。

## 验证

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 核心定向 | 91 passed、0 skipped、0 failures；模型 14、授权存储 17、持久化集成 15、权限 17、Manager 14、生命周期 14。 | `/tmp/dynamic-island-t33-core-targeted-v2/TestResults.xcresult`。 |
| 原生 UI 定向 | 3 passed、0 skipped、0 failures；真实 AppKit 鼠标触发启停、分项确认 / 取消 / 拒绝 / 撤销、诊断、卸载确认 / 取消。 | `/tmp/dynamic-island-t33-ui-final-panel/TestResults.xcresult`。 |
| 完整 CI / 普通 Release build | 648 total、647 passed、1 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t33-final-ci-v3/TestResults.xcresult`、同前缀 `.log`。 |
| Release 核心定向 | 146 passed；同一轮的 UI 项暴露测试宿主焦点 / 事件时序问题，修复 fixture 后单独复测 UI。 | `/tmp/dynamic-island-t33-release-tests/TestResults.xcresult`；该旧 bundle 中 3 项 UI 未全通过，不能称整个旧 bundle 已通过。 |
| Release UI 修复后定向 | 3 passed、0 skipped、0 failures；与核心定向合计 149 项通过。 | `/tmp/dynamic-island-t33-release-ui-final/TestResults.xcresult`。 |
| 普通 Release 签名 | strict / deep 核验通过；Sandbox / allow-jit 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t33-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t33-release-entitlements.plist`。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。唯一 CI skip 是既有截图矩阵生成入口。Release 测试注入 / library-validation 例外仅位于临时测试 Host，普通 App 无该例外。

800×600 的生产 NSWindow 元数据 / 完整权限及空列表画面通过本地 PNG / Vision 检查；交互测试使用承载同一 production View 的非激活 NSPanel，避免 XCTest Host 抢不到系统焦点导致按钮首击被吞，同时分别派发 AppKit down / up。这属于原生 fixture 交互证据，未声称已验收普通 App 的全部真实窗口 / VoiceOver 场景。NSAlert 文案及原生按钮确认 / 取消通过；其 cacheDisplay 材质截图不完整，没有作为截图验收证据。

截图：`/Users/rong5/Library/Containers/com.rong5.dynamic-island-mac/Data/tmp/dynamic-island-t33-extensions.png` 与 `dynamic-island-t33-management-confirmed.png`。

旧确认不能授予替换代码 / 卸载同 ID 新包；并发准备与撤销、卸载后排队重新安装、损坏存储、保存 / 清理失败、真实 JS Activity 停止、KV 保留、unsupported 权限均有集成测试。Manifest 定向现为 16 项，optional developer schema 已同步。

既有 T31 的正式 App 多插件长时 Energy Impact / 实际能耗缺口继续独立保留，T35 的全范围依赖仍需复核。
