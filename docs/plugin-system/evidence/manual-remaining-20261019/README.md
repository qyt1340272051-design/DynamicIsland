# 恢复人工验收

[Host 预检](preflight.json)确认同一普通 Release 隔离副本、101 份生产源码摘要和严格签名；已装五个无额外权限包的文件摘要本轮复核一致。

## M03 已通过

[结果](m03-result.json)、[归并说明](../../t02-t37-manual-acceptance-20261019.md)、[按钮时间记录](actions.json)及[原始截图 / AX 索引](screenshots.json)记录菜单用户确认、三个兼容工具和独立作者包的真实 UI。

隐藏时的消失由用户直接确认；隐藏后 AX 超时没有当作像素证据。恢复后的真实窗口另行记录。三个兼容示例采用用户批准的原创兼容子集，不代表原样上游或完整兼容已验收。

## M04 仍待完成

前两轮均通过真实按钮开始五分钟 Host countdown，expanded 中实际看到 minimal、倒数推进和 Scheduler 回执后的 compact，但两次各 25 秒连续捕获都只有展开画面，未取得收起 minimal → compact 的物理界面记录。两轮已用真实“结束验收”按钮结束，目前没有计时运行。

[首轮](m04-run1-observation.json)和[第二轮](m04-run2-observation.json)保存帧时间 / AX，另存起点、阶段边界和末段原始图像。它们是未完成的观察记录，不计为 T11 已通过；同实例 / generation 的代码及自动证据也没有替换为本轮直接读取运行时身份。

M05 修正版手册复测尚未开始。后续验收结果继续追加，按[统一人工清单](../../MANUAL_ACCEPTANCE.md)追踪。
