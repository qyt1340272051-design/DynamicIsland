# T38：API 复核与独立 SDK 分发准备

日期：2026-10-19。T35 / T36 的真实官方插件前置已满足，分别见[番茄钟结果](evidence/t35-manual-20261019/result.json)与[GitHub 结果](evidence/t36-manual-20261019/result.json)。本轮采用 **SDK 1.0.0 发布候选**，完成本地分发收尾和 API / 版本复核；独立 AI 作者的原始包也已[通过正式 Host 自动闭环](t38-independent-host-20261019.md)。尚未公开发布，真人作者体验与实际界面分别保留范围。

## 已验证接口与公开范围

[类型](../../SDK/types/island.d.ts)继续限定为两款官方包使用的 Native API，不增加新的 namespace 或权限。来源为仓库内当前官方 JS、其真实 VM / Bridge 集成测试及上述单台设备验收；静态使用情况与运行覆盖分别看待。

| SDK 接口 | 官方使用来源 | 复核结果 |
| --- | --- | --- |
| `log` | Pomodoro、GitHub 固定分类日志 | Promise 返回值；保留诊断不含消息正文，拒绝值为数据对象。 |
| `activity.publish/update/end` | 两款官方包 | publish / update 返回 `{id: string}` receipt；局部字段补丁、整体替换 presentation、生命周期约束及 Host 裁决保持原合约。 |
| `actions.on` | 两款官方包 | 先注册后发布，当前呈现实例绑定；旧实例不能操作新执行。 |
| `storage.get/set` | 两款官方包 | 显式 capability / 权限；入站 JSON 冻结且无原型，SDK 不承诺数组原型方法。 |
| `scheduler.requestRefresh` | Pomodoro 一次对账、GitHub 有界刷新 | 一次性 Host 调度，受能耗策略、撤销与合并约束；不提供 JS Timer。 |
| `countdown.get/start/pause/resume/stop/onComplete` | Pomodoro | generation 与 activation 为不透明标识；start / resume 需要新的真实动作凭证。 |
| `network.fetch` | GitHub | HTTPS GET / HEAD，目标、请求、响应受 Host 边界约束；Schema 与 TypeScript 不替代运行准入。 |
| `links.open` | GitHub | 显式批准和单次 activation；当前目标政策限定 GitHub，不能扩展为任意系统 URL 打开。 |

同步 `onStart` / `onStop`、Promise 动作回调、八类有限节点、闭集 Manifest、权限不随启用自动批准等边界未改变。类型正例是独立调用夹具，不能表述为对未加类型的官方 JS 做了完整静态检查。正式 Host 契约继续由 `PluginSDKContractTests` 和 `PluginDocumentationTests` 承担。

## 分发缺口及修正

审阅发现原 SDK 根 README 的官方示例和进度表链接指向仓库外，Hello README 命令也假定作者拥有仓库根目录。原脱仓库测试只复制工具所需子集，没有检查整个根入口和实际分发包。

本轮修正：

- 根 README 的可点击链接均留在独立 SDK 内；仓库专属资料以位置说明保留。
- Hello README 的校验和打包命令改为从 SDK 根目录执行。JS / Manifest 与 Quick Start 脚本不变；说明文件改变后重新生成 `SDK/tests/fixtures/hello-world.dip`。历史人工包的旧摘要保留在原记录，不反写成新包验收。
- 增加完整 [MIT License](../../SDK/LICENSE)、[分发说明](../../SDK/DISTRIBUTION.md)和 [归档工具](../../SDK/tools/package_sdk.py)。不将 `node_modules`、缓存、隐藏文件、主 App、安装数据或工作区证据打入 SDK ZIP。
- ZIP 带逐文件 SHA-256 / 大小清单及 SDK / wire / Manifest / minimumHostVersion 元数据；固定排序与时间，相同 Python / zlib 工具链下生成相同字节。摘要不提供作者身份认证。
- 新的实际归档测试从解压后的完整 SDK 检查全部 Markdown 链接，通过交互式 zsh 执行首段入口、生成真实 `.dip`、比较 fixture，并运行节点校验；另验证已存在输出不覆盖、缓存排除和源链接拒绝。

## 版本与发布边界

SDK 首次稳定发布候选已采用 **`1.0.0`**。此值独立于 App `0.6.0`、wire API `1.0.0` 与 Manifest schema `1`；相同数字不表示它们共享发布周期。当前 `package.json` / lockfile / 类型头 / CLI / Schema 来源与本地构件已一致采用 1.0.0 候选状态，`private` 保持 true，不执行 npm 发布。历史 `0.1.0-experimental` 记录保持原状。

本候选的有限接口及行为已冻结在 [CHANGELOG](../../SDK/CHANGELOG.md)，版本策略分别规定 SDK major / minor / patch 与 Host wire 协议迁移。最终公开发布前仍需复核独立作者结果、正式 Host 契约和同一源码归档。原生接口扩展和 SuperIsland 兼容不能隐式改变授权。

receipt 文案修正阶段的结果见[历史结构化证据](evidence/t38-distribution-20261019/result.json)，最新候选见[最终归档复核](evidence/t38-final-audit-20261019/result.json)。SDK 分发子步骤没有运行或修改生产 App，也没有远端推送、Git tag、Release、SDK 上传或 Registry 发布。修正版手册的真人独立作者体验及实际用时仍在 T39 中单独追踪。

## receipt 文案修正阶段的本地验证

- 仓库 SDK Python **39 passed / 0 skipped / 0 failures**，类型正例及 **47 项预期错误**通过。当前手册仍为 15 页 / 9 个源码对照块 / 33 条本地链接。
- 初始候选 ZIP 解压后的 SDK 曾在脱仓库位置运行全部 Python 测试：**37 passed / 2 skipped / 0 failures**。两项明确跳过为完整仓库官方示例和旧 Scripts wrapper；它们本就不包含在独立 SDK 中。此结果保留在 `initialCandidate`，不写成重打候选上的全套运行。
- 该阶段归档含 **53 个源文件**和生成的摘要清单，84,000 bytes。每个源文件大小 / SHA-256 与当时工作区逐字核对；两次独立生成的 ZIP 完整字节相同。该阶段 39 项 SDK gate 已实际覆盖解压后的 Markdown 入口、交互式 zsh Quick Start 和真实 `.dip` 字节。
- receipt 阶段 SHA-256 为 `47729aa038528f800b8da6fd94666a0c0bcf6da6cc530086d5d4c86f9443663c`，现备份于 `artifacts/sdk/history/receipt-clarified-20261019/`。它是本地历史候选，未公开发布；最新 canonical 摘要见下方。
- 修正后的独立走查副本已解压到 `/tmp/dynamic-island-sdk-1.0.0-walkthrough-receipt-20261019/DynamicIslandSDK`；从其 README / Quick Start 开始即可，不依赖完整仓库。初始走查目录保持原样。

以上是本子步骤的 SDK 工具 / 归档验证。后续主任务完整 CI 为 1070 passed / 2 skipped / 0 failures，见[完整回归](evidence/final-regression-20261019/result.json)；再新增的独立作者原包用例与既有 SDK / 文档契约为 8 passed / 0 skipped / 0 failures，见[单独 Host 记录](t38-independent-host-20261019.md)。后者不混入前一份完整 CI 统计。

## 独立 AI 作者资料走查与 receipt 表述修正

主任务安排的新上下文 AI 作者仅凭初始 SDK，未读 Swift，在 **137.7 秒**内生成原样 Hello 与原创双按钮插件，并完成离线校验、打包和 ZIP 核对。原始记录位于 `/tmp/dynamic-island-independent-author-20261019/review.md`，它不包含 Host 安装、启用或 UI 点击，不是人类首次使用验收，也不能证明十分钟安装目标通过。

该作者指出 README 将 publish / update 的返回值简写为本地 Activity ID，容易理解为字符串。现已明确为 Promise resolve 的 **`{id: string}` receipt**，其中 id 为本地 ID；API 和 fixture 没有改变。最终 SDK gate 重跑通过，重打归档只改变 README 与生成的摘要清单。

AI 实际读取的是初始候选 SHA-256 `b92a911594b8e7dafa723dc70ba6e851cc35e21ec0e730ef2857a8cf5ccf0808`，不将修正后的新字节归于该次走查。旧 ZIP 及原结果 / 清单 / 日志备份于 `/tmp/dynamic-island-t38-distribution-20261019/initial-candidate/`；结构化 `initialCandidate` 保留旧摘要和观察范围。

该原始双按钮包随后实际经过 Extractor、Validator、JavaScriptCore、Bridge、ActivityManager 和 ActionRouter，验证待选择 → 专注中 → 休息中、同实例更新、停用旧动作拒绝与重新启用重置，见[正式 Host 自动闭环](t38-independent-host-20261019.md)。它也已在普通 Release 隔离副本安装后停用、明确启用，见[实机装载记录](evidence/final-app-install-20261019/result.json)；用户本轮跳过人工操作，因此未检查真实工具按钮或刘海像素。

## 提交前归档审阅与最新候选

审阅发现 Python `os.walk` 默认会忽略目录扫描错误，某个不可读取的子目录可能静默遗漏。归档工具现将扫描错误直接抛出；新增模拟 `scandir PermissionError` 用例，断言失败时不产生目标 ZIP。

[最新 SDK gate](evidence/t38-final-audit-20261019/sdk-check.txt)为 **40 passed / 0 skipped / 0 failures**，类型正例及 **47 项预期错误**通过。正式 Host 与生产 Swift 未改变，保留上述完整回归和单独 8 项 Host 证据的各自范围。

最新 `artifacts/sdk/dynamic-island-sdk-1.0.0.zip` 为 **84,278 bytes**、53 个源文件，SHA-256 `dd9ba3e40c856343271e8088643276fc329526191213fa1bbee1973eab299433`。两次独立打包字节一致，所有清单摘要与当前源文件一致；只比 receipt 候选改变归档工具、分发测试和生成清单。旧候选已保留，AI 实际阅读与此前执行事实不反写。详见[最终证据](evidence/t38-final-audit-20261019/README.md)。

下次独立 SDK 走查使用 `/tmp/dynamic-island-sdk-final-audit-20261019/walkthrough/DynamicIslandSDK`。该候选仍未公开发布；人工 M03–M05 由用户明确延期。
