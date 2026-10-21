# T40：官方插件发布与真实 Registry 安装验收

2026-10-20 开始，2026-10-21 完成。T38 SDK 1.0.0 前置已满足，T40 标为 `verified`。当前 **39 verified / 1 in progress**，T39 新作者独立体验按用户要求暂跳过。

## 公开构件

[plugins-0.6.0](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/plugins-0.6.0) 已公开，保持 **prerelease**，最低 Host 0.6.0。公开 App 0.5.0 没有插件 Runtime；本次没有创建 App 0.6.0 DMG。

| 插件 | 版本 | 实际字节 | SHA-256 |
| --- | --- | --- | --- |
| 番茄钟 | 0.2.1 | 7,319 | `444647bb7a2f40dc0c66418b62e94210c76f2b890f3df2681c2fd179ce5e25b2` |
| GitHub | 0.1.0 | 10,215 | `5a090cbc251b48d34ffed3bd82d8fd5ff42214e7c6386b769e1ba70477bae0fa` |

同页另有 `SHA256SUMS` 和 `release-manifest.json`。两款各精确包含 Manifest、JavaScript、README 和完整 MIT LICENSE。脚本、Manifest、权限与已实机验收版本一致；本次修正过时 README，整包身份变化，不能继承旧包授权。三次独立生成的五份本地产物逐字相同；草稿下载和四个公开资产匿名 HTTP 200 下载均逐字匹配冻结产物。

公开标签只含插件源码树：提交 `e4f0bb373c9a6fb610c68f6d156261d9902033b7`、树 `54b230ea665507a716997b1860220263a44438b2`，无父提交、十个文件。来源为冻结 Host 开发提交 `a518361` 中的两款包及发布说明，没有推送整个 Host 开发分支。SDK 1.0.0 源码保持冻结版本。

## 目录登记与保护规则

[PR #3](https://github.com/qyt1340272051-design/DynamicIsland/pull/3) 仅新增 Registry 两个文件。先验证实际公开资产，再对 PR 固定提交 `7c198aee3ee8b839ec24c4bd702e11a7d0bbff5a` 运行生产 Host 公网安装链路。[必需 CI](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39453141716/job/118732963147) 通过后正常合并，未绕过 main 保护规则。

main 合并提交为 `7193cdc5021b603abd3a046fed74b027d07c177a`。[默认正式目录](https://raw.githubusercontent.com/qyt1340272051-design/DynamicIsland/main/Registry/registry.json) 匿名 HTTP 200，879 字节、两项，SHA-256 为 `9392649799c432bbf2f1efe1dd25e61956695abc1fa35c6a98d7975089d63c2f`，与冻结候选完全相同。Host 默认地址未变。

## 真实 Host 闭环

新增显式开启的 [PluginRegistryLiveTests](../../DynamicIslandTests/PluginRegistryLiveTests.swift)。使用正式 RegistryModel / RegistryClient、无凭据 URLSession、Installer / Validator、权限与存储服务、JavaScriptCore / ActivityManager / Router；没有 URLProtocol、假归档或本地目录替代。

1. 主动读取公开目录，核对身份、版本、固定下载地址、最低 Host、SHA-256。
2. 真实下载、同字节摘要核对、解包和 Manifest 验证后进入预览；下载和预览均不安装或执行。
3. 显式确认安装，记录保持停用、权限 `requested`、Runtime 不运行，Staging 清空。
4. 启用本身不批准权限；测试在临时权限存储中逐项明确批准，再启用真实 VM 工具。
5. 经真实动作路由选择番茄钟 15 分钟预设并写入 KV，不开始倒计时；停用后工具撤销、旧动作拒绝。
6. 新建 Host 服务对象图，从磁盘恢复启用状态、权限和预设，实例令牌更新、Staging 为空。此处不是 App 进程重启。

| 运行 | 通过 | 跳过 | 失败 | 范围 |
| --- | --- | --- | --- | --- |
| PR 固定公开提交 | 1 | 0 | 0 | 7.715 秒，`defaultSource=false` |
| 默认 main | 1 | 0 | 0 | 8.230 秒，`defaultSource=true` |
| Registry 核心 / 模型 / UI | 28 | 1 | 0 | 29 total；锁屏环境跳过原生 AppKit 鼠标输入项 |
| 普通 Release 构建 | 通过 | — | — | 隔离副本另通过 strict / deep 签名验证 |

离线目录测试已从“必须为空”改为两款正式构件的完整固定契约。实时测试默认跳过，显式执行的两轮均零跳过。复测命令仍须核对计数和 `defaultSource=true`：

```sh
DYNAMIC_ISLAND_LIVE_REGISTRY=1 TEST_RUNNER_DYNAMIC_ISLAND_LIVE_REGISTRY=1 xcodebuild test -project DynamicIsland.xcodeproj -scheme 'Dynamic Island' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:DynamicIslandTests/PluginRegistryLiveTests
```

GitHub 工具发布不代表本轮重新验证实时 CI / PR 内容或系统网页打开；相关实机结论保留 [T36 原验收范围](evidence/t36-manual-20261019/result.json)。没有新增真实十五分钟自然到期验收。

## 实际界面与保留项

普通 Release 的全新隔离副本 `Dynamic Island Registry Acceptance` 初始安装数为零。CUA 实际打开插件管理和发现页，验证初始离线，点击刷新后从默认 main 展示两款公开条目；原始窗口像素已检查、保存。

保存完整 AX 状态后索引重排，一次旧索引误开帮助菜单；随后工具持续返回失效菜单引用、截图不可用，取消、重新绑定和重建工具会话未恢复。本轮没有点击真实网络 GUI 安装确认，不把该项算作通过。副本通过 Cmd-Q 正常退出、进程消失，没有改变生产插件数据。既有 AppKit 控件输入与本轮真实生产 Host 网络闭环分别留存，覆盖 T40 原发现、下载、验证、安装完成标准；不新增强制人工悬停门槛。

T39 仍需新作者仅按公开 SDK 文档独立构建和安装，约十分钟为待验证目标，暂不安排。整体 Plugin 1.0 和主 App 0.6.0 对外发布尚未完成。

## 证据与回滚

[result.json](evidence/t40-publication-20261020/result.json) 和[证据说明](evidence/t40-publication-20261020/README.md)保存独立产物复核、公开下载、PR / CI、两轮实时日志、回归、构建与截图。独立审查未发现阻塞问题。

撤回条目应以新 PR 修改目录，保留已发布包、标签和摘要；本地导入不依赖目录。不自动卸载、升级、启用插件或改变已有权限。发布工作树已提交完成并请求归档。
