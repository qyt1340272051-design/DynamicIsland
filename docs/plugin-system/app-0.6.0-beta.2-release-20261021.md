# App 0.6.0 beta.2 发布与公开构件核验

日期：2026-10-21。按用户「先完成可独立执行的任务，人工项先跳过」安排，主 App 已作为 **未公证开发预览**公开；原计划仍为 **39 verified / 1 in progress**。

## 发布身份

- [公开 Release](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/v0.6.0-beta.2)：非草稿、prerelease，App `0.6.0` / build `4`。
- [PR #5](https://github.com/qyt1340272051-design/DynamicIsland/pull/5)通过必需检查后正常 squash 合入 main；源码提交 `eacec4d1d385bc90946e8d0df1731dbd22c23428`。
- annotated tag `v0.6.0-beta.2` 的 tag object 为 `4a6de2495c95b828817b28c31b578bc14e08d2ff`，指向上述已检查的 main。已公开 SDK 1.0.0 源码树仍为 `79bc3ace4e378dddf29eb332be171b9379daffee`。
- `beta.1` 源码标签保持原 object / commit；其标签验证失败，未生成 DMG 或 Release。失败记录、后续修复及成功证据分别保留。

## 自动检查

| 门槛 | 结果 | 证据 |
| --- | --- | --- |
| PR #5 最终源码 | 1092 total / 1087 passed / 5 skipped / 0 failures；Release build passed | [CI 39541138606](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39541138606) |
| 合入 main | 同上 | [CI 39541741218](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39541741218) |
| beta.2 标签 | 同上；后续打包与发布 job 均成功 | [Release 39542326315](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39542326315) |

五项 skip 是默认关闭、需显式开启的真实 GitHub、真实 Registry、截图矩阵选测，以及 runner 开启 Reduce Motion 时不适用的两项动画退出测试。本机完整检查为 1089 passed / 3 skipped / 0 failures，相关原生输入 30 passed，稳定性脚本 49 passed。最后六行存储测试观察修正后，另有本机存储回归 6 passed；随后最终源码通过表中三个完整远端门槛。各次结果独立记录，不混作一次本机运行。

本轮修正测试窗口焦点、实际鼠标事件分派，以及 Storage actor 提交后等待 Promise 回调发布清除提示的观察边界。保留真实控件、JS 回调、精确持久值与业务断言，未新增 skip，未改生产插件或冻结 SDK。证据见[发布结果](../releases/evidence/app-0.6.0-beta.2-20261021/publication.json)、[逐轮 CI 汇总](../releases/evidence/app-0.6.0-beta.2-20261021/ci-verification.json)及[准备与失败记录](../releases/evidence/app-0.6.0-beta.2-20261021/preparation.json)。

本地 `gh run watch` 在标签流水线期间遇到 API 网络错误；独立重新查询确认原 run 已成功。只恢复状态查询及下载，没有重跑构建、覆盖标签或重传资产，见[监听恢复记录](../releases/evidence/app-0.6.0-beta.2-20261021/listener-recovery.json)。

## 三个公开资产

| 文件 | 字节数 |
| --- | ---: |
| `Dynamic-Island-0.6.0-beta.2-local.dmg` | 5,554,615 |
| `Dynamic-Island-0.6.0-beta.2-local.dmg.sha256` | 104 |
| `Dynamic-Island-0.6.0-beta.2-local.json` | 321 |

三个文件均从公开下载 URL 匿名取得 HTTP 200；大小与 GitHub 资产一致。[下载记录](../releases/evidence/app-0.6.0-beta.2-20261021/anonymous-downloads.json)与[独立核验](../releases/evidence/app-0.6.0-beta.2-20261021/independent-artifact-result.json)分别保留。DMG 的实际 SHA-256 与 checksum、manifest、GitHub digest 一致：

```text
5168a80105a7e561154940d59fa8d3796443c22471d5ed45b1638bf2c194766b
```

独立脚本检查 DMG 完整性、只读挂载、Applications 链接、App 版本/build/Bundle ID、最低 macOS 26.0、实际 Mach-O 的 arm64 与 x86_64、strict/deep 签名、ad hoc 与 hardened runtime、sandbox/JIT/network client entitlement 及无 get-task-allow，全部通过。核验后正常卸载并删除临时挂载目录；没有启动 App。可复核的[核验脚本](../releases/evidence/app-0.6.0-beta.2-20261021/verify-public-artifact.py)随记录保存。

本机下载副本位于仓库的 `build/release/v0.6.0-beta.2/`，该目录由构建忽略规则管理，不提交二进制。

## 已关闭与继续保留的范围

- 真实目录 GUI 安装补验已完成：普通 Release `0.6.0/build3` 全新隔离副本通过默认公开目录下载两款官方包、预览、显式确认安装；均保持停用及所有权限 requested，磁盘包字节一致，Staging / Storage 为空并正常退出，见[GUI 结果](../releases/evidence/app-0.6.0-beta.1-20261021/gui-result.json)。此项与上述下载 DMG 的只读核验分别记录。
- T39 独立新作者仅按发布文档完成构建、安装与首次操作仍为 `in progress`。既有作者的协助复测与 AI 自动闭环不替代该门槛。
- [九项硬件 Beta 场景](../BETA_TESTING.md)及无 Xcode 的干净 Mac 首次安装仍待人工验证；双架构编译不等于 Intel 运行实测。
- 本包没有 Developer ID 签名或 Apple 公证，manifest 明确 `notarized=false`。首次运行按[发布说明](../releases/v0.6.0-beta.2.md)核对来源与摘要，再在系统隐私与安全设置中手动批准。
- 本次完成 App 开发预览发布，不关闭整体 Plugin 1.0 的剩余人工门槛。发布后的证据归档提交不修改已发布标签或资产。
