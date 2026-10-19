# T38：独立 AI 作者插件的正式 Host 自动闭环

日期：2026-10-19。用户暂不方便进行物理指针与真人复测，本轮只补充可自动完成的独立开发证据。新上下文 AI 作者此前仅凭独立 SDK 资料开发的[双按钮原始包](evidence/t39-independent-20261019/status-switch-0.1.0.dip)，现已进入正式 Host 的解包、校验、VM、Bridge、ActivityManager 与 ActionRouter 路径。没有改写该包、替换为自写 JS 夹具，或修改已冻结的 SDK ZIP。

## 来源与自动验证

原始作者过程见[离线记录](evidence/t39-independent-20261019/result.json)。137.7 秒只描述该 AI 作者的资料阅读、编写与离线校验 / 打包，不包含安装、启用、UI 或本轮 Host 测试，也不是人类首次使用验收。

本轮只读取作者 Manifest、README 和既有身份记录来确定接口及预期；没有为编写测试读取或修改 `index.js`。生产 Validator 在读取归档后保存真实入口快照，随后由生产 JavaScriptCore Runtime 执行。原包 SHA-256 仍为 `c4a68d98adff6205e9f712feeebab86d610ac5230a128ebd28281d4741e90f0b`。

[新增 Host 测试](../../DynamicIslandTests/PluginSDKContractTests.swift)复用已有 `SDKRuntimeFixture`，原 Hello 的 `increment` 路由默认值保留；原创插件使用显式 `focus` / `rest` 动作。断言覆盖：

1. `.dip` 进入 `PluginPackageArchiveExtractor`、`PluginValidator`，确认 Native 引擎与空 permissions。
2. 停用加载不创建 VM、不发布工具；启用后经真实 Bridge 发布「当前状态：待选择」，没有自行取得前台展示。
3. 测试设置 Host 数据上下文并选择工具，通过正式 ActionRouter 分别路由 focus / rest；异步等待实际 expanded 树出现「当前状态：专注中」与「当前状态：休息中」。两次更新保持同一实例，第一次也保留创建时间。
4. 停用后两个旧动作均被拒绝；重新启用创建新实例并恢复「待选择」。旧 rest 动作仍被拒绝，新实例 focus 可再次成功，生命周期没有最后失败记录。

这是数据与状态机的真实 Host 集成，工具选择发生在测试 ActivityManager 上；没有操作系统鼠标、原生按钮或真实刘海窗口。expanded 文本断言不等于像素已绘制或真实相机遮挡已检查。

## 结果与范围

[结构化结果](evidence/t38-independent-host-20261019/result.json)及[xcresult 摘要](evidence/t38-independent-host-20261019/summary.json)：`PluginSDKContractTests` 4 项、`PluginDocumentationTests` 4 项，合计 **8 passed / 0 skipped / 0 failures**。新增原创包用例为其中 1 项，原有 Hello、Schema / Converter 契约和文档 Host 闭环同时通过。

测试使用单台 arm64 MacBook Air / macOS 26.6.2、Debug XCTest Host 和隔离临时解包目录；这不是新完整 CI 或普通 Release UI 验收。两项既有 countdown 测试 actor 隔离警告及 AppIntents / linkd 系统诊断仍有出现，没有新增测试失败。

测试源码及涉及 Host 实现的 SHA-256、输入包摘要、命令、结果路径和日志摘要均已记录。本次 Host 测试时的 SDK 1.0.0 候选 ZIP 为 84,000 bytes，SHA-256 `47729aa038528f800b8da6fd94666a0c0bcf6da6cc530086d5d4c86f9443663c`；后续仅归档工具的扫描错误修复与最新候选另见[归档复核](evidence/t38-final-audit-20261019/result.json)，不改变本次原包及 Host 执行结果。

本轮补齐「AI 原创插件可通过正式 Host API 完成双动作闭环」的自动证据，不将其写成人类首次作者、原生鼠标点击、物理刘海视觉或十分钟安装目标通过。用户需要配合的验收继续按主任务人工清单延期，本轮没有请求操作或公开发布。
