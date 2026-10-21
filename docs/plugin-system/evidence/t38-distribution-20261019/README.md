# SDK 1.0.0 发布候选的本地分发证据

本目录保留初始与 receipt 文案修正阶段的历史字节和测试结果。后续目录扫描错误修复、40 项 SDK 检查及最新候选摘要见[最终归档复核](../t38-final-audit-20261019/README.md)；下文 39 项和 84,000 bytes 不代表最新 canonical ZIP。

日期：2026-10-19。结果见 [result.json](result.json)，实际文件清单见 [file-inventory.json](file-inventory.json)。本候选尚未公开发布、推送、创建 tag 或上传 npm；`private` 保持 true。

[sdk-check.txt](sdk-check.txt)记录最终源码的 39 项 Python 全通过、三款 Manifest / 目录校验及 TypeScript 检查。正例与既有 47 项预期类型错误通过，协议与资源权限范围没有扩大。

[portable-check.txt](portable-check.txt)来自**初始候选** ZIP 解压后的独立 SDK，39 项中 37 passed、2 skipped、0 failures。跳过项分别要求完整仓库的官方示例与兼容 wrapper；不把这两项算作通过，也不依赖它们运行作者工具。原结果与清单保留在 [initial-candidate.json](initial-candidate.json) 和 [initial-file-inventory.json](initial-file-inventory.json)。receipt 文案修正后重跑的最终 SDK gate 包含实际解压的全部 Markdown 入口、交互式 zsh Quick Start 和真实 fixture 检查；没有将初始独立全套测试冒称为新 ZIP 上的重跑。

[package-summary.json](package-summary.json)记录本地 ZIP 的大小、53 个源文件及整体 SHA-256。清单列出每份源文件的大小与摘要；ZIP 另含生成的 `distribution-manifest.json`。摘要仅用于核对字节，不提供来源身份认证。同一 Python / zlib 工具链下，测试重复生成两份 ZIP 并比较完整字节。

新上下文 AI 作者在初始候选上用 137.7 秒完成离线 Hello 与原创双按钮插件开发，未读 Swift；不包含 Host 安装 / UI，也不是人类走查。其反馈使 README 明确 publish / update resolve 为 `{id: string}` receipt。API 和 Hello fixture 不变；新 ZIP 为 84,000 bytes，SHA-256 `47729aa038528f800b8da6fd94666a0c0bcf6da6cc530086d5d4c86f9443663c`，只比旧 ZIP 改变 README 和生成清单。旧 SHA `b92a911594b8e7dafa723dc70ba6e851cc35e21ec0e730ef2857a8cf5ccf0808` 及其实际阅读范围保存在 `initialCandidate`，旧 ZIP 留于本轮临时证据备份；原 AI 已读目录没有修改。

Hello README 修正了 SDK 根目录命令及版本说明，因此 `.dip` fixture 从历史 2667 bytes 变为 2690 bytes；JS 与 Manifest 不变。原人工验收包的旧 SHA 和截图保持历史原状，不反写成新候选的验收结果。

本次 SDK 元数据、类型 / CLI 说明、Schema 来源状态、版本策略和变更说明一致采用 1.0.0 发布候选。正式 Host 契约由主任务集中运行，首次独立作者和实际用时继续由 T39 单独追踪。
