# T39 修正版手册人工复测

日期：2026-10-20。用户恢复人工项目后，M03 菜单 / 兼容工具及 M04 计时三态已完成。本轮 M05 的协助功能复测已通过；参与者已有首轮经验，过程中接受了协助，不能记作新作者首次无指导通过。T39 继续为 `in progress`。

## 实际过程

用户按[本次起点](evidence/manual-remaining-20261019/m05-attempt-20261020.json)使用独立 SDK 解压副本，随后在终端校验 / 打包阶段请求协助。用户提供的[原始输出](evidence/manual-remaining-20261019/m05-user-output.txt)中，`validate` 和 `package` 均为 `ok: true`；没有观察到命令失败。助手解释成功状态，定位已有 `/tmp/hello-world-0.1.0.dip`，说明后续导入步骤。

用户第一次回复看到 0 → 1 时，实际管理页和 Installed 目录仍仅有原先五个包，没有 `com.example.hello-world`。该回复不能归属到 Hello。助手随后通过真实文件选择器打开正确包，预览名称“你好，计数器”、ID `com.example.hello-world`、版本 0.1.0、无额外权限；助手没有点击安装、启用或加一。见[协助记录](evidence/manual-remaining-20261019/m05-assistance-20261020.json)及[正确预览](evidence/manual-remaining-20261019/m05-hello-install-preview.jpg)。

用户随后明确回复“Hello 已安装启用，已点击加一”。[真实管理页](evidence/manual-remaining-20261019/m05-hello-running.jpg)显示已安装六款，Hello 正在运行。其[已安装文件](evidence/manual-remaining-20261019/m05-installed-20261020.json)与所选包三份文件的 SHA-256 全部一致；Manifest 权限数组为空，启用状态已持久化，Staging 为空。用户包为 2,690 bytes，SHA-256 `d0e94985f688832de8227f524cecb2bef83aef09c50af6ddebf33129d077c976`；助手另行生成的诊断包明确排除，不替代用户产物。

用户随后配合展开刘海。助手仅选择 Hello，实际 [AX](evidence/manual-remaining-20261019/m05-hello-count.txt)及[原始截图](evidence/manual-remaining-20261019/m05-hello-count.jpg)均显示“已点击 3 次”；助手没有点击增加或重置。该证据证明当前 Hello 已响应用户点击，不声称直接拍到最初 0 → 1 的瞬间。尚未取得用户实际耗时及是否查阅 Swift 的答复，不推断约十分钟目标已达成。

副本于 2026-10-20 14:10:33.618（北京时间）正常 Cmd+Q 退出；[只读退出核对](evidence/manual-remaining-20261019/m05-cleanup.json)确认 PID 7794 消失、Staging 为空，六款 Installed 和启用状态保留。退出后没有再调用 UI 读取，未重新启动副本。Hello 的计数仅在内存中，下次启用 / 重启预期归零，不能将安装保留写成计数持久化。

[本轮结构化结果](evidence/manual-remaining-20261019/m05-result.json)保留安装、计数、协助范围和退出证据。

## 文档修正与验证

[SDK README](../../SDK/README.md)和[Quick Start](../../SDK/docs/quick-start.md)补充两条成功 JSON 的含义、`summary` 的源码统计范围及实际输出包路径。只修改说明文字，未改脚本、Hello 模板、类型、Runtime 或权限。

[本轮 SDK 检查与分发](evidence/t39-output-clarity-20261020/README.md)为 40 Python passed / 0 skipped / 0 failures、严格类型正例及 47 项预期错误通过；文档为 15 页 / 9 个源码对照块 / 33 条本地链接。新候选 84,717 bytes / 53 个源文件，两次打包字节一致，SHA-256 `8f4da7d24c1def1db6087b9c9124b427761975c3458075248afb831217d161ab`。

用户本轮使用的仍是旧 `dd9ba3e4…` 候选副本；新文档没有回写进该副本，不把本轮走查算作新候选字节的独立人工验收。旧候选已保留备份。没有公开发布、推送远端或新增权限。

## 完成标准边界

原计划 T39 完成标准为“新开发者仅按文档即可构建并安装首个插件”。本轮用户已有经验，并接受成功输出解释、路径定位和打开正确预览的协助。功能结果与文档问题均如实归档，原无指导新作者门槛继续保留；不以 AI 离线走查或本轮协助结果替代。
