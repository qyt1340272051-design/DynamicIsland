# T38：SDK 1.0.0 正式发布

2026-10-20 已公开 [DynamicIsland SDK 1.0.0](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/sdk-v1.0.0)，T38 标为 `verified`。[结构化结果](evidence/t38-sdk-release-20261020/result.json)保留发布、来源、检查及剩余边界。

## 公开产物与源码

| 内容 | 结果 |
| --- | --- |
| Release | `sdk-v1.0.0`，普通稳定发布，非草稿、非 prerelease；UTC 2026-10-20 15:33:53（北京时间 23:33:53）公开。 |
| SDK ZIP | 85,192 bytes，53 个源文件和生成的清单；SHA-256 `b64d87e400a90f730bd098cce23dc7b743cf78dcbfcb4f878f7cfeb16a494ac9`。 |
| 构件 | ZIP、`.zip.sha256`、`.manifest.json` 三份文件，同页可公开下载。 |
| 原始提交 | `69a9fe72b706930132f8b2d7e319d394c46ddf9e` 的 SDK 目录。 |
| SDK 专用标签提交 | `da3e6273b01f197b7044ed7d036b6a5f0f95f092`，树为 `79bc3ace4e378dddf29eb332be171b9379daffee`。 |
| 推送范围 | 仅 SDK 标签及其 SDK 专用历史，未推送完整 Host 开发分支。 |

[来源映射](evidence/t38-sdk-release-20261020/source-mapping.json)逐项确认标签树等于原始提交的 `SDK` 树、53 个构件源文件逐字一致，7 个可达 SDK 专用提交均只含 SDK 范围。标签根目录直接是 SDK，54 个 Git 跟踪文件中的 `.gitignore` 按分发规则排除；ZIP 另生成完整性清单。GitHub 自动生成的 Source code 归档和命名 SDK ZIP 的字节及目录不同，校验文件用于命名 ZIP。

稳定版统一了 README、版本策略、类型头、CLI 和 Schema 来源的发布说明，归档清单为 `stable`。API、协议、权限及 Hello JavaScript / Manifest 没有扩展。Hello README 改变后重新生成 `.dip` fixture；旧 84,717-byte / `8f4da7…` 候选保留于本地 `artifacts/sdk/history/pre-stable-20261020/`，不反写历史人工阅读或操作事实。

## 实际验证

- [仓库 SDK gate](evidence/t38-sdk-release-20261020/sdk-check.txt)：40 passed / 0 skipped / 0 failures；类型正例及 47 项预期错误通过，15 页、9 个源码块、34 条本地链接。
- [Host 契约](evidence/t38-sdk-release-20261020/host-contract.txt)：8 passed / 0 skipped / 0 failures，覆盖 Hello、独立原创双按钮、Schema / Converter 和文档资源合约。未修改生产 Swift，未为此次 SDK 发布重跑完整应用 CI。
- [独立冻结包审计](evidence/t38-sdk-release-20261020/independent-result.json)：53/53 源文件匹配、MIT / CRC / 排除规则通过；脱仓库 38 passed / 2 skipped / 0 failures，跳过项仅依赖完整仓库的官方示例与旧 wrapper。两次重打与最终 ZIP 逐字一致。
- [草稿服务器复核](evidence/t38-sdk-release-20261020/draft-verification.json)：已认证下载三份草稿资产，均与本地冻结字节一致；远端标签的 peeled commit 匹配 SDK 专用提交后才公开。
- [匿名公网复核](evidence/t38-sdk-release-20261020/public-verification.json)：不带 Authorization 或 Cookie，从公开 API 与三条公开资产地址获取成功，HTTP 200、摘要一致，53 文件哈希一致；从实际下载的 SDK 运行 Quick Start，生成的 Hello 包与其 fixture 逐字一致。该路径不读取主 App Swift 源码。

初次 SDK gate 暴露文档测试副本缺少新链接所需的分发说明文件，见[初始失败日志](evidence/t38-sdk-release-20261020/sdk-check-initial.txt)。测试副本现包含五个根文档 / 许可文件，保留原有漂移与坏链接拒绝断言，复跑通过；没有通过删除有效链接或削弱断言避开失败。

## 发布元数据与剩余任务

发布与公开后的补充请求均使用 `make_latest=false`。GitHub 当前仍把唯一的普通稳定发布 SDK 报为 `isLatest=true`，此前 Latest API 为 404，两份 App Release 均为 prerelease；[实际列表](evidence/t38-sdk-release-20261020/release-list-after.json)保留该行为。现有 App Release 未修改，当前应用代码没有调用 `releases/latest` 的自动更新器。发布页和命名资产明确为 SDK；App 0.6.0 安装包仍单独处理。

SDK 需要包含插件系统的 Host 0.6.0；公开的 App 0.5.0 不具备该 Runtime。有限稳定接口不代表完整 Host 能力或更高 SuperIsland 兼容。T39 新作者仅凭文档构建安装与约十分钟目标、T40 官方插件包 / 正式 Registry / 真实网络安装仍分别为 `in progress`。原 T01–T40 当前 **38 verified / 2 in progress**；补充 U01 已独立验收。
