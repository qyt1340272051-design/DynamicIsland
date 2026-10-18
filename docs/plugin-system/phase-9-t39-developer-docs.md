# T39：开发者文档与可验证示例

日期：2026-10-18。按用户允许延期人工验收的安排，继续 T38 实验草案的作者资料。T38 / T36 / T35 的依赖门槛保留，T39 为 `in progress`；新作者按文档首次安装以及约十分钟的目标尚未实测。

## 交付

[SDK 开发手册](../../SDK/docs/README.md)覆盖计划指定的 Quick Start、Manifest、Activity、UI Components、Actions、Storage、Network、Permissions、Settings、Lifecycle、Debugging、Packaging、Publishing 共 13 个主题，另有索引和验证边界页。无需阅读 Swift 源码即可理解有限 Native API。

Hello 沿用 T38 的单一可打包源目录，没有另做分叉模板。Quick Start 将模板复制到新的工作目录，执行真实离线校验和 package 命令，说明安装后停用、启用、工具选择、点击和重启归零。约十分钟只作为设计目标。

四个补充函数片段演示 Activity 生命周期、设置默认值 / schema 校验、一次网络请求和真实动作打开链接。文档明确它们需要结合入口与各自 Manifest 声明；不能当成独立包直接运行。Settings 没有增加不存在的 API 或 Manifest 字段；网络限于当前 Host 允许的 API 目标；入站无原型数据、授权失败、一次性 activation、同步 hooks 和 presentation 整体替换均有说明。

## 自动验证

[证据](evidence/t39-docs-20261018/result.json)：

- 文档检查覆盖 15 页、8 个完整代码块、33 条本地链接；示例逐字对照实际源码。错误标记、代码漂移、断链会失败。
- SDK Python **37 passed / 0 skipped / 0 failures**，包含 4 个新文档测试。Quick Start 在仅有 SDK 的临时副本中实际执行，生成 `.dip` 与正式 Host 契约测试包字节一致。
- 所有手册 JS 参加原严格 TypeScript 检查及语法检查；既有 47 项预期类型错误保持通过。
- 正式 Host 定向 **7 passed / 0 skipped / 0 failures**：4 个新文档测试和 3 个 SDK 契约测试。读取原始文档示例文件，校验临时包后进入实际 VM / Bridge / Manager / Router；验证发布更新结束、未授权 / 批准 / 撤销存储、非法业务 JSON、网络状态和真实动作链接。只替换网络响应和系统 opener，不发真实请求。
- 本子步骤未改变产品 Swift 源码，未重复完整 UI / Release 矩阵。构建出现的两项历史 actor 警告不由本次新增测试引入；没有新增编译错误。

## 后续门槛

需要新作者按 Quick Start 完成第一次安装并确认信息足够；暂不要求用户现在操作，不以自动 Host 测试代替人类上手体验。M01 / M02 继续按原安排延期，本轮未启动验收副本或新的十五分钟计时。稳定 SDK、真实上游兼容和 Registry 发布仍分别保留。
