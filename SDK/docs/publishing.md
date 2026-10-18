# Publishing

本 SDK 与文档仍为实验草案。当前可以准备 `.dip` 和分发说明；稳定 SDK 发布、官方插件真实验收与 Registry 是独立门槛。当前开发版已接入插件管理中的「发现」，由用户刷新目录、下载并查看，再明确确认安装；正式目录尚无条目，真实发布网络链路未验收。没有自动审核或自动更新服务。

发布准备应包含：唯一 ID 与递增版本、最低 Host、功能和每项权限解释、来源与许可、变更说明、已验证 / 未验证的平台行为，以及固定包的校验值。先完成 [Packaging](packaging.md) 和安装 / 启用 / 撤销 / 重启验收，再由作者选择自己的发布渠道。

包名、developer 字段、下载链接和摘要都不能代替作者身份验证或代码审查。摘要只能核对所下载的字节；授权仍由 Host 针对当前代码逐项处理。不要把升级描述为自动沿用旧授权。

版本号遵循 [SDK 版本策略](../VERSIONING.md)：插件版本属于作者，minimumHostVersion 说明最低主程序，Manifest schema 与 wire API 各有自己的标识。实验 API 改动时同步示例和测试，说明旧包如何迁移，避免只改一个版本字符串就假定兼容。

T40 使用仓库内 registry.json，记录 id / name / version / download / source / minHostVersion / hash；发布门槛完成前，本页不提供提交地址或承诺登记服务。本文档更新没有上传 SDK、插件或 Registry 条目。
