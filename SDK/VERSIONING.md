# SDK 1.0.0 版本和兼容策略

状态：SDK `1.0.0` 稳定的有限作者接口。构件及公开状态见 [sdk-v1.0.0 Release](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/sdk-v1.0.0)；Host wire 协议沿用现有版本。

| 标识 | 当前值 | 含义 |
| --- | --- | --- |
| SDK 版本 | `1.0.0` | 稳定的有限作者工具和类型版本；其发布独立于 App 与协议升级。 |
| Manifest `schemaVersion` | `1` | Host 解析的包格式；未知字段和声明拒绝。 |
| `island.apiVersion` / 方法 namespace | `1.0.0` | 当前桥接协议标识；不单独授予能力或权限。 |
| Manifest `minimumHostVersion` | Hello 为 `0.6.0` | 安装时的最低 Host 版本门槛；不能省略。 |

本版本只整理现有两官方插件使用过的接口。两款官方插件的实机依赖已于 2026-10-19 满足，范围见[验证说明](docs/verification.md)；本版的公开构件与同一源码状态的校验信息见对应 Release。有限类型和 Schema 不能覆盖主程序的所有运行状态，也不能提升 SuperIsland 的兼容等级。

T39 本日首次作者走查暴露了交互式 zsh 粘贴完整 Bash 源码的问题；Quick Start 已改为首个可复制的单行入口，修正后的协助功能复测已通过，用户自行打包、安装、启用并确认计数更新。该修正不更改 wire 协议、Manifest schema 或权限；首次独立体验及约十分钟目标仍待复测验证。

本版冻结的有限接口及行为见[变更说明](CHANGELOG.md)。公开后的删除方法、返回类型或默认行为改变必须进入新的 SDK major 版本并提供迁移说明；新增向后兼容的 SDK 能力使用 minor，修正文档或校验缺陷使用 patch。SDK SemVer 不能代替 Host wire 协议版本。即使只新增 Host 声明，也不能让旧包自动取得 capability 或授权。代码 / Manifest 改变后的授权失效继续由 Host 执行。

`package.json` 与 lockfile 使用 `1.0.0`，`private` 保持 true，不执行 npm 发布。独立归档包含许可证和逐文件摘要，最终复核及发布步骤见[分发说明](DISTRIBUTION.md)。历史 `0.1.0-experimental` 证据保留其原始状态，不反写为本版结果。

未来稳定版本应分别管理 SDK 和协议版本：在现有严格解码中新增必填字段、修改默认行为、删除方法或改变返回类型均需显式新协议 / 迁移策略，不能仅更新文档而让旧 Host 误收。保留现有协议的兼容实现后再扩大支持范围，且必须补充真实插件验证。SDK 与主 App 安装包、插件包及 Registry 条目分别发布和验收。
