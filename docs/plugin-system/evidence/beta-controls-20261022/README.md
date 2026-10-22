# beta.2 滑杆与七项工具菜单补验

本地日期：2026-10-22（Asia/Shanghai）。原样公开 App 0.6.0 / build4，Mac16,12 / arm64，沿用同一进程；源码与发布可执行文件身份见[结果](result.json)和[启动记录](sources/session-start.json)。本轮补验当前设备的两个缺口，DI-B01 保持 **pending**；[前批记录](../beta-device-followup-20261022/README.md)按原时间范围保留。

## 音量滑杆

用户实际拖动并确认音量文字变化。第一次回复后读到的仍是 0／静音，不把那张图当作中间值证据；再次请用户停在约 10% 后，实际 AX 读到 **0.09551376104354858**，截图文字为 **10%**。随后通过正式减小按钮降至 0.03301377221941948，再恢复 **0／静音**。没有播放音乐。

[中间值截图](captures/b01-physical-slider-held.jpg)、[AX](captures/b01-physical-slider-held.txt)、[恢复 AX](captures/b01-physical-slider-restored.txt)、[结构化结果](sources/physical-slider-result.json)。这补齐真实鼠标拖动；不将 App 窗口截图解释为物理刘海周围音量 HUD 的完整性证明。

## 七项菜单及底部工具

将六款仓库已有、`permissions=[]` 的样本用冻结 SDK 打包，并通过正式预览／安装流程安装，初始停用后逐项启用：Hello、兼容计数／进度／状态、计时三态、工具选择示例。原两个官方插件一直停用，未重新授权。首个 Hello 文件选择器的路径输入自动化未稳定确认，由用户协助选包；不能记作 T39 新作者独立上手。

用户按提示选择最底部“工具选择示例”，在菜单位置停约半秒后移回岛内，回复 **“保持展开，仍是工具选择示例”**。回复后的第一张 App 图为 compact idle，它不独立证明此前的物理返回时段。随后另行实际打开原生菜单，捕获完整 **七项**；选择底部工具稳定显示“已点击 0 次”，正式按钮“增加一次”更新为“已点击 1 次”。这些分别是用户对物理返回的确认和助手对实际菜单／渲染／动作的观察，未连续记录全局指针。

[七项菜单截图](captures/b01-seven-menu-actual-entries.jpg)、[菜单 AX](captures/b01-seven-menu-actual-entries.txt)、[稳定工具页](captures/b01-bottom-tool-selected.txt)、[按钮结果](captures/b01-bottom-tool-incremented.txt)、[范围与用户反馈](sources/long-menu-result.json)、[六包摘要](sources/menu-package-manifest.json)。本轮第七项为现有 tool-demo，与历史 U01 的“双按钮状态”样本不同；没有修改菜单实现，也没有重新定义已 verified 的 U01。

## 清理与仍待验证

六款本轮新增样本已逐项停用并正常卸载；原 GitHub／番茄钟两项保留安装、停用，三项／一项权限仍分别为已撤销。安装数恢复 **2**。未修改显示设置、移动或删除托盘文件，未启动音乐或计时，设置窗口已关闭，App 保持运行。[卸载记录](sources/menu-sample-cleanup.json)、[最终清理](sources/final-cleanup.json)、[保留的两项](captures/b01-samples-removed-original-two-retained.txt)、[番茄钟撤销状态](captures/b01-original-pomodoro-still-revoked.txt)

DI-B01 仍缺物理音量 HUD、实际 Apple Music、安全基线下的托盘清空，以及完整正常离开／再展开复测序列；原两项未知临时文件继续保留。B02 物理全屏／Space 和非默认新报告、其他硬件、干净 Mac 安装及 T39 新作者门槛均未关闭。U02 全分辨率自适应保持 pending／版本待定。

[manifest.json](manifest.json)记录逐项 bytes／SHA-256；只归档本轮 App 窗口、公开样本和筛选的来源，不归档文件选择器或私人数据备份。图片为原始 JPEG 字节，未转码或编辑。本轮没有改动 App、Runtime 或冻结 SDK。

上批 PR #8 的合并提交 `a65390d69be73be5168c9be30d0848f8e2a328e7` 已有 [main push CI 39733641959](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39733641959)成功：1092 total / 1087 passed / 5 skipped / 0 failures，Release 构建通过。[只读核对 receipt](sources/pr8-postmerge-ci-result.json)保留其身份；未 dispatch 或重跑，也不冒充本批新提交的 CI。
