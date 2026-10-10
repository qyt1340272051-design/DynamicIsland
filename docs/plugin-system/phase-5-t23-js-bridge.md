# Phase 5 — T23 JS Bridge 实现与验收

后续契约：T24 已扩展 Activity 可选字段、独立 update 与发布/更新限频，见 [T24 实现与验收](phase-5-t24-js-activity.md)。本文保留 T23 完成时的接口和验证记录。

日期：2026-10-09。范围：在 T22 的独立 JavaScriptCore Runtime 中建立 JavaScript 与 Swift Core 的受控通信层，形成「记录日志、发布简单 Activity、读写插件私有 KV」的最小闭环。完整 Activity 转换、IslandNode 转换、动作回传、持久化 Storage 和用户权限状态分别按 T24–T28 继续实现。

## Bridge 的责任与执行顺序

[`PluginJSBridge`](../../DynamicIsland/Plugins/PluginJSBridge.swift) 是 `island.log`、`island.activity`、`island.storage`、`island.actions` 请求 Host 能力的单一入口。每个插件仍拥有独立执行线程、VM 与 Context；JavaScript 参数、Promise 和回调引用留在该线程，跨线程只传经过限制的 JSON 字符串、数字请求 ID 和 Swift `Sendable` 数据。

隐藏的原生入口仅接收 JSON 请求与请求 ID。请求包含 `apiVersion`、`method`、`params`；Host 重新验证版本、方法、参数类型、字段、数值和容量，再进入 Core。JavaScript 包装层的验证用于尽早返回错误，Swift 验证仍是 Host 边界；插件不能借修改包装层省略 Host 校验。

同一 Runtime 的 [`PluginBridgeTransport`](../../DynamicIsland/Plugins/PluginBridgeTransport.swift) 按 FIFO 处理 Host 请求，因此连续发出的 `storage.set` 与 `storage.get` 按发出顺序执行。Host 使用该会话的 `PluginExecutionContext.perform` 检查当前 token，随后才调用 Activity、日志或 KV 服务；回复排队返回原插件线程，不通过 MainActor 同步等待 JavaScript。

禁用、暂停、停止、卸载、重载和启动失败会撤销会话。旧 Runtime 的排队请求不得写入新会话的数据或重新发布 Activity，撤销后的回复不得再次执行 JavaScript。T22 的 `onStop` 仍可在原线程清理 JavaScript 自有资源，但此时普通 Host Bridge 请求已无执行资格。

## V1 JavaScript API

`island.apiVersion`、各命名空间与每个方法的 `apiVersion` 均为 `"1.0.0"`。全局 `island`、插件元数据、各命名空间与方法受冻结和不可写绑定保护。命名空间只包含 Host 定义的数据与方法；它们不持有 Swift 对象、`FileManager`、`URLSession`、`NSWorkspace` 或文件句柄。Bootstrap 使用 strict 函数，阻止通过 `caller`、`arguments` 获取内部调用信息；原生入口的临时全局属性在注入包装层时删除，插件入口只能看到公开 `island` API。

所有方法返回 Promise。参数或 Host 拒绝通过 Promise rejection 返回，拒绝值为冻结、空原型的 `{code, message}` 数据对象，包含 Host 定义的固定字符串；它没有 `Error` 实例的 prototype、stack 或其他可执行属性。插件应使用 `error.code` 判断原因并捕获失败。生命周期函数仍沿用 T22：`onStart` 与 `onStop` 必须返回 `undefined`，不能声明为 `async` 并返回 Promise。

| 方法 | 输入与结果 | 本步边界 |
| --- | --- | --- |
| `island.log(message, level = "info")` | `message` 为字符串；`level` 为 `debug`、`info`、`warning`、`error`；成功返回 `null`。 | 记录带插件 ID 的有限日志。 |
| `island.activity.publish(payload)` | `payload` 只包含本地 `id` 与 `presentation`；成功返回 `{id}`，其中 `id` 为插件传入的本地 ID。 | 仅简单摘要，Host 决定 source、实际 ID、优先级与生命周期。 |
| `island.activity.end(id)` | 接收本地 Activity ID；成功返回 `null`。 | 只结束当前插件的 Activity。 |
| `island.storage.get(key)` | 读取当前插件命名空间中的 JSON 值；key 不存在时返回 `null`。 | Host 进程内 KV，T27 再增加持久化。 |
| `island.storage.set(key, value)` | 写入受限 JSON 值；成功返回 `null`。 | 不提供文件路径或其他插件命名空间参数。 |
| `island.storage.remove(key)` | 删除当前插件的 key；成功返回 `null`，不存在时幂等成功。 | 不修改其他插件的数据。 |
| `island.storage.clear()` | 清空当前插件的 KV，成功返回 `null`。 | 不提供全局清空能力。 |
| `island.actions.on(actionID, handler)` | 校验动作 ID 和函数形状；声明 `actions.handle` capability 后拒绝 `unsupportedMethod`。 | T26 才建立动作路由；不保留或传送 handler。 |
| `island.actions.off(actionID)` | 校验动作 ID；声明 `actions.handle` capability 后拒绝 `unsupportedMethod`。 | `island.actions.supported === false` 明示当前能力。 |

一个 classic JavaScript 入口可以这样启动最小闭环：

```javascript
globalThis.onStart = function () {
  // 生命周期函数返回 undefined；异步 Host 请求由 Promise 链处理。
  void island.storage.set("lastTitle", "插件已启动")
    .then(() => island.storage.get("lastTitle"))
    .then(title => island.activity.publish({
      id: "welcome",
      presentation: {title, symbolName: "checkmark.circle"}
    }))
    .then(() => island.log("已发布 welcome", "info"))
    .catch(error => {
      void island.log("Bridge 请求失败", "warning").catch(() => {});
    });
};
```

需要结束 Activity 时使用 `island.activity.end("welcome")` 并处理其 Promise。T23 没有 Host 定时器、网络 API 或动作 callback，示例不依赖这些后续能力。

## 简单 Activity 契约

```javascript
{
  id: "build",
  presentation: {
    title: "正在构建",
    subtitle: "编译中",               // 可选字符串
    symbolName: "hammer",             // 可选 SF Symbol 名称
    progress: 0.4                     // 可选有限数值，0...1
  }
}
```

Bridge 拒绝未知字段以及类型错误，不接受插件指定 `source`、Host ID、`priority`、`lifecycle`、创建时间、过期时间、actions 或 IslandNode Tree。本地 `id` 非空、最多 80 UTF-8 bytes，仅接受 ASCII 字母、数字、`.`、`_`、`-`；`title` 最多 256 UTF-8 bytes，不能为空或只有空白；可选 `subtitle` 最多 256 UTF-8 bytes；可选 `symbolName` 非空、最多 128 UTF-8 bytes，接受与本地 ID 相同的字符以及 `:`。`progress` 不接受 `NaN`、Infinity 或范围外值，可选字段存在时不能用 `null` 代替指定类型。

Host 使用当前 `PluginExecutionContext.source`，实际 Activity ID 加上 `plugin:<plugin ID>:<local ID>` namespace；优先级固定 `normal`，生命周期固定 `transient`，创建时间来自 Host。同一插件重复发布相同本地 ID 走已有 Activity 更新语义；不同插件相同本地 ID 不互相覆盖。每个插件本步最多保留 16 个 Activity ID，现有 Core 队列还可能提前淘汰 Activity；完整发布/更新频率策略和更丰富的转换按 T24 实现。

`activity.publish` 要求 Manifest 声明 `activity.publish` capability，`activity.end` 要求 `activity.end` capability。T23 不将 `notifications.publish` 自动视为 Activity 发布授权，也不接受插件伪造 built-in source。

## 私有 KV、日志与声明门禁

KV 由 Host 保存，按可信 Manifest plugin ID 划分命名空间；Runtime 不能提交另一个 plugin ID。数据在同一 Host 进程内跨 Runtime 重启、暂停恢复或重载保留，不写入磁盘。T27 继续确定持久化格式、卸载清理、迁移和数据恢复；本步不承诺 App 退出后数据仍在。

`storage.get` 返回 JSON 数据的独立副本，对象和数组均使用空原型，避免 Promise resolve 读取继承的 `then` getter。数组仍满足 `Array.isArray(value) === true`，可按索引读取并用 `JSON.stringify` 序列化；它不继承 `map` 等 Array prototype 方法。修改读出的对象不会改变 Host 已存数据；需要修改后再次 `set`。

每次 KV 调用要求 Manifest 同时声明 `storage.local` capability 与 `storage.local` permission。T23 只检查声明与执行会话；用户 grant/deny/revoke 状态仍由 T28 PermissionManager 建立，不能把此声明检查作为完整授权验收。普通 KV 不提供 Keychain 或 secret storage，插件不应把 Token/API Key 当作普通 KV 的默认用途。

日志按插件 ID 保存有限记录，并在同一 Host 进程内跨 Runtime 保留，由 Host 选择输出级别和隐私标记。输入必须是原始字符串，Bridge 不调用任意对象的 `toString` 来格式化日志，也不记录入口源码或完整 Bridge payload。日志环最多保留每插件 100 项，避免插件无限增长 Host 的诊断数据；卸载清理策略按 T27 明确。

`actions.on` 仅在 JavaScript 包装层检查 `handler` 是函数，函数不被保留，也不跨原生边界。`on/off` 的 Host 请求仅含 `actionID`，其字符与 80-byte 长度限制同 Activity 本地 ID。非法形状或字符先返回 `invalidArguments`，长度超限返回 `quotaExceeded`；合法参数但未声明 `actions.handle` 时返回 `capabilityRequired`，声明后返回 `unsupportedMethod`，本步不注册 handler。

## 输入与容量限制

| 边界 | 限制 |
| --- | --- |
| 单次请求 JSON | 16 KiB；每 Runtime 最多 64 个未完成请求。 |
| JavaScript 请求快照 | params 最大深度 10、最大节点数 512，单字符串及对象字段名最多 4 KiB；拒绝非 JSON 值、循环与 accessor。 |
| Host 请求 JSON 结构 | 最大深度 12、最大节点数 512；拒绝所有层级的重复字段、非法 JSON 和非有限数字。 |
| 单条日志 | 最大 1,024 UTF-8 bytes，级别仅四种；每插件日志环 100 项。 |
| 简单 Activity | 每插件最多 16 个本地 ID；ID 80 bytes、title/subtitle 256 bytes、symbolName 128 bytes，字段规则见上节。 |
| Storage key | 非空且不能只有空白、最大 128 UTF-8 bytes，无控制字符；每插件最多 128 个 key。 |
| Storage value | 最大 8 KiB，最大深度 8、最大节点数 256，单字符串最大 4 KiB。 |
| 插件 KV 总容量 | key 的 UTF-8 bytes 加各 value 编码 JSON bytes 合计最多 64 KiB；容量超限不提交部分写入。 |

[`PluginJSBridgeBootstrap`](../../DynamicIsland/Plugins/PluginJSBridgeBootstrap.swift) 使用捕获的内建能力，不依赖插件后续覆盖的 `JSON`、`Object` 或 `Promise` 属性。它通过 own property descriptor 复制纯数据，不读取 `value[key]`，拒绝 getter/setter、function、symbol、BigInt、undefined、非有限数字、循环、稀疏数组和非普通对象；动作 handler 是只用于类型检查的单独参数例外。每个输入属性 descriptor 只取一次，其 data value 随后用于复制，避免 Proxy 在重复读取时替换 descriptor。

请求快照递归禁止对象字段名 `toJSON`，防止序列化重新进入插件方法；Swift 对 Storage value 递归执行相同禁止规则。KV key 字符串 `"toJSON"` 本身仍可使用，例如 `storage.set("toJSON", 1)`；不能将它作为 value 内部的对象字段。[`PluginBridgeJSON`](../../DynamicIsland/Plugins/PluginBridgeJSON.swift) 独立拒绝所有层级的重复 JSON 字段与结构超限。

JSON 序列化不等于 Host 参数校验。拒绝 accessor 无需调用其 getter，但 Proxy 的 `ownKeys`、`getPrototypeOf`、`getOwnPropertyDescriptor` trap 仍可能在插件线程执行；本步不能强制中断无限循环，也不能隔离同进程内存耗尽。T31/T32 的调度与 Watchdog 仍待实现。

## 自动化验收与证据

[`PluginJSBridgeTests`](../../DynamicIslandTests/PluginJSBridgeTests.swift) 的 23 项测试与完整 CI 覆盖以下场景：

- 实际 JavaScript 经 Bridge 记录日志、读写 KV，并在真实 ActivityManager 中发布与结束简单 Activity；同一个 `NSHostingView` 连接正式 IslandRenderer，发布和结束后渲染 PNG 数据发生变化，Activity 当前摘要对应 JS 输入。
- 两个独立 Runtime 使用相同 Activity 本地 ID 和 KV key，source、实际 Activity ID、日志与存储数据均按插件隔离；同一插件创建新 Runtime 时读取进程内数据。
- 验证 API 与方法版本、只读全局绑定、冻结命名空间/方法、原生服务对象不可见；覆盖插件修改内建全局及 `Object.prototype.toJSON/then` 后的 Bridge 行为，不调用恶意 getter。
- 缺少 capability 或 Storage permission、错误类型、未知字段、伪造 source、非法数值、深度/节点/字节超限、KV 容量与日志/Activity 上限均返回明确失败并且没有部分副作用。
- 连续 `set/get` 按 FIFO 返回；未完成请求上限有效；两个插件的请求与异常不互相阻塞。
- 禁用与替换会话测试验证旧 context、排队请求及迟到回复不能修改新会话；T22 的暂停、恢复、重载和卸载测试继续验证统一 teardown 与会话撤销路径，实际系统设备行为由对应阶段单独验收。
- `actions.on/off` 验证输入与 capability 并返回对应失败，声明 capability 的合法请求返回 `unsupportedMethod`；本步没有注册 ActionRouter handler，T26 状态保持待办。
- 完整回归测试和 Release 构建通过；新增 API 不改变内置音乐、音量、电池 Provider 的 Host 入口。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| Bridge 定向测试（历史中间版本） | 22 passed / 0 failures；随后增加 Proxy descriptor 快照测试，完整 CI 包含当前 23 项。 | `/tmp/dynamic-island-t23-bridge-tests-final/TestResults.xcresult`；恶意 inherited getter 强化单项通过：`/tmp/dynamic-island-t23-bridge-tests-intrinsics/TestResults.xcresult`。 |
| 完整 `./Scripts/ci.sh` | 415 total / 414 passed / 1 expected screenshot skipped / 0 failures；Release build passed。包含当前 23 项 Bridge 测试、29 项 T22 Runtime 测试与生产 factory 测试。 | `/tmp/dynamic-island-t23-verified-ci/TestResults.xcresult`、`/tmp/dynamic-island-t23-verified-ci.log`。 |
| Release Runtime + Bridge + 生产入口执行 | 53 passed / 0 skipped / 0 failures，包含 23 项 Bridge、29 项 Runtime 和 1 项生产 factory 测试；实际 JavaScriptCore 与 Renderer 回归通过。 | `/tmp/dynamic-island-t23-release-verified/TestResults.xcresult`、`/tmp/dynamic-island-t23-release-verified.log`。 |
| 普通 Release App 签名 | `codesign --verify --deep --strict` 通过；Hardened Runtime `flags=0x10002(adhoc,runtime)`，App Sandbox 与 allow-jit 均为 true，无测试专用 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t23-ci-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t23-release-entitlements.plist`。 |

Release 验证沿用 T22 的独立临时测试宿主流程：在 `/tmp/dynamic-island-t23-release-derived` 以 Release 优化、`ENABLE_TESTABILITY=YES`、`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES` 构建 XCTest；仅重签该临时测试宿主，保留 Hardened Runtime、Sandbox、allow-jit 并加入加载 ad hoc XCTest bundle 所需的测试专用 `disable-library-validation`，再运行 `xcodebuild test-without-building`。项目权利与普通 Release App 保持正式测试例外之外的配置；不构成 Developer ID、公证或发行验收。

最终 Debug 与 Release 自动化结果满足 T23 原文「JS 可发布简单 Activity、记录日志和读写插件私有存储」的完成标准，进度表已标记 `verified`。以上 NSHostingView 验证是自动化渲染回归，不能替代真实刘海设备上的视觉验收。T24–T28 的完成状态各自按计划继续验收。
