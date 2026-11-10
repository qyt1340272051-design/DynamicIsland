# U17 — 音乐插件市场与主页默认页面、循环切换

日期：2026-11-04。开发 Host：0.6.1/build22。

## 插件市场

QQ 音乐与 Spotify 0.1.0 已发布为独立 [plugins-music-0.1.0 预发布](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/plugins-music-0.1.0)。两份安装包、SHA256SUMS 和来源摘要清单已上传，匿名下载与冻结归档逐字匹配。最低要求为含对应 helper pin 的 Host 0.6.1/build21 或更新版本；本轮未发布主程序，也未替换用户当前运行的 App。

源码标签提交：`34ebb64c706600821390584a92c6c6ab84cca74e`。只冻结两款插件的各五文件源码，没有提交开发 Host 工作区。发布后仓库 README 将一处旧中文项目名改为当前名称，以满足既有发布校验；已公开的包、标签和摘要保持不变，归档源码仍以标签快照为准。

| 插件 | 归档 SHA-256 |
| --- | --- |
| QQ 音乐 0.1.0 | `4d5abeea4ec84a32447742130fdb7b596b2e1b47492da45da7c10d3a302b4aa4` |
| Spotify 0.1.0 | `23788519eb3d7a203e18e90c8a4ce024cc355206f92489ab138912f5bc5c36d3` |

目录更新 [PR #14](https://github.com/qyt1340272051-design/DynamicIsland/pull/14) 包含新源码、两个固定资产条目、目录说明与离线固定资产测试。保留现有番茄钟和 GitHub 条目，按 main 的保护规则通过必需 `Test and build` 后正常 squash 合并，未使用管理员绕过。合并提交：`9acce8f6d77dca55de655d7121bde5d04cb1fb27`。

PR CI：1092 项测试中 1087 通过、5 跳过、0 失败，Release 构建通过。合并后默认 main 目录的真实公网安装测试通过，日志明确 `defaultSource=true`，两款包的摘要、下载、预览、安装、授权、精确路由与卸载均验证；结果 `/tmp/dynamic-island-market-default-live.xcresult`。当前默认目录包含四款插件。

## 默认主页层

「设置 → 通用 → 主页 → 展开时主页默认页面」使用原生分段选择器提供音乐、日历、课程、会议，默认音乐。`IslandHomeSettings.defaultLayer` 保存到 `island.home.defaultLayer`；旧安装或无效存值回落音乐。

只有真正从收起进入展开状态时读取当前默认层，重复指针采样、展开中切层、访问其他区域后返回均保留本次手动选择。修改偏好在下次展开应用。只更新主页层，不改变活动、计时完成或拖入文件的目标区域；锁定托盘后指针重入不算一次新的展开。

## 循环切换

仅主页四层支持循环：音乐 → 日历 → 课程 → 会议 → 音乐，反向同样循环。先将偏移对层数取余再计算索引，`Int.min` / `Int.max` 均不溢出。继续使用原有手势状态机，每次手势只切一页，惯性不连续翻页；其他区域与设置分页仍在首尾停止。滑块、原生选择器、输入框及横向列表保留自己的交互。

## 验证

本地分批定向测试共 177 个不同方法通过，覆盖主页默认选择与恢复、循环边界、真实设置鼠标输入、两种主页缩放、手势排除、工具与计时优先级、展开模型、真实公网安装与媒体授权。初次新增设置测试的 OCR 将四个分段识别为一行，导致控件定位失败；改为定位真实 `NSSegmentedControl` 并发送鼠标事件后，整个 AppSettingsTests 9 项通过。没有直接改模型值来替代 UI 点击。

公网测试先使用 PR 的固定提交目录，经生产 `PluginRegistryClient`、Release、归档摘要与 Installer 链路，验证两包安装默认禁用，启用不授权、不启动 helper，独立批准读控后五项操作发送到正确 Bundle ID，撤权与卸载失效。只替换系统 helper runner，不读取或控制真实播放器，也不触及用户插件容器。

- 44 项其他主页/导航方法在第一次运行通过，9 项设置方法在修正测试定位后通过。
- 13 项 Registry 离线测试、7 项可选音乐安装测试通过。
- 31 项 Activity Runtime、51 项 ViewModel、1 项音乐公网测试通过。
- 21 项 Manifest 测试通过；单独编译公开旧 Host 的真实解析器，验证两包满足旧数组上限并明确被拒绝。示例测试保留所有数组检查，按当前 schema 是否支持媒体描述符分别验证完整解码或拒绝新字段，没有放宽生产解析器或跳过示例。
- 通用设置同时显示音乐来源和主页设置时，原生鼠标选择与持久化再次通过；截图确认默认页面四个选项完整显示，结果 `/tmp/dynamic-island-general-home-combined.xcresult`。
- SDK 的 45 项 Python 测试、媒体包/节点/脚本预检和 TypeScript 合约通过。
- build22 Release 构建、版本/构建号、发布配置与 `codesign --verify --deep --strict` 通过。本地没有运行全量 CI；目录 PR 的 CI 验证主分支公开 Host。

结果：`/tmp/dynamic-island-home-default-loop.xcresult`、`/tmp/dynamic-island-market-settings.xcresult`、`/tmp/dynamic-island-market-live-routing.xcresult`、`/tmp/dynamic-island-media-manifest-compat.xcresult`。程序：`/Users/rong5/.codex/artifacts/dynamic-island-home-build22/Dynamic Island.app`。源码旁的[证据目录](evidence/u17-market-home-default-loop-20261104/validation.json)包含安装包、摘要、截图和测试摘要。

QQ 音乐未安装，Spotify 未运行；真实播放器控制、系统提供封面和持续收起态更新仍待验收。物理触控板手感也需人工确认，自动化状态机与原生监视器测试不代替该步骤。
