# U01 菜单交互证据

- [最终预检](preflight.json)记录生产源码 SHA-256、最终 Release / 副本身份、签名及 88 项定向结果。[初版预检](initial-preflight.json)仅保留替换前的历史身份，初版已正常退出。
- [定向测试原始日志](targeted-tests.txt)：最终 88 项 / 0 failures，含新增 10 项与既有 78 项；没有跳过。本批不是完整 CI。
- [最终 Release 构建日志](release-build.txt)与 strict / deep 签名均通过。AppIntents 元数据提示为未依赖该框架，非编译失败。
- [实际清单 AX](inventory-ax.txt)显示最终副本的六款示例均运行；[截图索引](screenshots.json)现含最终七项菜单、底部工具选择及按钮更新原图；初版收起画面独立保留。物理返回路径仍待结果。

实现细节、首次 visibility 回归修正和待完成实机步骤见[U01 记录](../../u01-tool-menu-20261020.md)。用户已配合展开，助手已完成真实原生菜单打开、AX 底部选择及按钮更新；[当前结果](result.json)与[只读连续观察](pointer-watch.json)保留范围。最终副本保持运行，等待用户实际菜单外侧移动 / 返回结果，尚未退出收尾，不宣称 U01 已验收。
