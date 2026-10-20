# U01 第三版：返回时间与指针复核

[第二轮物理失败](../u01-menu-repair-20261020/physical-return-attempt-2.json)的两个日志会话均完成选择及宽限移交，完整经过 1.097395 / 1.047012 秒，期间没有 pointerEnter 或 cancel。它们来自同一轮用户反馈，不计两轮独立真人验收。日志不能继续区分实际返回时间与采样未命中的原因。

第三版将固定返回宽限调为 2 秒；原 30Hz 指针 Timer 加入主 RunLoop `.common`；截止释放前由 Controller 强制重读实际鼠标位置，同步自身缓存和 VM，再核验原 token。短暂进入不消费或延长截止时间，真实隐藏和正常离开仍清理所选工具。

- [定向测试原始日志](pointer-regression.txt)：96 tests / 0 failures / 0 skipped；菜单 18、ViewModel 50、Runtime 24、Hover Region 4 项。新增四项通过闭包模拟 Controller 的同步刷新，覆盖内外缓存与隐藏／重开，不代替物理鼠标。
- [普通 Release 原始日志](release-build.txt)与 [strict / deep 签名](signature.txt)通过。
- [预检](preflight.json)绑定 102 个生产 Swift 文件、可执行文件及构建／测试日志。失败副本 PID 22058 已正常退出，第三版仅使用原隔离验收容器，无额外插件授权或生产容器修改。
- [初始截图](third-candidate-initial-state.jpg)及 [AX](third-candidate-initial-state.txt)仅记录启动后的收起状态。
- 当前副本为 `Dynamic Island Menu Return`（PID 23408），已开启低频事件记录。用户已确认返回后保持双按钮工具；[第三轮记录](physical-return-attempt-3.json)对应会话 2.039910 秒到期时复核 inside=true，完整 trace 同时保留其他取消 / outside 到期会话，不全部归为成功。回复后截图仅显示收起状态，工具身份依据用户反馈。用户也确认正常离开重开回到内置计时；键盘 / 取消和退出收尾仍待，见[结构化状态](result.json)，U01 保持 `in progress`。

没有进行公开发布或远程推送。
