# 独立 AI 原创插件的 Host 自动验收

[result.json](result.json)记录正式 Extractor / Validator → VM / Bridge → ActivityManager / ActionRouter 的结果及源码摘要，[summary.json](summary.json)为真实 xcresult 摘要，[test-excerpts.txt](test-excerpts.txt)保留八项测试的实际开始 / 通过记录。

输入为[此前独立 AI 作者生成的原始包](../t39-independent-20261019/status-switch-0.1.0.dip)，2661 bytes，SHA-256 `c4a68d98adff6205e9f712feeebab86d610ac5230a128ebd28281d4741e90f0b`。本轮未读取 AI JavaScript 正文来编写测试，没有修改其源码或归档；预期状态来自作者 README。入口仍由正式 Validator 读取、生产 JavaScriptCore Runtime 执行。

新增用例验证停用不执行、focus / rest 分别更新「专注中」/「休息中」、保持同实例、停用撤销旧动作、再启用新实例恢复初态。与既有 SDK / 文档契约合计 **8 passed / 0 skipped / 0 failures**，不是八项新用例或一次完整 CI。

Host 的 expanded 上下文和工具选择由测试直接设置，动作由正式 Router 分派；没有真实 AppKit 点击、物理指针、真人操作或像素截图。先前 AI 作者的 137.7 秒离线用时不等于本轮 Host 或十分钟安装验收。

SDK 1.0.0 候选 ZIP 未改动，仍为 `47729aa038528f800b8da6fd94666a0c0bcf6da6cc530086d5d4c86f9443663c`。没有要求用户操作、修改生产 App、创建发布或上传。
