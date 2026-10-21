# Phase 7 — T34 .dip Installer

日期：2026-10-13–14。依赖 T19、T28 已验收；实现与验收完成。

## 流程与职责

原生导入入口接受 `.dip`，在源文件 security-scoped 访问期间读取有界压缩数据。插件管理页和状态栏共用导入入口；文件类型注册将 Finder 打开交给 `NSApplicationDelegate.application(_:open:)`。启动前 URL 队列最多四项，初始化完成后只打开一个安装预览；未完成预览时后续请求明确提示重试，不替换用户正在确认的包。

`PluginInstaller` actor 在 Host 的私有 `Staging/<UUID>` 解包；Validator 验证 Manifest / 最低 Host / 入口和文件树，再构造不可伪造的不可变 review。准备阶段没有注册生命周期、执行 JavaScript 或批准权限。预览展示名称、版本、开发者自述、旧版本 / 降级信息和 Host 提供的权限用途。确认与取消都绑定本次 token；关闭预览也取消。

安装成功后通过 Manager / 生命周期注册为停用，返回管理页并选中插件。用户分别批准权限和启用插件。升级中新代码或 Manifest 变化会在 T33 的持久化授权准备步骤中重置为 requested，新增权限不沿用旧批准。

## 解包边界

`.dip` V1 是明确的 ZIP32 子集；使用系统 zlib，没有调用外部 unzip / shell。压缩包最多 40 MiB；单文件 8 MiB，总量 32 MiB，256 个普通文件，512 个路径节点（含隐式父目录），16 个路径组件和 1024 字节相对路径。注入策略只允许收紧默认上限。

central / local 元数据必须一致，成员范围精确覆盖 payload 区；reject Zip64、多卷、加密、descriptor、未知 extra、路径穿越、链接、特殊类型、名称规范化冲突、重叠和隐藏记录。raw deflate 按固定 buffer 解压，每次实际输出检查配额，精确校验结束、大小、压缩字节耗尽和 CRC。创建输出使用 descriptor-relative no-follow / exclusive 文件操作，固定目录 0700、文件 0600，不恢复压缩包的权限、owner、ACL 或扩展属性。

完整格式与打包方法见 [dip-format.md](dip-format.md)。

## 安装事务与恢复

Manager 的既有 FIFO 覆盖确认时的全树 SHA256 重验、已安装快照匹配、Runtime 停止、排他 rename、状态持久化与生命周期注册。升级先将旧包移到同卷 `Recovery/<UUID>`，新包从暂存移至 `Installed/<pluginID>`；保存的新状态始终 disabled。未提交前的验证 / 移动 / 保存错误尝试恢复旧目录和旧 Runtime，失败则保留 Recovery 并关闭执行；旧 lease 不会因回滚重新获得准入。

所有资源文件都进入预览 fingerprint，同大小资源变更也使确认失效。`entrySource` 仍以 Validator 的不可变快照交给 Runtime，不重新打开入口脚本。

每次事务在第一次移动前写入严格的 pending marker 并 fsync，避免同版本替换在状态提交前中断后沿用旧 enabled 记录。重启发现有效 marker，先持久化停用，再清除有效 marker；保留异常 Recovery 供恢复。损坏 marker 不被自动覆盖，所有发现包都保持停用并给出固定错误。状态已提交之后的清理失败不会逆转成功的 disabled 安装。

取消和失败清理只操作 Host 曾创建且 inode/device 匹配的目录。清理失败保留可重试的清理状态，阻止在同一 Installer 中继续堆积待安装目录；跨启动的暂存 / 恢复配额也限制遗留文件量：暂存最多四个根目录、恢复最多十六个根目录，各自逻辑文件总量最多 128 MiB，注入策略只能收紧。预览还绑定 Manager 安装 generation，两个同版本、同大小资源更新的并发确认也不会相互覆盖。

## 验证

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 接入定向 | 91 passed、0 skipped、0 failures；Installer 当时 18 项、归档 17、UI model 12、注册 1、Manager 14、权限持久化 15、生命周期 14。后加第 19 项 Recovery 预算预留，由完整 CI / Release 覆盖。 | `/tmp/dynamic-island-t34-core/TestResults.xcresult`。 |
| UI model / 原生控件 | 12 model + 2 UI passed；背景修正后 2 UI 再次 passed，0 skipped / failures。 | `/tmp/dynamic-island-t34-ui-v1/TestResults.xcresult`、`/tmp/dynamic-island-t34-ui-v2/TestResults.xcresult`。 |
| 完整 CI / 普通 Release | 最终 699 total、698 passed、1 skipped、0 failures；Settings 初始化修正后的完整回归及普通 Release build 均通过。 | `/tmp/dynamic-island-t34-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t34-final-ci-v2/TestResults.xcresult`。 |
| Release 定向 | 150 passed、0 skipped、0 failures，包含安装 / 解包 / 管理 / 权限、真实 JS Runtime、生产 factory 和原生 UI。 | `/tmp/dynamic-island-t34-release-tests/TestResults.xcresult`。 |
| 普通 Release 签名 | strict / deep 通过；Sandbox / allow-jit=true，无 get-task-allow / disable-library-validation；生成后的 Info.plist 文档声明正确合并。 | `/tmp/dynamic-island-t34-release-entitlements.plist`、普通 App `/tmp/dynamic-island-t34-derived/Build/Products/Release/Dynamic Island.app`。 |

环境：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。唯一 CI skip 是既有截图生成入口。测试 Host 的注入 / library-validation 例外只在临时测试目录启用，不在普通 App 中。

640×520 的生产 NSWindow 安装预览截图与本地 Vision 检查通过，内容和按钮完整可读；原生点击使用同一 production View 的 nonactivating NSPanel fixture，确认 / 取消 / 关闭、lease 平衡、升级 / 降级和清理错误状态均有回归。截图在 App 容器 `Data/tmp/dynamic-island-t34-install-preview.png` 与 `dynamic-island-t34-installed-disabled.png`。

### 普通 App 的实际交互

使用上述普通 Release App，执行真实 Settings、NSOpenPanel 与管理窗口，测试包来自本仓库本地 Mock，未申请权限：

1. 启动时 Settings 曾缓存初始化占位内容；已用独立 `@ObservedObject` View 修复，重新启动后显示管理页。
2. 系统选择器导入 ID 不合法的包，显示固定 `invalidPackage` 并禁用安装。
3. 合法 `com.example.installer.acceptance.run20261013` 包显示完整名称 / 开发者 / 无额外权限预览；点击安装后管理页显示已停用。
4. 实际点击启用后显示运行中；停用后确认卸载，两个共用模型的管理窗口都恢复已安装 0。
5. 验收插件已卸载，临时验收 App 已退出；未批准真实剪贴板或网络权限。

### Finder 关联验收补充 — 2026-10-14

Finder 双击关联仍需修正 / 验收。实测 `.dip` 已解析为 `com.rong5.dynamic-island.plugin`，但 `LSCopyAllRoleHandlersForContentType` 返回归档实用工具 / Keka，没有本 App；Finder 打开将合法测试包解压到同名目录，没有进入安装预览。强制重新登记临时构建 App 后结果仍相同。没有改写用户的默认打开方式来掩盖问题，也没有将此路径记为通过。

本轮以完全相同的签名 Release 副本放到正常应用目录后，系统查询与 Finder 双击均选中本 App，冷启动准确进入权限预览，取消后没有执行或遗留暂存包。根因收敛到本机临时构建目录的候选选择；未更改 Info.plist 角色 / 继承或用户默认程序。详细对照、进程与清理证据见 [Finder 实际验收](evidence/t34-finder-20261014.md)。T34 标记 `verified`。T31 的正式 App 多插件长时 Energy Impact / 能耗仍未完成，T35 尚不开始。
