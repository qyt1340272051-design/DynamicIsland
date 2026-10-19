# T39 首次作者卡点、修正与协助复测

2026-10-19。助手只准备普通 Release 的隔离 App、空插件管理与手册；用户自行进行打包、安装、启用和点击。来源见 [preflight.json](preflight.json)，过程见 [walkthrough.json](walkthrough.json)。

首轮用户在终端报告 `zsh: event not found: /usr/bin/env`。旧手册的第一个可复制代码块包含 Bash shebang，交互式 zsh 对 `!` 进行了历史展开。已复现这一错误，随后把手册首段改为 `bash docs/quick-start.sh`；完整脚本折叠显示，并说明工作目录变量只在脚本内部存在。

[修正与回归](quick-start-fix.json)记录 Python 37 项、类型与 47 项预期错误、15 页 / 9 个源码块 / 33 条链接均通过。原有独立 SDK 测试现将真正的首段命令送进交互式 zsh 标准输入，实际生成包并对比确定性字节，覆盖这次粘贴入口的问题。

用户之后自行生成 [hello-world.dip](user-built-hello-world.dip)，三文件与模板逐字相同，整包与正式 Host fixture 字节相同，见 [user-package.json](user-package.json)。用户回复已看到 0 → 1；后续只读检查显示[插件已安装 / 运行](installed-running.jpg)，并在重新选择工具后看到[已点击 2 次](counter-2.jpg)。助手没有点击加一、重置或修改计数，实际值 2 如实保留。

[cleanup.json](cleanup.json)确认正常 Command-Q、PID 82976 消失、Staging 为空，已安装包与启用状态保留。安装未申请额外权限。

结论见 [result.json](result.json)：**协助功能复测通过，首次独立体验与十分钟目标未验证。** 交接至用户完成回复约十六分二十五秒，包含发现问题、修复、指导及等待；不是精确的首次点击耗时。是否查阅 Swift 未获单独报告。T38 稳定版本和后续独立作者体验继续追踪，T39 不因本轮协助成功直接改为 verified。
