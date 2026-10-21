# T31 — 前台判定修正与实际反馈

日期：2026-10-14。本页记录策略原因的诊断与代码修正；后续两段长时测量已完成，见[后台验收记录](t31-background-20261014.md)。

普通 Release、隔离容器及 20 个原 audited 1.0.1 插件。实际诊断 [修正前](t31-policy-20261014/policy-before-fix.json)同时显示 `policy=active`、`NSApp.isActive=true`、本进程不在前台、低功耗关闭。因此单独以 NSApp 标志判断前台不充分；跨 App 的定向 AX/键盘操作也不能代替状态确认。

active 现在同时要求 NSApp 活跃和 Workspace 前台 PID 等于本进程。监听 NSApp/default center 与 Workspace center 的激活 / 失活事件，按各中心注销，共用 generation 拒绝停止 / 重启后的旧回调；低功耗仍优先，没有新增轮询或插件私有接口。只读诊断页显示刷新时的四项 Host 状态，未暴露其他 App 名称、PID 或内容。

[修正后快照](t31-policy-20261014/policy-after-fix.json)在相同 NSApp 活跃但非前台条件下返回 background。[实际刷新记录](t31-policy-20261014/refresh-after-fix.json)为 21:03:23、21:04:28 两次 INFO，验证 JS 收到实际后台策略。原 App PID 66831 保留；验收副本使用独立 bundle ID，未竞争 `.dip` handler 或改变用户默认设置。

新增两项 Workspace 状态 / 旧回调测试，两项诊断快照测试。定向首轮 27 passed；新增 Sendable warning 修正后诊断定向 9 passed。完整 `./Scripts/ci.sh` 为 **703 total、702 passed、1 skipped、0 failures**，普通 Release build passed；日志 `/tmp/dynamic-island-t31-corrected-ci.log`，结果 `/tmp/dynamic-island-t31-corrected-ci/TestResults.xcresult`。唯一 skip 为原截图生成。完整 CI 未出现本次新增 closure warning。

本页不能替代长时 CPU / 能耗验收。后续已固定本次 Release 和 sampler，真实 UI 全停用 / 全启用各测约 15 分钟，逐个保存 20 项完整日志及时间边界，结果链接如上。

前台进程依据 [Apple NSWorkspace.frontmostApplication](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)；它表示接收键盘事件的前台 App。本次实际差异来自上述实机快照，不假设所有 UIElement 都有相同行为。
