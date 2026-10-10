# Phase 6 — T29 NetworkBroker

日期：2026-10-10。依赖 T28 已验收；最终验证通过。

## API 与 Host 策略

```javascript
const response = await island.network.fetch('https://api.github.com/repos/octocat/Hello-World', {
    headers: {Accept: 'application/vnd.github+json'}, timeoutMs: 10000
});
if (response.ok) {
    const repository = await response.json();
    await island.log(repository.full_name);
}
```

冻结 namespace `apiVersion=1.0.0`、supported=true。fetch 返回冻结 null-prototype 响应（status / ok / headers / text() / json()）；HTTP 4xx / 5xx 返回响应，策略、传输、超额与撤销拒绝 Promise。json 返回有界冻结数据树，最多 4096 节点、20 层，字符串最多 64 KiB；不带原生 URLSession 或对象引用。

V1 只允许 GET / HEAD、HTTPS 默认端口或 443；URL 最多 2048 UTF-8 bytes。Host 默认 exact allowlist `api.github.com`，可由 Host 配置，JS 无扩大范围的入口。拒绝凭据、IP 字面量（含旧数字形式）、localhost / .local / 单标签域名和未批准 host。所有 DNS 答案必须为公网地址，包括 IPv4-mapped IPv6 检查。

headers 最多 16 个、名称 64 bytes、单值 1024、名称和值合计 4096；大小写重复、控制字符、Host / Cookie / Connection / proxy / 转发等头拒绝。Authorization 可由已批准插件明确发送，但本实现不记录 URL、query、headers、body、底层 NSError 或 Token。响应移除 cookie / 认证 / Location 等敏感头，保留头总量最多 4 KiB。

默认超时 10 秒，允许整数 timeoutMs 100...30000；绝对 deadline 覆盖 DNS / 连接 / 下载。每插件最多 2、Host 最多 8，无额外等待队列。响应 body 最多 64 KiB，先检查 Content-Length，再逐块累计；坏 UTF-8、非 HTTP 和过大响应均固定错误拒绝。无法取消的同步 DNS 仍保留 reservation 到 resolver 实际返回，避免连续短超时累积无限 DNS 工作；Promise 按 deadline 结算。

每请求使用 ephemeral URLSession 与独立串行 delegate queue，明确关闭内存 / 磁盘 cache、cookies、credential storage 和代理配置，TLS 使用系统验证，全部重定向拒绝。[Apple ephemeral 文档](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral) 说明临时配置仍可能使用内存状态，因此本实现另行关闭上述容器；[data delegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate/urlsession(_:datatask:didreceive:)) 的累计限制在每个新增 data chunk 执行，[redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)) 拒绝新请求。

## 授权、停止与异步顺序

每次调用 require `.network` lease，绑定 pluginID 和 permission。启动、接收 data 和最终交付再次检查；权限 generation 更新在解锁后通知取消，重新批准不能恢复旧请求。每个执行会话拥有 NetworkAdmission，生命周期结束和 Transport 直接 teardown 先关闭交付资格，再幂等取消请求。晚 DNS / delegate callback 不重复结算或释放配额。

Transport FIFO 只等待网络参数验证与准入，不等待网络 completion；慢 fetch 不挡同 VM 的 storage / Activity / action。回复按 request ID 回到原 VM。Bridge 在 MainActor 交付前再检查当前执行、网络 admission 和 lease；VM teardown 沿用 worker 撤销。

JS 请求普通 snapshot 保留 T23 4 KiB 单字符串限制；仅 network 响应使用 64 KiB body / 512 KiB wire。receiveResponse 捕获 parse / shape / copy 错误并明确 reject，不在删 resolver 后留下悬空 Promise。生产增加 Sandbox `network.client`；这只是 Host 出站能力，插件仍必须通过每次权限和政策检查。

DNS preflight 未绑定实际连接地址；URLSession 可重新解析，系统网络环境也可能影响路由。本 V1 不声称完整 DNS rebinding 隔离，依赖 narrow Host allowlist 和系统 TLS。生产无 T33 批准 UI，network 默认 requested，不自动授权。

## 验证与后续

[`PluginNetworkBrokerTests`](../../DynamicIslandTests/PluginNetworkBrokerTests.swift) 12 项覆盖 DTO / URL / header / DNS、大小与无效响应、deadline / 并发、cookie / cache / redirect、权限 / 生命周期取消与晚 callback，以及两个真实 JS fixture（6 KiB GitHub JSON、冻结 text / json、storage 旧限制和慢 fetch 不挡 Core 操作）。传输用 URLProtocol 假响应；未声称真实公网 GitHub / 代理环境验收。

Bootstrap 的临时 Node 语法与边界 smoke 通过（`/tmp/dynamic-island-t29-work/bootstrap-smoke.cjs`）；生产 Debug build 通过。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 517 total、515 passed、2 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t29-final-ci/TestResults.xcresult`、对应 `.log`。 |
| Release 定向 | Network 12、Permission 17、Storage 17、Bridge 23、Node 20、Activity 18、Action 18、Runtime 29、生产 factory 1；155 total、154 passed、1 skipped、0 failures。 | `/tmp/dynamic-island-t29-release-tests/TestResults.xcresult`、对应 `.log`。 |
| 普通 Release 签名 | strict / deep 核验通过；adhoc + runtime；Sandbox / allow-jit / network.client 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t29-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t29-release-entitlements.plist`。 |

环境同 T28：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。CI skip 为原截图生成和锁屏期间真实鼠标控件单项，Release skip 仅为后者；没有网络测试 skip。Release 的测试注入 / library-validation 例外只用于临时测试 Host，普通 App 无该例外。

T29 按计划完成标准 verified：实际 JavaScript 经 Host Broker 获取 GitHub 格式 API 数据，插件不接触 URLSession；传输额度、权限、停止与 Core 请求交错均有实测 fixture。后续 T30 File/Clipboard Broker。尚无批准 UI、正式公网 GitHub / 系统代理实测或 0.6.0 发布结论。
