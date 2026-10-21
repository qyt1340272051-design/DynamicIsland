# Phase 6 — T30 File/Clipboard Broker

日期：2026-10-12。依赖 T28 已验收；本任务完成并验证。

## API 与显式授权

```javascript
const selected = await island.files.chooseText();
if (selected !== null) {
    await island.log(selected.name);
    // selected: {name, type, text, size}; no URL or filesystem path.
}
const text = await island.clipboard.readText();
await island.clipboard.writeText('Shared text');
```

`files.userSelected`、`clipboard.read`、`clipboard.write` 独立检查，每次调用使用绑定插件 ID 和权限的 lease。Manifest 声明与插件启用不会自动授权；批准界面仍按 T33 实现。

`chooseText()` 不接受参数；Host 独立拒绝 path、URL、过滤器和未知字段。NSOpenPanel 显示请求插件的名称和共享文本说明，一次只选一个文件；用户取消返回 null。JS 只取得文件名、MIME 类型、UTF-8 文本与字节数，不取得路径、原生对象、资源句柄或 bookmark。

V1 类型为 txt / text / md / markdown / json / csv，最多 64 KiB。文件描述符检查普通文件、最终组件 no-follow、打开前后 inode / device、读取大小和修改时间；拒绝目录、符号链接、特殊文件、超限、不合法 UTF-8 和 NUL 数据。读取发生在后台，保持全局一个选择 / 读取的上限。文件选择期间，同一 VM 的 Activity、storage 和动作请求仍可处理。

每个执行会话持有 ResourceAdmission。停止或直接 teardown 同步关闭准入，取消选择器；权限撤销同样取消，晚选择结果与文件读取结果不能重新取得交付资格。已经开始的有界读取在返回前保留配额，避免反复取消创建无限后台任务。

Host 通过系统文件选择流程获得 Sandbox 用户选择权限；已有 App 的 user-selected.read-write entitlement 支持内置文件托盘，插件 API 本身仅提供文本读取。平衡主动获取的 security scope，不保存 bookmark。Apple 说明系统会为 open panel URL 自动开始安全作用域访问，主动 start 返回 false 本身不代表读取失败：[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

剪贴板只读取 `.string` 数据，不读取图像、富文本、文件列表或 URL 表示；文件 URL 与多 item 内容拒绝。普通复制的文本可同时带 HTML / RTF 表示，但本 API 只读取明确的字符串表示。最多 4096 UTF-8 bytes，先检查原始数据大小再解码。写入先验证文本与授权，再改变剪贴板；未授权或超限写入不会清空原内容。没有自动读取、轮询或后台监视。

两侧 API 与结果冻结，JS file 响应单独允许 64 KiB 文本 / 512 KiB wire；storage 与 clipboard 保持原 4 KiB 单字符串限制。固定错误不含文件路径或剪贴板内容，Broker 不记录这些数据。

## 验证

[`PluginUserResourceBrokerTests`](../../DynamicIslandTests/PluginUserResourceBrokerTests.swift) 共 17 项，覆盖路径 / 原生句柄输入拒绝、类型 / 大小 / UTF-8 / NUL / 符号链接、绑定权限与插件 ID、选择器取消及全局配额、读写分权和撤销 / 再批准。真实 JavaScript 验证冻结 API / 6 KiB 文件 DTO / 私有剪贴板闭环、选择器等待时 Core 请求仍完成，以及未批准 / 拒绝 / 撤销后的明确错误。系统选择器使用可取消的 Host 注入 fixture，剪贴板测试使用独立命名的私有 NSPasteboard；不修改用户真实剪贴板。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 534 total、533 passed、1 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t30-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t30-final-ci.log`。 |
| Release 定向 | Resource 17、Network 12、Permission 17、Runtime 29、Bridge 23、Lifecycle 14 = 112 passed；生产 factory 另 1 passed；无 skip / failure。 | `/tmp/dynamic-island-t30-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t30-release-factory/TestResults.xcresult`。 |
| 普通 Release 签名 | strict / deep 核验通过；Sandbox / allow-jit / network.client 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t30-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t30-release-entitlements.plist`。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。唯一 CI skip 是原截图生成条件项，本次真实鼠标控件回归通过。Release 测试注入与 library-validation 例外只用于临时测试 Host，普通 App 无该例外。

T30 按完成标准 verified：Host 独立拒绝任何 JS 路径参数，只有用户选择流程的 URL 进入有界文件读取；读写权限和生命周期不能被 wrapper、错误 owner 或晚回调绕过。尚未进行真实 NSOpenPanel 用户交互与系统剪贴板手动验收；T33 批准 UI、0.6.0 发布仍是后续工作。
