# Phase 4 — T19 PluginValidator 验证记录

日期：2026-09-30。范围：在任何第三方代码进入 Runtime 前，对已经展开的插件目录完成静态、只读、失败即拒绝的验证。

## 输入边界

T19 接受 Host 所有、受控 `allowedContainerURL` 下的一个已展开目录。包根必须是真实目录并且是允许容器的严格后代；容器外路径、包根 symlink、普通文件和不存在路径都会拒绝。Validator 不接收压缩包，也不负责把不可信归档展开到磁盘。

包根只接受精确小写的根级 `manifest.json`。大小写不同的文件名、子目录内的 Manifest 或额外 wrapper 目录不能替代它。Manifest 字节必须经过 `PluginManifest.decodeJSON(_:)`，沿用 T18 的 64 KiB 输入上限、V1 字段闭集、严格 ID/entry 规则、权限和 capability 闭集及 SemVer 解析。

## 目录与资源验证

Validator 完整遍历包内目录树，包括隐藏文件、隐藏目录以及 `.app` 等 package 目录的后代；这些内容都计入资源配额。遍历采用精确相对路径，不通过大小写不敏感查找补齐文件。

每个目录项只允许普通文件或目录，并执行以下门禁：

- 拒绝内部、外部、断开的 symbolic link，以及路径中间组件为 symbolic link 的入口。
- 拒绝 hard link，避免同一 inode 绕过逐文件与总量边界。
- 拒绝 FIFO、socket、block/character device 等特殊文件，防止读取阻塞或访问包外资源。
- 拒绝与包根不同设备的后代，避免挂载点跨出受控文件系统边界。
- 对目录项数量、普通文件数量、目录深度、相对路径长度、单文件大小和包总大小设置上限。
- 文件和总包配额使用 `lstat` 的 logical size；稀疏文件不能用较小的实际磁盘占用绕过限制。求和必须检查整数溢出。

目录清单建立后，Manifest 与入口文件通过 no-follow 文件描述符重新读取，并核对设备、inode、类型、link count、大小与修改身份。验证期间发生替换或变化时失败关闭。验证结果属于一个时间点的快照，因此调用方必须始终在 Host 独占、不可被插件作者并发写入的 staging 或安装目录中调用它；T20/T34 创建这些目录时须使用当前用户所有且仅当前用户可写的权限。

## Manifest、兼容性与入口

目录边界通过后，Validator 按以下顺序完成静态契约检查：

1. 读取并严格解析根级 `manifest.json`。
2. 用调用方注入的当前 Host `SemanticVersion` 比较 `minimumHostVersion`；SemVer prerelease 按规范排序，build metadata 不影响优先级。
3. 用调用方注入的已占用 ID 快照拒绝重复 `manifest.id`。
4. 按 Manifest 中的精确相对路径查找入口，并要求它是清单中的普通、单链接文件。
5. 从已经安全打开的入口文件返回不可变 `entrySource` 字节及已验证 Manifest、规范包根和统计信息。

T19 不创建 `JSContext`，不解析或执行 `index.js`，也不会在验证结束后按 URL 重新打开入口。后续 Runtime 必须消费 Validator 返回的 immutable `entrySource`，避免入口在验证与执行之间被替换。

## 与 T20、T34 的责任边界

- T20 `PluginManager` 可以使用 T19 的已占用 ID 快照提前报告冲突；在真正登记、启用或安装提交时仍须在同一原子临界区重新检查并预留 ID，防止两个并发请求同时通过快照验证。
- T34 `.dip Installer` 负责归档输入边界：流式解压到 Host 所有的临时目录，在写入前拒绝 absolute path、`..`、symlink/hardlink 和特殊项，并同步限制压缩条目数量、单项大小与累计展开大小，避免 path traversal 和 zip bomb 已经消耗磁盘后才调用 Validator。
- T34 在解压完成后调用同一 T19 Validator，展示权限预览，并通过同卷原子移动提交安装；提交前重新确认包根身份和目标 ID。

这条分工使 T19 可以复用于本地 staging、已安装目录复检和 T34 导入流程，同时把压缩格式特有的风险留在最早能够阻止写盘的位置。

## 错误契约

拒绝结果提供稳定 `code`、包内相对 `path` 和非空说明，覆盖非法包根、容器越界、Manifest 缺失或非法、Host 版本过低、重复 ID、入口缺失或类型错误、symlink/hardlink/特殊文件/跨设备条目、路径与资源配额超限、读取失败以及验证期间文件变化。错误不能泄漏 symlink 指向的包外绝对路径。若同一包同时包含多项错误，Validator 返回遍历中首先发现的一项；文件系统枚举顺序不属于对外契约。

## 验证

- `PluginValidatorTests`：14 项定向测试通过，0 failures；覆盖合法嵌套包、strict local file URL、容器 realpath、中间/最终 symlink、hardlink、FIFO、资源边界、重复 ID、SemVer 和不可变入口快照。
- `./Scripts/ci.sh`：306 passed、1 skipped、0 failures；Release build passed。结果包：`/tmp/dynamic-island-ci-results-66362/TestResults.xcresult`。
- `git diff --check`：通过。

验收覆盖必须至少证明：合法嵌套入口通过；恶意路径、缺失或错误类型入口、错误大小写 Manifest/entry、超大文件或包、超量条目、隐藏/package 内容计数、稀疏文件、symlink、hardlink、特殊文件、重复 ID 和过高 Host 要求均被拒绝；验证过程不会执行 JavaScript；入口在验证后变化不改变返回的 `entrySource`。
