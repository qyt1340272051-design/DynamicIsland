# T39 成功输出与包路径说明改进

用户在终端阶段请求协助，实际贴出的两条 JSON 分别为 `validate` / `package` 且 `ok: true`。未观察到命令失败。助手解释成功状态并定位已有 `/tmp/hello-world-0.1.0.dip`，随后协助进入正确 Hello 安装预览。人工过程另见[协助记录](../manual-remaining-20261019/m05-assistance-20261020.json)。

仓库 SDK README 与 Quick Start 现明确：两条成功状态代表可以进入安装，`summary` 统计源码；README 手动命令使用其指定输出路径，Quick Start 脚本使用最后 `Plugin package:` 后的实际路径。只改说明文字，未修改脚本、示例、类型或 Host API。

[SDK 检查](sdk-check.txt)：**40 Python passed / 0 skipped / 0 failures**，严格类型正例和 47 项预期错误通过；15 页 / 9 个源码对照块 / 33 条本地链接通过。

[最新候选](package-summary.json)：**84,717 bytes**、53 个源文件，SHA-256 `8f4da7d24c1def1db6087b9c9124b427761975c3458075248afb831217d161ab`。两次独立打包字节一致，归档中每份源码与[清单](distribution-manifest.json)及工作区匹配。[结果](result.json)保留旧候选与实际备份位置。

用户本轮复测读取的是旧 `dd9ba3e4…` 候选解压目录；新说明没有回写进该副本，不将旧走查冒充新字节的独立验收。[协助功能复测](../../t39-manual-retry-20261020.md)随后已核对 Hello 实际计数 3 次并正常退出。新目录仅供后续复测：`/tmp/dynamic-island-sdk-output-clarity-20261020/walkthrough/DynamicIslandSDK`。候选没有公开发布。
