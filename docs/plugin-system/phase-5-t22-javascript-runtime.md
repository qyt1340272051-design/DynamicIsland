# Phase 5 — T22 JavaScriptCore Runtime 实现与验收

日期：2026-10-09。范围：为每个已验证插件建立独立的 JavaScriptCore 执行环境，将实际 JavaScript 启停接入 T21 生命周期，并注入 V1 最小 `island` 对象。入口仍来自 T19 的不可变 `ValidatedPluginPackage.entrySource`；Runtime 不重新读取入口文件。

本记录保留 T22 完成时的最小元数据接口及验收证据。T23 随后加入日志、简单 Activity、私有内存 KV 和受控 Promise 通信，当前 API 见 [T23 JS Bridge 记录](phase-5-t23-js-bridge.md)。

## Runtime 与 Host 的责任

[`PluginRuntime`](../../DynamicIsland/Plugins/PluginRuntime.swift) 实现 T21 的 `PluginLifecycleRuntime`。每个 Runtime 独立拥有专用线程、该线程的 CFRunLoop、一个 `JSVirtualMachine` 和一个 `JSContext`，所有 JS 操作都留在该执行线程。不同插件不复用 VM、Context、全局对象或 JSValue；同一插件暂停后恢复、重新启用或重载时也创建新 Runtime。

Host facade 留在 `MainActor`，延续 `onStart(context:)`、`onStop(reason:)`、`teardown()` 的同步 Swift 协议；调用只登记或撤销工作，不等待插件 JavaScript 返回。入口求值和生命周期调用在插件线程排队，结果异步回到 Host。一个插件抛出 JS 异常时，Host 结束该执行会话，其他插件的登记和运行状态继续独立维护。

生产 [`IslandActivityRuntime`](../../DynamicIsland/Core/Activity/IslandActivityRuntime.swift) 为 Bridge 提供真正的 Runtime factory。T21 文档中的 factory 为空及仅 Swift 测试 Runtime 是该阶段完成时的历史状态；实际 JS factory 从 T22 开始接入。

## V1 入口与最小 island 对象

Manifest V1 的 `entry` 指向一个 classic JavaScript `.js` 文件。入口可以声明两个可选全局函数：

```javascript
globalThis.onStart = function () {
  // 每次新的执行会话调用一次。
  globalThis.startedPluginID = island.plugin.id;
};

globalThis.onStop = function (reason) {
  // reason 是 Host 的停止原因字符串。
  delete globalThis.startedPluginID;
};
```

`onStart` 不接收 Swift 对象；`onStop` 只接收 `disabled`、`unloaded`、`suspended`、`stopped`、`startFailed` 或 `shutdown`。函数缺失时可继续执行；存在时必须可调用，并且返回值必须是 `undefined`。返回 Promise 的 `async` 函数和其他返回值会使该次生命周期调用失败。Host 不等待 Promise，也不读取其 `then` 属性。

T22 在入口执行前注入以下纯 JavaScript 数据：

```javascript
island.apiVersion;       // "1.0.0"
island.plugin.id;        // Manifest 中的插件 ID
island.plugin.name;      // Manifest 中的展示名称
island.plugin.version;   // Manifest 中的完整语义化版本字符串
```

`island` 与 `island.plugin` 使用空原型并冻结；全局 `island` 属性不可写、不可重新配置。它们不持有 Swift Runtime、ExecutionContext、Manager、文件句柄或系统服务引用。

`require`、CommonJS `module`/`exports`、ES module import、npm loader、浏览器 DOM 和 Host 定时器均没有由本阶段提供。`island.log`、`island.activity`、`island.storage`、`island.actions` 按 T23 建立受控 Bridge。插件的权限声明继续由 Manifest 保存，授权与 Broker 按 T28–T30 实现。

## 会话准入与异步结果

Bridge 的六状态机仍描述 Host 准入：`running` 表示会话已取得执行资格，入口 JavaScript 可能还在队列中或正在初始化。Runtime 只有在入口求值、生命周期形状校验和 `onStart` 都成功后才就绪；UI 和诊断不能仅凭 Bridge 的 `running` 声称 JS 已完成启动。

每次启动保留 T21 的独立 `PluginExecutionContext` 和会话 token。启动错误通过该 context 回报；Host 在接收时再次核对当前会话。禁用、暂停、停止、重载或卸载会撤销 token，因此旧 Runtime 的迟到启动失败、停止结果和普通排队工作不能停止新 Runtime，或重新取得新会话执行资格。

停止先在 MainActor 关闭执行准入并清理该插件 Activity 与动作，再排队 `onStop` 与 JS 资源清理。`teardown()` 幂等并立即撤销普通工作；它不在 MainActor 等待 `onStop`。执行线程最终清除 JS 回调引用、异常 handler 和 Context/VM，并结束自己的 run loop。停止失败不阻止清理，单个插件的失败也不传播到另一个插件的线程或 Context。

## 异常与资源边界

Runtime 在入口求值和回调阶段设置异常 handler，保存 Host 定义的失败阶段。诊断不把插件 JSValue 传到 MainActor，不读取插件自定义 `stack`、`then` 或 `toString`，避免在格式化错误时再调用插件代码。诊断也不输出入口源码或完整插件数据。

Promise 微任务可能在 JavaScriptCore 的求值或函数调用返回前执行，同样会占用该插件线程。`exceptionHandler` 处理这些 Host API 的未捕获异常，但公开 API 不保证把未处理 Promise rejection 交给它；本阶段不提供异步生命周期或未处理 rejection 观察器。参见 [Apple 的异常 handler 文档](https://developer.apple.com/documentation/javascriptcore/jscontext/exceptionhandler) 与 [WebKit 的微任务执行实现](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSLock.cpp)。

`JSContext` 是同进程解释器与 JIT 引擎，不构成完整安全沙箱。专用线程使普通 JavaScript 求值不占用主线程，并提供每插件对象空间隔离；已经进入执行中的同步 JavaScript不能被 `teardown()` 强制中断。无限循环、内存耗尽及同进程引擎故障仍需 T31 调度与 T32 Watchdog 的资源策略，T22 的异常处理不能作为这些风险的验收结论。

本阶段未暴露 `FileManager`、`URLSession`、`NSWorkspace`、Objective-C 对象导出或任意系统能力；后续敏感操作必须经过参数验证、会话门禁和受控 Broker。

## Hardened Runtime 与 Release 执行

App 继续启用 App Sandbox 和 Hardened Runtime；[`DynamicIsland.entitlements`](../../DynamicIsland/DynamicIsland.entitlements) 添加 `com.apple.security.cs.allow-jit = true`，允许 JavaScriptCore 使用 `MAP_JIT`。Apple 说明其 fast path 使用该能力，缺少权利时依赖 JIT 的框架可能退回解释器。该权利不等于插件权限，也不能替代 Host Bridge 的授权检查。见 [Apple 的 JIT 权利说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit)。

Runtime 的线程设计依据 JavaScriptCore SDK 中 `JSVirtualMachine` 的契约：VM 的延后任务使用初始化线程的 run loop，创建后不能重新指定。参见 [Apple 的 JSVirtualMachine 文档](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine)。

默认 CI 运行 Debug XCTest，随后构建 Release App；Release 构建本身无法证明签名后的 JS 执行。T22 验收还应运行 Release 配置的 Runtime 定向测试，并检查产物实际签名权利。

## 自动化验收

[`PluginRuntimeTests`](../../DynamicIslandTests/PluginRuntimeTests.swift) 的 29 项真实 JavaScript 测试与 [`IslandActivityRuntimeTests`](../../DynamicIslandTests/IslandActivityRuntimeTests.swift) 的 1 项生产 factory 测试已覆盖以下行为：

- Plugin A 和 Plugin B 的全局变量、VM/Context 以及入口/启动异常互相隔离。
- 可选生命周期函数、非函数导出、不允许的返回值与启动/停止异常。
- 使用 Validator 的不可变入口快照，修改磁盘入口不会改变已登记 Runtime 输入。
- Manager 启用、禁用、重新启用、暂停恢复和卸载接入实际 JS Runtime；旧会话异步结果不会影响新会话。
- `teardown` 幂等，待执行普通任务失效，执行线程在有限 JS 回调结束后释放 Context、VM 与 Runtime 资源。
- Host 对象和敏感能力不可见，`island` 元数据与全局绑定受保护。
- Release 配置实际运行 JavaScript，实际 App 签名包含 JIT 权利。

验证环境：arm64 MacBook Air，macOS 26.6.2（25G83），Xcode macOS 26.5 SDK。结果：

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 `./Scripts/ci.sh` | 392 total / 391 passed / 1 expected screenshot skipped / 0 failures；Release build passed。 | `/tmp/dynamic-island-t22-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t22-final-ci.log` |
| Release Runtime + 生产 factory 定向执行 | 30 passed / 0 skipped / 0 failures；实际执行 JavaScriptCore。 | `/tmp/dynamic-island-t22-release-verified/TestResults.xcresult`、`/tmp/dynamic-island-t22-release-verified.log` |
| 普通 Release App 签名检查 | `codesign --verify --deep --strict` 通过；`flags=0x10002(adhoc,runtime)`；App Sandbox 和 allow-jit 均为 true，无 get-task-allow 和 disable-library-validation。 | `/tmp/dynamic-island-t22-ci-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t22-release-entitlements.plist` |

Release 定向测试使用独立 `/tmp/dynamic-island-t22-release-derived`，保留 Release 优化，并为 XCTest 临时启用 `ENABLE_TESTABILITY=YES` 和 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES`。直接 Release 测试首先遇到缺少 `-enable-testing`，随后遇到 ad hoc XCTest bundle 的 Team ID 库加载校验。最终仅对该临时测试宿主重新签名，保留 `--options runtime`、App Sandbox、allow-jit，并加入测试专用 `disable-library-validation` 后运行 `xcodebuild test-without-building`；30 项全部通过。项目权利文件与上表普通 Release App 都没有该测试例外。这证明 Release 优化代码及启用 Hardened Runtime 的测试宿主能执行 JS；不构成 Developer ID、公证或 DMG 发布验收。

T22 满足计划中「插件 A 的异常与全局变量不会影响插件 B」的完成标准，已将 [PROGRESS](PROGRESS.md) 的 T22 标为 `verified`。T23 继续建立日志、Activity、Storage 和 Actions 的受控 Bridge；本步没有提前关闭 Scheduler、Watchdog、权限或官方插件任务。
