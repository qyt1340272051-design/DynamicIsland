# Phase 4 — Plugin Core 阶段检查

日期：2026-10-09。范围：T18 PluginManifest、T19 PluginValidator、T20 PluginManager、T21 Plugin Lifecycle。阶段目标是建立 Host 管理的插件身份、静态包验证、发现与启用偏好、生命周期及清理边界。

## 已实现的阶段能力

- T18：[Manifest 记录](phase-4-t18-plugin-manifest.md)定义 V1 字段、严格解析、插件 ID、语义化版本及 JSON Schema。未知权限与 capability 失败关闭。
- T19：[Validator 记录](phase-4-t19-plugin-validator.md)检查 Host 版本、重复 ID、入口、路径、symlink、文件数量/大小，并返回不可变入口字节。
- T20：[Manager 记录](phase-4-t20-plugin-manager.md)实现受控目录中的发现、静态加载、独立启停、重载、卸载与 V1 状态恢复，包含状态提交及卸载回滚保护。
- T21：[Lifecycle 记录](phase-4-t21-plugin-lifecycle.md)定义六个状态、Swift Runtime Bridge、每会话执行 token、Activity/action 清理、Manager hooks、FIFO 变更顺序及正式 App 环境接入。

启用偏好与运行状态分别维护。Phase 4 完成时，生产组合根缺少 JavaScript Runtime factory；插件可被静态发现和登记，入口源码作为已验证数据保留。后续实际 JSContext 与执行闭环见 [T22 Runtime 记录](phase-5-t22-javascript-runtime.md)；本记录保留 Phase 4 当时的验收边界。

## 按计划统一检查

“代码确认”表示可以从实现审查得到该结论；“自动化证据”指测试 fixture 的覆盖范围；涉及设备行为和性能测量时单独保留人工证据缺口。最终 CI 已包含 T21 全部 27 项新增测试。

| 检查项 | 当前确认与证据 | 仍需后续证据 |
| --- | --- | --- |
| 功能 | T18/T19/T20 已有验收记录；T21 测试覆盖全部状态转换、真实 Manager API 到 Swift 测试 Runtime、独立启停、多个暂停原因和卸载前清理。禁用只清理目标 source。 | 实际 JS 插件启动、停止、恢复、更新和官方插件端到端行为待 T22–T36；正式 App 的 Music/Volume/Battery 回归需随最终验收补充。 |
| 架构 | Manifest/Validator 负责输入与包；Manager 负责静态登记/持久化；Bridge 负责运行边界；Environment 负责系统条件。插件 Activity 经正式 ActivityManager/ActionRouter，Renderer 继续由 Host 控制。 | 实际 JS Bridge、Broker、Installer 继续遵守这些边界，待对应任务审查。 |
| 并发 | Manager 每个公开变更入口持有 FIFO ownership 到 MainActor hooks 完成；Lifecycle 与 UI/Activity 修改在 MainActor。并发启停测试核对静态偏好、运行状态和旧 token；环境旧 generation 与后台排队事件有回归测试。 | 真实 JS 异步完成、定时器、Runtime teardown 和执行超时需在 T22/T31/T32 验证；现有测试不能证明未来 JS 工作自动安全。 |
| 性能 | 静态包校验有文件数量与大小上限。生命周期转换只处理登记插件与其 Activity；T21 没有新增每插件刷新循环。 | 本阶段未取得正式 Release App 空闲 CPU/内存、动画帧率或 Instruments 数据；实际插件运行后需同设备基线比较。 |
| 能耗 | Environment 只做初始读、BatteryService 事件读及唤醒读，无 Timer/polling；睡眠和低电量关闭已有执行会话。20% 进入、25%/AC 退出降低阈值抖动。 | 自动化模拟不代表实际能耗测量；真实电池、睡眠与插件后台工作的能耗证据仍待设备验收及 T31。 |
| 安全 | 严格 Manifest、受控目录、不可变入口、包配额、ID 复查已由 T18–T20 验证。T21 每会话 token、source 激活与动作实例 token 共同撤销过期执行/交互；卸载前清理所有 source Activity。 | Manifest 权限声明尚未成为运行时授权；PermissionManager/Broker 待 T28–T30。T22 需明确 JSContext 非完整安全沙箱与受控 Bridge 限制。 |
| 隐私 | 当前启动日志只记录稳定错误 code 或通用配置失败；环境错误记录读取/监听故障，不记录入口源码、Token、剪贴板或文件内容。状态 JSON 只保存版本和启用偏好。 | JS 日志、插件诊断、存储与 Broker 的敏感值处理待 T27–T32；当前实现不能预先认可后续日志策略。 |
| 兼容 | Environment 处理无内置电池、AC、睡眠和唤醒；多个暂停原因独立，读取失败不清除已有条件。Activity 渲染仍使用原 Host 屏幕与几何路径。 | 本阶段系统事件主要为注入通知/FakeBatteryService；尚无真实合盖、低电量、屏幕热拔插、多屏或无刘海设备的新增 Plugin Lifecycle 证据。Phase 3 人工结论不能替代新增插件生命周期实测。 |
| 测试 | T18/T19/T20 的既有验收记录包含定向测试、完整 CI 和 Release build；T21 新增状态机 6、Environment 7、Bridge 14 项全部通过。最终 CI 为 362 total、361 passed、1 expected skipped、0 failures，Release build 成功。 | 实际 JS、真实设备新增生命周期路径与两个官方插件仍按后续任务验收。 |
| 回滚 | V1 持久化仍只含版本与启用状态；Runtime 运行态/token 不写盘。启停/重载状态提交失败保持旧执行，卸载失败按 Recovery 边界保留可恢复包；移除 Runtime factory 可关闭执行，退出先 stop Environment 再 shutdown Bridge。 | 新 Runtime 资源必须实现 teardown；实际 JSContext、异步任务和 Broker 资源释放要在后续阶段补充验证。发行回滚/DMG 发布也未包含于本阶段。 |

## 自动化与真实设备的验收边界

T21 使用 Swift 测试 Runtime 证明 Host 在禁用、暂停、停止、重载、卸载、异常及 App shutdown 时关闭执行资格，并清理 Activity 与 action handler。测试中的入口可以包含抛错 JavaScript 字节，代码仍没有 JSContext；因此结果证明静态快照与 Host 生命周期合约，不构成 JavaScript 的执行或异常隔离验收。

环境测试使用独立 NotificationCenter 和 FakeBatteryService，覆盖低电量滞回、AC 恢复、wake 后仍低电量、停止时迟到事件、旧睡眠不能覆盖较新唤醒和观察器幂等。实际 `NSWorkspace` 通知与 IOKit 已接入生产 App，但尚未记录新增生命周期路径的真实设备执行过程与数值。

后续可按以下场景保存设备证据：运行实际插件时合盖/唤醒；电池低于 20% 后 AC 插入；醒来但低电量仍在；禁用后保留旧 UI 点击或异步完成；卸载后重新发现；两个插件交错暂停/恢复且内置 Activity 正常。实际执行部分需等待 T22 Runtime 与对应 Bridge 完成。

## 最终验证记录

2026-10-09 最终 `./Scripts/ci.sh`：362 项测试，361 passed、1 项截图矩阵按设计 skipped、0 failures；T21 新增 27 项测试全部通过，Release build 成功。

- 结果包：`/tmp/dynamic-island-t21-final-ci/TestResults.xcresult`。
- 日志：`/tmp/dynamic-island-t21-final-ci.log`。
- Release App：`/tmp/dynamic-island-t21-ci-derived/Build/Products/Release/Dynamic Island.app`。

进度状态以 [PROGRESS](PROGRESS.md) 为准。以上是本机自动化与构建证据，未新增真实低电量、睡眠唤醒或实际 JS 插件的人工验收结论。

Phase 4 记录不关闭 Phase 0–2 中仍待资源、视觉或设备实测的独立任务，也不提前认可 Phase 5 的 JavaScript 执行、Phase 6 的权限/能耗/Watchdog 或 Phase 7 的安装管理界面与官方插件。
