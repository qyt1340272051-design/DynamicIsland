# beta.2 当前设备补充实机观察

本地日期：2026-10-22（Asia/Shanghai）。原样公开 App 0.6.0 / build4，Mac16,12 / arm64 / macOS 26.6.2（25G83），单内建刘海屏。[B01 结构化记录](di-b01.json)和[B02 结构化记录](di-b02.json)均为 **pending**，与[前一批部分观察](../beta-device-20261022/README.md)共同阅读。

## 本轮补齐

- **默认显示配置**：系统设置实际选中 1470×956（默认），backing scale 为 2。原生面板 2560×1664 与报告中的 estimated pixels 2940×1912 分别记录。默认报告的面板顶边为 956 pt，紧凑宽度 179 pt 与辅助顶区间隙一致；这些几何数值不代替物理刘海周围的视觉验收。[原始报告](sources/diagnostic-default-visible-20261022.txt)
- **文件托盘**：第二次导入唯一的 91-byte 合成文件，副本摘要匹配；锁定后两次观察间隔 42.371 秒仍展开，用户已被提示移出，工具未独立测量全局指针位置。实际打开 AirDrop 系统面板并取消，没有选择接收设备或发送。仅移除本轮测试副本，解锁后立即收起，UI 回到 0，原两项临时文件和合成源保留。[锁定记录](sources/tray-lock-hold.json)、[AirDrop](sources/airdrop-panel-observation.json)、[清理](sources/tray-followup-cleanup.json)
- **官方插件 GUI 安装及权限**：真实刷新默认目录、下载预览、显式安装番茄钟 0.2.1 / GitHub 0.1.0；安装后停用，启用不会自动批准权限。分别验证拒绝，再按用户本轮许可逐项批准四项权限。最后全部撤销并停用两个插件；真实退出重启后仍保持撤销／停用。[授权及清理](sources/temporary-plugin-permissions.json)、[重启](sources/app-after-real-restart.json)
- **番茄钟**：15 分钟预设保存、暂停／继续／结束通过；另一轮真实 900 秒运行在 GitHub 操作期间持续推进，最后观察到“本轮已完成 00:00”、进度 100%，没有观察到自动重开。用户另行确认收起后两侧完整。该回复在计时结束后收到，没有独立物理观察时刻。[自然计时结果](sources/pomodoro-build4-natural-result.json)、[用户确认](sources/user-followup-confirmations.json)
- **GitHub**：真实公开 actions/checkout、cli/cli 数据，仓库切换和刷新；系统默认 Safari 实际打开构建和 PR 页面，URL／标题分别核对，无登录或 Token。仅关闭本轮新增的两个公开标签页。运行中撤销网络后刷新显示“网络未授权”，随后撤销其余权限并停用。[构建页面](sources/github-browser-build-open.json)、[PR 页面](sources/github-browser-pr-open.json)、[撤销](sources/github-permission-revoke-steps.json)
- **生命周期**：岛内电源按钮正常退出 PID 63049，确认进程消失；实际重启为 PID 68525，并检查权限／停用持久化。再经原生应用退出菜单正常退出并确认进程消失，均未强制退出。最后重新启动并留作使用；用户确认右上角胶囊菜单隐藏后消失、显示后恢复且能悬停展开。[第一次退出](sources/app-normal-quit-result.json)、[菜单退出](sources/app-menu-quit-result.json)、[用户确认](sources/user-followup-confirmations.json)

## B02 执行范围与恢复

经用户明确同意，实际切换了 **1280×832** 和菜单栏“始终”自动隐藏。合成 TextEdit 文档进入原生全屏，“退出全屏幕”菜单证实其状态，随后正常退出；全屏期间能读取 App 面板 AX，但这不证明它显示在前台 Space。没有取得非默认状态的新 App 报告，也未实际验证第二桌面切换及各上下文物理刘海显示／悬停，因此 B02 保持 pending。[分辨率选中行](sources/display-b02-1280x832-ax-excerpts.txt)、[自动隐藏选项](sources/menu-bar-temporary-always.json)、[全屏观察](sources/b02-textedit-observation.json)

已在系统设置恢复 **1470×956（默认）**及原菜单栏 **“仅在全屏幕视图下”**，并关闭设置。用户后补的报告也显示恢复后的 1470×956，不能当作 B02 非默认报告。合成 TextEdit 文档移到本地临时目录后关闭。[恢复核对](sources/display-restore-result.json)、[恢复后报告](sources/diagnostic-after-display-restore-20261022.txt)、[文档清理](sources/textedit-fixture-cleanup.json)

## 保留的边界

- 本轮未连续捕获番茄钟自然到期转换，也漏拍短暂 compact 完成提示。首次完成态观察在预期截止后 **74.133 秒**；这是采样时机，不能记作计时调度延迟。历史 T35 已通过的独立验收仍按其原范围保留。
- GitHub 切换仓库后有一次读到内置计时界面，重新选择 GitHub 后正常显示仓库；未捕获收起事件，原因未确定。[当时界面](captures/b01-build4-native-after-github-selection-reset.txt)
- 前一批为保护两项既有临时文件而暂缓 AirDrop。本轮核对实际分享入口只使用当前托盘条目；唯一条目已证实为合成文件，因而补验打开／取消。清空入口会遍历临时目录，仍未执行。前一批记录保留为历史快照。
- B01 尚缺真实 Apple Music（用户暂不播放）、物理滑杆拖动／音量 HUD 完整性、安全空基线下的托盘清空，以及当前发布包长工具菜单选择／返回复测；本批未关闭完整场景。
- B02 的完整前台 Space／原生全屏／菜单栏过渡仍待实测；其他七项硬件、干净 Mac 安装及 T39 独立新作者验收未新增结论。U02 全分辨率自适应仍只是后续计划。

## 清理与证据

最近确认音量 0／静音，秒表重置，倒计时恢复 5 分钟且未运行；番茄钟本轮已结束，两个官方插件保留安装但停用，四项权限全部撤销且重启后保持。文件托盘未锁定、UI 为空，原两项临时文件保留。未播放音乐、未发送文件、未使用登录或 Token；App 最终保留运行。

[manifest.json](manifest.json)逐项列出原字节截图／AX／JSON 的 bytes 和 SHA-256；截图实际为 JPEG。系统设置含账户身份的原图未归档，改用筛选后的选项记录；AirDrop 身份信息和私人数据备份均未发布。`sources/default-environment.json` 是 05:05 报告对应的历史底稿，其中 B02／恢复的 planned 字段不代表本批最终状态；最终状态以 `di-b01.json`、`di-b02.json` 和后续恢复记录为准。

PR #7 已正常合并为 `8b3a184a9d5e24134f5f10edd566c0e577f20597`。[现成 main push CI](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39725742204)同一提交 **1092 total / 1087 passed / 5 skipped / 0 failures**，Release 构建通过；本轮未 dispatch 或重跑该检查。[合并后 receipt](sources/pr7-postmerge-ci-result.json)与[历史 PR 检查快照](sources/pr7-ci-result.json)分别保留，后者 OPEN 不表示当前 PR 状态。本批只增加文档与证据，公开 App／冻结 SDK 均未修改。
