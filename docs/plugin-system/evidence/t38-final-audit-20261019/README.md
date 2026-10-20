# T38 最终归档复核

本目录保留 2026-10-19 目录扫描修复阶段的字节与结果。2026-10-20 又按人工卡点补充成功输出 / 包路径说明；当前候选摘要见[后续分发记录](../t39-output-clarity-20261020/README.md)。下文的 84,278 bytes 为本阶段历史候选。

审阅发现 `os.walk` 默认可能忽略子目录读取错误，导致工具成功输出缺文件的 SDK ZIP。现通过 `onerror` 直接抛出错误；新增模拟 `scandir PermissionError` 的负向测试，确认不会生成目标归档。

[SDK gate](sdk-check.txt)为 **40 passed / 0 skipped / 0 failures**，类型正例与 47 项预期错误通过。gate 仍覆盖实际解压后的全部 Markdown 链接、交互式 zsh Quick Start 和真实 Hello fixture。没有新增 Host 协议或资源权限。

[最新候选](package-summary.json)包含 53 个源文件，**84,278 bytes**，SHA-256 `dd9ba3e40c856343271e8088643276fc329526191213fa1bbee1973eab299433`。两次独立打包字节一致；每个源文件与[分发清单](distribution-manifest.json)和工作区逐字一致。仅两个 SDK Python 文件及生成清单相较 receipt 候选改变。

[结果](result.json)保留旧候选的摘要、实际备份和历史证据。AI 作者读的是初始候选；[Host 8 项测试](../t38-independent-host-20261019/result.json)独立记录实际原包执行。本次只修复 SDK 归档工具，不将旧走查归到新字节，也不声称真人或刘海实机验收已通过。

最新本地 ZIP 位于仓库 `artifacts/sdk/dynamic-island-sdk-1.0.0.zip`，尚未公开发布。完整说明见[候选复核](../../t38-stability-review-20261019.md)。
