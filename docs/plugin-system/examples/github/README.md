# GitHub 官方插件 0.1.0

包 ID：`com.dynamicisland.github`；开发者：DynamicIsland；版本：0.1.0；最低 Host：0.6.0。

这是公开 API 示例。工具页提供 `actions/checkout` 和 `cli/cli` 两个仓库按钮，默认选择前者。它读取最新一次 GitHub Actions 工作流运行和最近更新的一条打开的 PR，提供刷新、打开构建、打开 PR。没有 Token 输入或凭据存储；私有仓库不在这个包的范围内。

## 权限与启用

启用不会自动授权。Host 分别审核三项权限：`network` 允许向 Host 允许列表中的公开 HTTPS API 发出请求；`storage.local` 保存仓库选择和每个仓库最近已提示的构建结果；`links.open` 允许一次真实按钮动作打开受 Host 允许列表限制的公开 HTTPS 页面。包声明 Storage、Links、Activity、IslandNode、Actions 和 Scheduler capability；Network 按现有公开 API 通过权限控制。

网络未授权时，工具显示「网络未授权」，仓库切换和设置保存仍可使用。Storage 未授权时显示「未保存」，网络读取和打开已缓存的链接仍可使用；本次 VM 运行内仍能去重，重新启用后的结果去重无法持久化。打开权限被拒绝、撤销或系统打开失败时显示固定提示。日志与设置都不包含 API 响应、Token 或凭据。

## 请求、状态与刷新

每轮先后发送两个 GET，请求不会并发：

1. `https://api.github.com/repos/{owner}/{repo}/actions/runs?per_page=1&page=1&exclude_pull_requests=true`
2. `https://api.github.com/repos/{owner}/{repo}/pulls?state=open&sort=updated&direction=desc&per_page=1`

请求头为 `Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2026-03-10`、`User-Agent: DynamicIsland-GitHub-Plugin`，超时 10 秒。没有 Authorization、Cookie 或自动分页。API 文档于 2026-10-16 核对：[工作流运行](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository)、[拉取请求](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests)、[API 版本](https://docs.github.com/en/rest/about-the-rest-api/api-versions)、[速率限制](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)。

成功后通过公开 `scheduler.requestRefresh(300000)` 请求下一轮。一个 VM 只保留一个 Host 调度请求，没有 JavaScript 定时器。默认每小时约 24 个 API 请求；GitHub 匿名 REST 配额为每个源 IP 每小时 60 次，同一 IP 的其他程序共享配额，手动刷新也消耗配额。Host 仍可按后台、低电量和睡眠规则延后调度，不补发错过的周期。

同时点击刷新会合并到正在进行的同一轮；仓库切换让旧响应失效，当前请求结束后只读取最新选择。离线、超时、API 错误和响应解析失败按 5、10、20、40、60 分钟退避，上限为 60 分钟。403 且 `X-RateLimit-Remaining: 0`、403 带 `Retry-After` 或 429 使用 `Retry-After` 和 `X-RateLimit-Reset`，至少等待 5 分钟；成功响应剩余额度为 0 时也停止后续请求并退避。服务端要求超过一小时等待时，分段请求 Host Scheduler 并保留剩余时间，不提前请求。手动刷新与仓库切换均不能绕过退避。若错误发生时已有调度请求，先等待旧请求，再保留完整退避时间，因此实际等待可以更长。

SDK 的 `response.json()` 保留 64 KiB 响应、4096 个 JSON 节点和现有深度限制。插件只读取每个列表的第一条，保留运行 ID、attempt、状态、结论、短名称以及 PR 编号和短标题。异常格式、过大响应或过多节点会显示「数据超出限制」，不提高 Host 配额。标题按 UTF-8 字节截断并清除控制字符。没有记录时明确显示「暂无构建」或「暂无打开的 PR」。

## Activity 与 Open

工具 Activity 的本地 ID 为 `dashboard`，使用 persistent / tool / automatic 策略并隐藏 compact。展开树固定五行，适配 Host 140 pt 内容区：仓库和保存提示、CI 状态、PR、两个仓库按钮、刷新与两个 Open 按钮。

构建 Activity 使用 `build.checkout.<runID>.<attempt>` 或 `build.cli.<runID>.<attempt>`。排队时发布 progress Activity，进入运行时更新同一 Activity；没有编造百分比或把 API 状态当作进度数值。首次观察到该运行完成时结束 progress 实例，再用同一本地 ID 发布 transient 结果。重复刷新同一完成结果不会再次通知；Storage 保存每个仓库最近的结果 key，重启后继续去重。工具页仍显示最新状态。切换仓库、出现新运行或构建列表变空会结束旧构建 Activity。

构建和结果都明确提供 expanded 布局。compact 为「图标 / spacer / 最多两个汉字」两翼，长仓库名、运行名和 PR 标题只出现在展开布局。

Open 使用 API 中与所选仓库、运行 ID 或 PR 编号完全匹配的 `https://github.com/...` 页面。API 提供不匹配、带凭据、不同 Host 或畸形 URL 时不缓存该链接。链接缓存只在对应布局成功提交后更新，构建 Activity 的链接绑定其本地 ID；新响应尚未呈现时不能打开新目标。`open.build` 与 `open.pr` 在真实按钮回调中立即调用 `island.links.open({url, activation: event.activation})`；它不等待网络或 Storage 链。Host 要求当前活动实例、已提交按钮、五秒内的一次性动作凭证和独立授权，默认只允许 `github.com`，插件不能自动打开页面或重用动作凭证。

## 验证范围

`DynamicIslandTests/GitHubPluginTests.swift` 从本目录校验真实包，在真实 JavaScriptCore、Bridge、ActivityManager 和 ActionRouter 上运行；只替换 URLSession 传输、系统链接 opener 与 Host 调度时钟。覆盖构建状态与结果去重、PR/Open、仓库设置、逐项权限拒绝、错误与退避以及有界 JSON。

2026-10-19 的单机普通 Release 隔离实测已完成真实 `.dip` 导入、三项独立授权、公开 CI / PR、仓库切换 / 刷新与系统浏览器打开。该实机记录与自动测试分别保留，没有扩展为其他设备、私有仓库或匿名配额保证。

公开包附完整 MIT LICENSE 和本说明。README / LICENSE 改动会改变整包身份；安装后保持停用，旧包授权不能自动沿用，仍须分别批准三项权限。运行需要包含插件系统的 Host 0.6.0，公开的 App 0.5.0 不具备该 Runtime。
