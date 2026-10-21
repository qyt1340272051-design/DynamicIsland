# Phase 7 — T36 GitHub 官方插件

日期：2026-10-17，更新于 2026-10-19。状态 `verified`。早期按 [PROGRESS 的人工依赖例外](PROGRESS.md)先推进自动开发；本日 T35 前置验收与 T36 实机 / 系统 Open 均已完成，见[Phase 7 统一检查](phase-7-acceptance.md)。历史延期和自动结果保留原时间范围。

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
- 需要物理指针的实际工具页 / 系统浏览器交互早期按用户安排延期，本日已完成[实际验收](evidence/t36-manual-20261019/result.json)；安装、授权、采样和文件归档均由助手完成。

T35 与 T36 的任务内门槛现已关闭；后续兼容、SDK 和 Registry 仍按各自计划及验收范围追踪。


## 2026-10-19 实机与系统 Open 验收通过

[本轮结果](evidence/t36-manual-20261019/result.json)：在独立普通 Release / PID 82621 中实际导入 GitHub 0.1.0，确认安装后停用且 network、storage.local、links.open 均待授权，再逐项批准后启用。工具五行、仓库选择与最后一行按钮均经实际像素核对；真实公开 API 先后显示 actions/checkout 和 cli/cli 的 CI / PR，仓库切换与手动刷新正常，没有使用网络 fixture 或 Token。

当时实际运行 key 为 `39115930522.1` 与 `39184461294.1`，PR 为 #1687 与 #14727。通过当前工具按钮实际打开 Safari 的 `https://github.com/cli/cli/actions/runs/39184461294` 和 `https://github.com/cli/cli/pull/14727`。撤销 links.open 后显示固定失败提示；重新批准后用新按钮点击，浏览器由原构建地址切到当前 PR 地址，证明新的真实动作到达系统 Open，不把已有页面或旧 activation 当作本次成功。原始观察与图像索引见[UI 摘录](evidence/t36-manual-20261019/ui-excerpts.json)和[截图](evidence/t36-manual-20261019/screenshots.json)。

[正常退出归档](evidence/t36-manual-20261019/cleanup.json)确认 Command-Q 后 PID 82621 消失、Staging 为空，包、启用状态、三项批准和 cli/cli 仓库选择 / 已提示结果保留。未发布消息或修改远端数据，生产 App 未修改。T35 前置已于本日满足，结合既有 VM / Broker / Links 测试，T36 标为 verified。

[预检与 Host 身份](evidence/t36-manual-20261019/preflight.json)说明本轮使用原 T36 历史独立普通 Release，产品版本仍显示 0.5.0 / build 2，其插件 Host 兼容契约为 0.6.0；实际包与源 hash 对应原 GitHub 0.1.0。该 Host 不是 checkpoint 253c588 的新编译，不能把本轮实际界面推广为当前 HEAD 的全量二进制验收。当前后续代码由[完整回归](evidence/t40-registry-ui-20261018/result.json)及[六项原生输入补验](evidence/native-input-20261019/result.json)分别支撑。

实际 UI 验收记录当时公开 API 返回的状态；排队 / 运行 / 结果转换、去重、离线、API 错误、两小时限流分段及旧票据拒绝等边界仍属于下述真实 VM、测试传输 / opener / 时钟的集成覆盖，没有宣称本轮真实公网经历全部错误与构建状态。系统接受 Open 与浏览器显示目标已实测，不保证网页后续跳转、登录或加载结果。

## 历史自动验证结果（2026-10-17）

[证据索引](evidence/t36-github-20261017/result.json)：完整 CI **926 total / 919 passed / 7 skipped / 0 failures**，普通 Release build passed。5 项真实 AppKit 输入因会话锁定跳过，另两项是截图矩阵和默认 opt-in live。后者已单独执行：**1 passed / 0 skipped / 0 failures**。

真实网络使用默认 NetworkBroker / URLSession 和官方 JS 包，不用 URLProtocol、不提供 Token。2026-10-16T17:36:36Z 已读到 actions/checkout 的 run 38419621917（completed / success）和 PR #1687，见[公共数据投影](evidence/t36-github-20261017/live-public-api.json)。这是实际网络测试夹具证据，不能替代普通 Release 工具页或真实系统浏览器验收。

集成修复了 permissionDenied 提示、SDK 无原型数组的持久化恢复，测试空值和权限集合计数也按真实合约修正。慢存储结果去重、已呈现链接绑定、两小时服务端限流分段及动作 / 权限 / 资源撤销边界均通过。未修改现有 Network / JSON / 权限存储资源限额。

当时独立普通 Release App 与 github-0.1.0.dip 已准备并校验签名，尚未启动或导入，不注册 .dip / URL 默认处理程序。实际界面与系统 Open 按[人工清单 M02](MANUAL_ACCEPTANCE.md)延期，T35 / T36 当时保持 in progress。该历史缺口现已由[2026-10-19 实机验收](evidence/t36-manual-20261019/result.json)关闭，当前任务和阶段结论见页面开头及[Phase 7 统一检查](phase-7-acceptance.md)。
