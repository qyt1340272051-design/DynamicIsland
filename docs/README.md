# 插件开发手册（SDK 1.0.0 发布候选）

面向熟悉 JavaScript 的作者，适用于 App 0.6.0 的 Native SDK 1.0.0 发布候选，尚未公开发布。先从 [Quick Start](quick-start.md) 制作一个无权限的计数工具，再按需要增加功能。运行插件只需支持本协议的 Dynamic Island；编写和打包需要 Python 3.9+，类型检查才需要 Node.js / npm。

| 主题 | 解决的问题 |
| --- | --- |
| [Quick Start](quick-start.md) | 从目录到 `.dip`，安装、启用、点击第一个按钮。 |
| [Manifest](manifest.md) | 标识、入口、版本、能力声明。 |
| [Activity](activity.md) | 发布、更新、结束；状态和工具的区别。 |
| [UI Components](ui-components.md) | 八类节点、布局限制和刘海两翼。 |
| [Actions](actions.md) | 注册按钮回调、实例边界、真实动作凭证。 |
| [Storage](storage.md) | 私有 JSON 存储、配额和授权失败。 |
| [Network](network.md) | HTTPS 请求、响应校验和退避。 |
| [Permissions](permissions.md) | 声明、逐项批准、撤销和升级。 |
| [Settings](settings.md) | 用工具按钮和 Storage 实现业务设置。 |
| [Lifecycle](lifecycle.md) | 同步 hooks、异步初始化、停用和重启。 |
| [Debugging](debugging.md) | 常见错误、诊断和最小复现。 |
| [Packaging](packaging.md) | 离线校验、打包、导入与替换。 |
| [Publishing](publishing.md) | 分发准备、版本和当前发布边界。 |

本手册的完整代码块由 CI 对照同目录示例源文件；JavaScript 参加 SDK 严格类型检查，JSON 参加离线校验。Quick Start 命令在临时目录实际打包；正式 Host 测试验证 Hello 的真实 VM / 动作 / 撤销闭环和本手册的资源示例。网络测试使用固定响应，不消耗外部服务额度。详见[验证范围](verification.md)。

SDK 尚未稳定发布。两款官方插件的实机验收已于 2026-10-19 完成；首次作者体验和稳定版本复核仍在验证。“约十分钟”是 Quick Start 的设计目标，尚非通过结论。[版本策略](../VERSIONING.md)说明协议标识和 SDK 发布状态的区别。
