# Plugin Registry V1

本目录登记已公开的固定版本插件包，供具备插件系统的 Host 0.6.0 主动发现。公开 App 0.5.0 不包含插件 Runtime；本次登记不发布或升级主程序。

## 官方插件

| 插件 | 版本 | 最低 Host | 声明权限 |
| --- | --- | --- | --- |
| 番茄钟 | 0.2.1 | 0.6.0 | `storage.local` |
| GitHub | 0.1.0 | 0.6.0 | `network`、`storage.local`、`links.open` |

包、完整性清单、许可和行为范围见 [plugins-0.6.0 预发布](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/plugins-0.6.0)。每款 `.dip` 精确包含 Manifest、JavaScript、README 和完整 MIT LICENSE。SHA-256 对应当前公开归档字节，不能沿用较早候选包的授权身份。

在兼容 Host 的「插件管理 → 发现」中点击「刷新目录」，再选择「下载并查看」。下载会核对摘要、归档安全与实际 Manifest；仍须核对预览并确认安装。安装后保持停用，启用不自动批准任何权限。未知权限默认拒绝，包身份改变后需要重新确认。目录本身不是开发者身份或许可证明。

默认目录地址为 `https://raw.githubusercontent.com/qyt1340272051-design/DynamicIsland/main/Registry/registry.json`。打开窗口保持离线，只有主动刷新才请求目录；不提供后台轮询、自动安装、自动升级或自动授权。

## 清单契约

顶层只有数字 `schemaVersion: 1` 和 `plugins` 数组；每项必须精确包含 `id`、`name`、`version`、`download`、`source`、`minHostVersion`、`hash`。未知字段、重复字段和重复 ID 拒绝；最多 100 项、整个 JSON 最多 256 KiB。

- `id`、`name`、`version` 沿用 Host Manifest 规则。
- `source` 必须是 GitHub 仓库根 HTTPS 地址。
- `download` 必须是同一仓库的固定 Release `.dip` 地址，不接受 `releases/latest/download`、任意网站、查询参数或凭据。V1 标签和文件名仅支持 ASCII 字母、数字、点、下划线和连字符。
- `minHostVersion` 必须与包内 Manifest 的 `minimumHostVersion` 一致。
- `hash` 是实际 `.dip` 字节的 64 位小写 SHA-256。

目录源限制为 `raw.githubusercontent.com` 的仓库 / 单段 ref / `Registry/registry.json`，目录重定向拒绝。Release 下载只允许 GitHub 的 `release-assets.githubusercontent.com` 资源重定向，仍执行大小与摘要校验。下载和本地导入共用安装事务：先核对同一份字节，再解包、验证、预览、显式安装；清单不能覆盖实际 Manifest 或绕过权限决策。
