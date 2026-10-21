# 公共 Links API（T36）

日期：2026-10-17。作为 `1.0.0` 的可选增量接口，所有插件均可发现冻结的 `island.links` namespace；调用仍由 Host 检查声明、授权和真实动作。

```javascript
island.actions.on('open', event => {
    return island.links.open({
        url: 'https://github.com/actions/checkout',
        activation: event.activation
    });
});
```

`open` 必须同时声明 `links.open` capability、`actions.handle` capability 和独立 `links.open` permission。返回 `Promise<null>`，只表示系统接受了打开请求，不表示网页已加载。安装和启用不授予权限；代码 / Manifest 改变后的旧授权失效。`network` 仅授权受限 HTTPS 读取，不隐含网页打开授权；打开一个已知页面也不需要额外授予 `network`。

## 参数与目的地址

精确对象 `{url, activation}`，不接受多余字段、访问器、原生对象或类型转换。SDK 在安全数据快照上校验形状和基本 URL，Host 独立解析并应用最终策略。

- 原始 URL 最多 2048 UTF-8 字节；绝对 HTTPS，默认端口或 443，无用户名 / 密码。
- 拒绝原始及一次百分号解码后的空白、控制字符、反斜杠和损坏转义；拒绝 IP、非 DNS host、尾点和编码 host。
- 当前生产 Host 精确允许 `github.com`。子域、后缀伪装和 `api.github.com` 都不属于链接允许列表；后者由独立 NetworkBroker 负责。
- 允许的路径、query、fragment 仍交给系统浏览器。Host 不控制浏览器接管后的重定向、登录或页面行为；权限说明明确这一范围。
- Host 可配置 Broker 的域名策略，JS 无法改变该策略。

## 动作凭证

沿用 Host ActionRouter 签发的唯一 5 秒 activation 槽，绑定 execution、Activity source / id / instance token、动作 registration。只允许当前已呈现的按钮动作（`.none`）；启动、刷新、网络完成和计时完成回调没有可自动使用的凭证。

Open 与 countdown 互斥消费同一个槽。同一点击不能各执行一次；错误的随机 token 不消耗真正票据，进入凭证检查后的匹配尝试先消耗。新动作、取消注册、同动作重新注册、旧实例替换和执行撤销使旧票据失效。消费后的 Open 失败不恢复票据，需要新的用户点击。

最终路径在 MainActor 同步执行：验证请求 / capability → 消耗动作 → 获取当前包的权限 lease → Broker 再验实例、注册、期限和 context → resource gate → 精确 links.open lease → 系统 opener。消费到副作用之间没有 `await`。权限 / 资源锁内的 opener 是不重入的短叶操作；生产调用 `NSWorkspace.shared.open`。

同一生产 Broker 的所有插件共享单调时钟的 1 秒冷却；失败的系统尝试仍消耗冷却。错误使用固定 `activationRequired`、`permissionRequired` / `permissionNotGranted` / `permissionDenied` / `permissionRevoked`、`linkPolicyDenied`、`rateLimited`、`linkOpenFailed` 等代码，不返回 URL、系统路径或底层错误。

## 验证入口

- [Broker 测试](../../DynamicIslandTests/PluginLinkBrokerTests.swift)：URL、域名、冷却、最终撤销与系统失败。
- [真实 VM / Router 测试](../../DynamicIslandTests/PluginLinkBridgeTests.swift)：SDK 快照、参数和 Host 独立校验、旧实例、权限变化、重放。
- [倒计时兼容与跨 API 消费](../../DynamicIslandTests/PluginCountdownActivationTests.swift)。

自动化使用注入 opener，不能冒充真实浏览器已打开；实际 UI 动作若需要物理悬停，登记到[人工清单](MANUAL_ACCEPTANCE.md)。
