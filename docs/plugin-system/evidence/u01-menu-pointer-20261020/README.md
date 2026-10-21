# U01 第三版：返回时间与指针复核

[第二轮物理失败](../u01-menu-repair-20261020/physical-return-attempt-2.json)的两个日志会话均完成选择及宽限移交，完整经过 1.097395 / 1.047012 秒，期间没有 pointerEnter 或 cancel。它们来自同一轮用户反馈，不计两轮独立真人验收。日志不能继续区分实际返回时间与采样未命中的原因。

第三版将固定返回宽限调为 2 秒；原 30Hz 指针 Timer 加入主 RunLoop `.common`；截止释放前由 Controller 强制重读实际鼠标位置，同步自身缓存和 VM，再核验原 token。短暂进入不消费或延长截止时间，真实隐藏和正常离开仍清理所选工具。

- [定向测试原始日志](pointer-regression.txt)：96 tests / 0 failures / 0 skipped；菜单 18、ViewModel 50、Runtime 24、Hover Region 4 项。新增四项通过闭包模拟 Controller 的同步刷新，覆盖内外缓存与隐藏／重开，不代替物理鼠标。
- [普通 Release 原始日志](release-build.txt)与 [strict / deep 签名](signature.txt)通过。
- [预检](preflight.json)绑定 102 个生产 Swift 文件、可执行文件及构建／测试日志。失败副本 PID 22058 已正常退出，第三版仅使用原隔离验收容器，无额外插件授权或生产容器修改。
- [初始截图](third-candidate-initial-state.jpg)及 [AX](third-candidate-initial-state.txt)仅记录启动后的收起状态。
- 该副本 `Dynamic Island Menu Return`（当次 PID 23408）已正常退出，日志捕获停止。用户确认返回保持及正常离开清理，后续实测键盘最底部选择、按钮更新、Esc / 点外取消和页面切换通过，见[最终原生验收](native-menu-acceptance.json)与[退出清理](cleanup.json)。当前设备实际七项菜单范围内 U01 标为 `verified`。两次自动滚轮未观察内容变化，不作为滚轮通过；原一秒失败的唯一根因仍未确诊。

没有进行公开发布或远程推送。

## 本轮收尾证据范围

`keyboard-bottom-tool-result` 首帧 AX 尚为菜单但像素已进入工具，后续 `keyboard-selected-tool-button-focus.txt` 为稳定双按钮 AX；该标签并不表示此时已点击专注。真实专注按钮操作及更新见 `keyboard-tool-focus-confirmed`。`native-timer-restored` 是动画过渡帧，稳定内置秒表见 `native-timer-stable`。

`menu-scrolled-to-bottom` 与 `menu-coordinate-scroll-result` 两次自动滚轮尝试没有显示内容变化，仅记尝试；鼠标底部访问依据用户此前的完整步骤反馈，键盘底部可达另由 End / Return 实测。独立只读复核未发现阻断项，U01 仅按当前设备七项菜单范围关闭，完整清单与来源见 [native-menu-acceptance.json](native-menu-acceptance.json)。
