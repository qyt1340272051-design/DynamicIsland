# Phase 5 — T27 Plugin Storage

后续 T28 已将每次 JS 存储调用接入 Host grant / revoke 检查，见 [权限记录](phase-6-t28-permission-manager.md)。下文保留 T27 完成时的声明检查边界。

日期：2026-10-10。依赖 T23 已验收。提供按 Host 验证的插件 ID 隔离的 KV，生产持久化，测试可明确注入内存模式。

## API 与隔离

```javascript
await island.storage.set('settings', {enabled: true, progress: 0.5});
const settings = await island.storage.get('settings');
await island.storage.remove('settings');
await island.storage.clear();
```

方法、Promise 返回值和 API version `1.0.0` 沿用 T23；缺失 key 返回 null，remove / clear 幂等。namespace 来自当前 PluginExecutionContext，JS 无 pluginID、文件路径或全局清空参数。相同 key 可由两个插件独立读写。存储要求 Manifest 同时声明 `storage.local` capability 和 permission；用户授权状态由 T28 接续。

生产组合根注入 [`PluginStorage.applicationSupport()`](../../DynamicIsland/Plugins/PluginStorage.swift)，Foundation 在当前 Sandbox 内解析 Application Support/DynamicIsland/Plugins/Storage，每插件独立 `<pluginID>.json`，包含 schemaVersion 1、pluginID、values。配置失败返回固定错误，不退回内存。重载、卸载和禁用保留数据；只有该插件明确 clear 才清空 namespace，卸载清理选择在后续管理 UI 扩展。

沿用 T23 限制：128 个 key；key 最多 128 UTF-8 bytes，非空白且无控制字符；namespace 按 key UTF-8 bytes 加 value 编码 JSON bytes 合计最多 64 KiB；每 value 最多 8 KiB、深度 8、256 节点、单字符串 4096 UTF-8 bytes。value 对象字段 `toJSON` 被拒绝，KV key `toJSON` 本身允许。

## 文件与并发

[`PluginStorage`](../../DynamicIsland/Plugins/PluginStorage.swift) actor 串行拥有 KV 和同步文件 I/O，位于 MainActor 之外。Bridge 在 MainActor 校验纯数据、声明和会话；Transport 按会话 FIFO await actor 完成后处理下一条请求，不阻塞 VM 或 UI。请求进入 MainActor 后再次检查 transport 撤销，过滤 direct teardown 后已出队但尚未执行的请求。

每次读取重新检查磁盘，拒绝坏 UTF-8、重复 JSON 字段、未知 schema / 字段、身份不匹配、超限值和损坏结构，不把坏文件视为空数据。文件最多 128 KiB，解析 envelope 后逐值验证。损坏文件的 set / remove / clear 同样失败，不隐式修复或覆盖。JS 只收到固定 `storageReadFailed` / `storageWriteFailed`，无路径或内容。

Storage 目录 0700，文件 0600。受控 root / Storage / 文件检查 owner、类型和权限，拒绝 symlink、hardlink 和非当前用户；openat / fstatat / renameat 绑定已检查的目录 descriptor。写入临时唯一文件，完整写入、fsync 并重新检查后原子 rename；提交前失败保留原文件并清理临时文件。

每次 Runtime 启动创建独立 PluginStorageAdmission。生命周期结束先撤销 admission，Transport 的直接 teardown / worker failure 同样同步撤销。I/O 准备在锁外，最终 rename 与撤销共用锁：撤销先发生则不能提交；提交先发生则数据保留，但停止后旧回复不交给新 VM。Bridge await 后再次检查执行 token。

当前生产 Host 共享一个 actor。两个独立 actor / 进程同时修改同一 namespace 的合并更新不受保证；可信配置的祖先目录遵循系统路径解析；fsync 文件不等于断电后目录项持久性保证。普通 KV 是明文 JSON，secret / Token 应走未来 Keychain Broker。

## 验证

首轮定向：52 passed、0 failures，含存储 15、Bridge 23、Lifecycle 14；`/tmp/dynamic-island-t27-targeted/TestResults.xcresult`。

[`PluginStorageTests`](../../DynamicIslandTests/PluginStorageTests.swift) 最终 17 项，覆盖真实 JS 跨 Store / Bridge / VM 重启、未 await 请求 FIFO、跨插件相同 key、UTF-8 / 容量边界、损坏文件、目录与文件拒绝规则、原子失败保留旧 bytes、后台 I/O 与撤销，以及真实 Lifecycle 禁用 / 重启、直接 teardown 阻断准备中的写入和固定 Bridge 错误。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 488 项：486 passed、2 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t27-final-ci-v2/TestResults.xcresult`、对应 `.log`。 |
| Release 定向 | Storage 17、Bridge 23、Action 18、Activity 18、Node 20、Runtime 29，共 125 项：124 passed、1 skipped、0 failures。 | `/tmp/dynamic-island-t27-release-tests/TestResults.xcresult`、对应 `.log`。 |
| Release 生产 factory | 1 passed、0 failures；两次 Release 定向合计 125 passed、1 skipped。 | `/tmp/dynamic-island-t27-release-factory/TestResults.xcresult`。 |
| 普通 Release 签名 | strict / deep 核验通过；adhoc + runtime；Sandbox / allow-jit 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t27-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t27-release-entitlements.plist`。 |

本机 arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。CI skip 包含原截图矩阵及真实鼠标控件单项：CGSession 明确显示当前 macOS 锁屏，窗口不能成为 key window，AppKit 事件无法交付。此前未识别环境的失败记录保留于 `/tmp/dynamic-island-t27-final-ci/TestResults.xcresult` 和 `/tmp/dynamic-island-t27-action-input/TestResults.xcresult`。测试仅在检测到锁屏时跳过，解锁自动执行原闭环；T26 已取得解锁时 CI / Release 的真实控件成功证据。本次不能新增解锁设备验收结论。

Release XCTest 仅对临时 `/tmp/dynamic-island-t27-release-derived` 的测试 Host 注入测试 entitlement 并允许库验证例外；普通 Release App 和项目生产 entitlement 无该例外。
