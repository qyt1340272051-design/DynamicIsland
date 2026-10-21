# DynamicIsland 官方插件包（Host 0.6.0 开发版）

本 Release 分发两款已完成单机实战验证的官方示例包，使用 SDK 1.0.0 的有限 Native 接口，采用 MIT 许可。运行需要包含插件系统的 Host 0.6.0；公开 App 0.5.0 不具备该 Runtime。

| 插件 | 版本 | 包大小 | 声明权限 |
| --- | --- | --- | --- |
| 番茄钟 | 0.2.1 | 7,319 bytes | `storage.local`，保存预设与状态元数据。 |
| GitHub | 0.1.0 | 10,215 bytes | `network` 读取公开 API；`storage.local` 保存选择与去重；`links.open` 由真实按钮打开允许的 GitHub 页面。 |

## 获取与安装

下载同页的 `.dip`、`SHA256SUMS` 和 `release-manifest.json`。将两款 `.dip` 与 `SHA256SUMS` 放在同一目录，运行 `shasum -a 256 -c SHA256SUMS`。

| 文件 | SHA-256 |
| --- | --- |
| `pomodoro-0.2.1.dip` | `444647bb7a2f40dc0c66418b62e94210c76f2b890f3df2681c2fd179ce5e25b2` |
| `github-0.1.0.dip` | `5a090cbc251b48d34ffed3bd82d8fd5ff42214e7c6386b769e1ba70477bae0fa` |

兼容 Host 可通过「插件管理 → 导入插件」选择包，核对名称、版本、来源与逐项权限，再确认安装。安装后保持停用；启用不会自动批准权限。README 和 LICENSE 的改变也会改变整包身份，旧包批准不能自动沿用到当前包。

目录发布后，可在兼容 Host 的「发现」页面主动刷新目录，选择「下载并查看」，经过相同的摘要校验和安装预览。SDK、插件包与目录分别发布；目录不提供自动安装、自动升级或授权服务。

## 行为与验证边界

番茄钟提供 15 / 25 / 45 / 60 分钟预设、暂停 / 继续、应用内完成提示和本地设置。Host 倒计时不跨应用重启保存；存储的运行元数据不会自动开始新一轮。GitHub 插件只读取 `actions/checkout`、`cli/cli` 公开仓库，遵守匿名配额与退避，不需要 Token，也不支持私有仓库。

每款归档精确包含 Manifest、JavaScript、README 和完整 MIT LICENSE。两款脚本与 Manifest 保持已实测版本；本次公开包更新说明并附许可，完整性清单记录实际字节。冻结、重复和独立重打的产物一致。

已有真实计时、逐项授权、仓库切换和系统网页打开的单机验收与自动 Runtime 测试分别留存。本 Release 标记为预发布分发，主 App 0.6.0 安装包仍另行处理；这不替代新作者独立体验、其他设备兼容或整个 Plugin 1.0 阶段验收。
