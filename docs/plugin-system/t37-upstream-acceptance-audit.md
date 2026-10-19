# T37 固定上游样本验收前置审计

2026-10-19 范围更新：用户明确选择本版交付兼容子集，并用独立编写的简单插件完成实机验收，见[原创示例与本轮验收](t37-independent-examples.md)。下文保留固定上游的历史审计；其中许可与 API 差距仍是原样上游插件的已知限制，不再作为本版 T37 的必达门槛。

日期：2026-10-17。状态：只读来源审计完成；真实上游插件验收仍待完成，T37 保持 `in progress`。本轮没有运行上游插件、启动验收 App、复制入口或样本正文，也没有扩展兼容 API。结构化记录见[审计证据](evidence/t37-upstream-audit-20261017/result.json)，其中 `actualUpstreamPluginsRun=false`。

## 固定来源与检查范围

首批协议目标沿用[范围记录](phase-8-t37-superisland-scope.md)中的 [shobhit99/SuperIsland commit `68cce87205a88a004e74e33f40bbcb253f8287e9`](https://github.com/shobhit99/SuperIsland/tree/68cce87205a88a004e74e33f40bbcb253f8287e9)。[Git Commit API](https://api.github.com/repos/shobhit99/SuperIsland/git/commits/68cce87205a88a004e74e33f40bbcb253f8287e9) 给出的提交时间为 `2026-09-13T03:54:09Z`，实际 Git tree SHA 为 `1386259ef7cf03c32113ae5401c033458dbde3e9`。

[完整递归 Git Trees API](https://api.github.com/repos/shobhit99/SuperIsland/git/trees/1386259ef7cf03c32113ae5401c033458dbde3e9?recursive=1) 返回 `truncated=false`。本轮检查：

- 在整个固定树中按文件名查找 LICENSE、LICENCE、COPYING、NOTICE，大小写不敏感，包含扩展名变体。
- 静态读取 `Extensions/` 下 **44 个 UTF-8 文本文件**，包含各插件 README、Manifest、JS、SVG、settings、hooks 和 server 等；排除 `.wav` 音频及 `package-lock.json` 依赖元数据。精确路径、排除路径、Git blob SHA、SHA256 和读取来源 URL 全部写入审计证据。
- 另检查根 README 与 `SUPER-ISLAND-EXTENSION-API.md`。`Extensions/README.md` 已包含在上述 44 项中。
- 文本检查使用 license/licence、copyright、SPDX、MIT 及常见授权正文短语；结果同时用于人工区分 Manifest 元数据、字段文档与实际授权正文。

只在内存中读取上游字节并计算身份；提交到本仓库的记录保存路径、哈希、API 名称、行号和审计结论，不保存上游入口或示例正文。依赖锁文件中的第三方包许可字段不作为插件自身的许可依据。

## 许可材料结果

固定树没有找到独立许可文件。七个插件 Manifest 都声明 `MIT`，例如 [Pomodoro Manifest L12](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/pomodoro/manifest.json#L12)，但各自 README、入口和其他受检文本没有找到配套许可正文或版权授权条款。根 README、Extensions README 和 Builder Guide 也没有找到独立授权正文。Builder Guide 中的 `license` 命中为 Manifest 字段说明。

观察时的 [Repository API](https://api.github.com/repos/shobhit99/SuperIsland) 返回 `license=null`；该字段是当前仓库元数据，其时间范围与固定提交的树检查分别记录。

按项目已有“纳入或分发上游代码／示例前补齐许可依据”的材料门槛，当前材料仍有缺口。本页记录检查结果与项目验收状态，不作法律结论。无需因此向用户追加问题或发送外部消息；其他已授权自动工作可继续。

## 七个真实插件与当前支持子集

当前兼容输入仍须使用[严格 DynamicIsland Manifest V1 外壳](phase-8-t37-manifest-profile.md)，显式声明 `engine=superisland`。上游原 Manifest 不直接进入 Host 解码。

[同 VM 模块子集](phase-8-t37-module-runtime.md) 接受 compact、expanded、onActivate、onDeactivate、onAction 五个字段；View 接受 text、icon、hstack、vstack、progress、button 六种工厂。[展示请求](t37-presentation-requests.md) 由 Host 裁决。本轮依据这些现有合约对上游原始文件作静态比较，没有执行插件。

七个插件都包含当前不接受的 fullExpanded／minimalCompact 模块配置，并各有额外依赖：

| 固定样本 | 代表性范围外能力 | 固定原始入口 |
| --- | --- | --- |
| Agents Status 1.6.0 | HTTP、settings、JS 定时器、通知／反馈，以及 frame、padding、scroll 等 View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/agents-status/index.js#L709) |
| AI Usage Rings 1.0.0 | system.getAIUsage、circularProgress、frame、spacer | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/ai-usage/index.js#L279-L345) |
| Last.fm Scrobbler 0.1.0 | media、HTTP、store、settings、JS 定时器、通知、URL 打开，以及图片／装饰 View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/lastfm-scrobbler/index.js#L1887) |
| Linear Mentions 1.0.0 | HTTP、store、settings、JS 定时器、通知交互、输入组件及图片等 View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/linear-mentions/index.js#L925) |
| Live Football 1.0.0 | HTTP、settings、JS 定时器、通知／反馈／URL 打开，以及图片、滚动和动画 View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/live-football/index.js#L918) |
| Pomodoro Timer 1.0.0 | settings、store、JS 定时器、通知／反馈／mascot，以及 circularProgress、zstack 等 View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/pomodoro/index.js#L315) |
| WhatsApp Web 1.0.0 | WhatsApp 系统桥接、settings、通知交互、输入组件，以及图片、滚动和 Markdown View | [index.js](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/whatsapp-web/index.js#L448) |

审计证据为每个样本分别保存 Manifest、入口和 README 的来源 URL／Git blob SHA／SHA256，以及代表性 API 行号。以上是静态能力差距，不是运行失败结果。当前没有一个原样入口完全落在已声明的子集内；许可材料补齐后仍需解决样本选择与现有子集的匹配问题。T37 的真实样本验收门槛继续保留，不增加未批准的 API 范围。

## Hello 文档候选

[Builder Guide Quick Start L13–L31](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/SUPER-ISLAND-EXTENSION-API.md#L13-L31) 使用的 text、icon、hstack 与 compact／expanded／onAction 声明在现有同步协议范围内。它可作为最小静态候选，仍需独立 DynamicIsland Manifest 外壳和许可材料；本轮没有提取其正文或运行它。

这个例子没有按钮或 progress，也不能覆盖计划要求的若干真实插件。它的静态匹配结果与已有独立协议夹具均不计入真实插件通过数。

关键固定文件身份如下；其余文件见 JSON：

| 文件 | SHA256 |
| --- | --- |
| SUPER-ISLAND-EXTENSION-API.md | `53a7c877ee6fc140c2a3394b521669b911c431305263959e63880d04c483a384` |
| Extensions/ai-usage/index.js | `4f8b8f7949101462a88bc78af9464401af92044054a5c2e09dc9401652df6b25` |
| Extensions/pomodoro/index.js | `140f7d10eeaaf567a8f40e8193ad6472d4e3234ce5989d3a630a66c9d89d8772` |

## 客观待办与后续证据

当前受阻项只有：

1. 固定候选缺少符合项目既有门槛的可追溯许可材料。
2. 七个内置插件均超出现有子集；Hello 单例无法覆盖若干插件、按钮与 progress 的真实验收要求。

后续若出现满足上述条件的样本，真实运行记录应分别保留原始 commit／路径／Git blob SHA／SHA256、独立 Host Manifest 外壳哈希、实际 Host 构建身份、权限与启用状态、真实界面和动作观察，以及不支持行为和视觉差异。改写上游入口的实验单独记录为迁移实验。

本轮不将 T37 标为 `verified`，不以源码静态匹配替代真实运行，也不因审计结果自动启动后续稳定 SDK 验收。
