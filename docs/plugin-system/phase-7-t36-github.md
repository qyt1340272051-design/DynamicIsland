# Phase 7 — T36 GitHub 官方插件

日期：2026-10-17。状态 `in progress`。用户要求跳过需要本人操作的部分并集中登记；因此按 [PROGRESS 的人工依赖例外](PROGRESS.md)先推进自动开发，T35 的真实提示验收仍保留，未冒充 verified。

## 实施范围

采用计划允许的公开 API 示例路线，不申请、读取或保存 Token。固定公开仓库 `actions/checkout` 和 `cli/cli`，展示最新一次 CI 与最近更新的一条打开的 PR；设置使用现有 Storage，刷新使用集中 Scheduler。

计划步骤对应：

1. 仓库配置：工具页提供有限仓库按钮，保存选择与已提示结果；不新增文本输入节点或凭据存储。
2. CI / PR：串行读取两个公开 GET，每页一条，保留 Host 的 64 KiB / JSON 限额。默认 5 分钟周期、刷新合并；离线、API 错误与限流分别显示固定提示并退避。
3. Activity：稳定 run / attempt ID，排队与运行使用 progress 生命周期，完成发布一次 transient；不编造百分比。显示明确 compact 两翼和 expanded 内容。
4. Open：新增[通用 Links API](t36-links-api.md)，独立声明与批准、真实按钮的一次性凭证、Host HTTPS / 域名策略。GitHub 不拥有私有 Host 回调。

源码、行为与官方来源见[公开示例](examples/github/README.md)。上游请求只读公开资源，未修改 GitHub 仓库或发送消息。

## 验证范围

- 公共 Host Release 编译已通过，日志 `/tmp/dynamic-island-t36-release-20261017.log`。
- Host Links、真实 VM / Router、倒计时兼容与 GitHub 示例测试已完成集成，完整结果见下方自动验证记录。
- 真实公共网络验收使用显式 opt-in 测试，默认 CI 不访问互联网；该测试已单独执行并确认通过。
- 需要物理指针的实际工具页 / 系统浏览器交互按用户安排延期，汇总到[人工清单](MANUAL_ACCEPTANCE.md)。安装、授权、采样和文件归档等工具可完成的部分不转交用户。

本页不关闭 T35 或整个 Phase 7；后续兼容、SDK 和 Registry 仍按原计划追踪。


## 自动验证结果（2026-10-17）

[证据索引](evidence/t36-github-20261017/result.json)：完整 CI **926 total / 919 passed / 7 skipped / 0 failures**，普通 Release build passed。5 项真实 AppKit 输入因会话锁定跳过，另两项是截图矩阵和默认 opt-in live。后者已单独执行：**1 passed / 0 skipped / 0 failures**。

真实网络使用默认 NetworkBroker / URLSession 和官方 JS 包，不用 URLProtocol、不提供 Token。2026-10-16T17:36:36Z 已读到 actions/checkout 的 run 38419621917（completed / success）和 PR #1687，见[公共数据投影](evidence/t36-github-20261017/live-public-api.json)。这是实际网络测试夹具证据，不能替代普通 Release 工具页或真实系统浏览器验收。

集成修复了 permissionDenied 提示、SDK 无原型数组的持久化恢复，测试空值和权限集合计数也按真实合约修正。慢存储结果去重、已呈现链接绑定、两小时服务端限流分段及动作 / 权限 / 资源撤销边界均通过。未修改现有 Network / JSON / 权限存储资源限额。

独立普通 Release App 与 github-0.1.0.dip 已准备并校验签名，尚未启动或导入，不注册 .dip / URL 默认处理程序。实际界面与系统 Open 按[人工清单 M02](MANUAL_ACCEPTANCE.md)延期；T35 / T36 均保持 in progress，未关闭整个 Phase 7。
