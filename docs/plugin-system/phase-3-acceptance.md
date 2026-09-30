# Phase 3 — 真机验收结论

日期：2026-09-29。范围：T14 Music Provider、T15 Volume Provider、T16 Battery Provider、T17 Activity 压力与回归测试。

## 验收确认

用户在完成 Phase 3 真机验收后明确回复“验收完成”，未报告阻塞问题。该确认关闭四份任务记录中列出的人工设备项目，并解除 T18 的前置门禁：

- Music：真实 Apple Music 自动化权限、自动切歌与封面刷新、鼠标进度拖动、播放动作和 VoiceOver。
- Volume：键盘、控制中心及岛内控件的连续 Core Audio 调节，默认输出设备变化、回声抑制、连续动画和 Reduce Motion。
- Battery：真实 AC 接入/拔出、充电及充满组合、IOKit 回调、沙盒读取、睡眠唤醒刷新和回调稳定性。
- Activity Engine：Release App 空闲与 100 事件压力、抢占恢复动画、多显示器与混合缩放、热拔插/合盖、真实睡眠唤醒，以及 Music、Core Audio、Battery 和 Space/全屏的交错回归。

人工验收环境为用户实际 macOS 设备；本仓库没有保存具体硬件标识、Instruments 原始 trace 或逐项数值。后续若需要跨版本量化比较，应沿用 T17 的自动化样本，并另行保存同机 Release App 基线。这里仅记录用户给出的验收结论，不反推未提供的设备参数或测量值。

## 阶段统一检查

| 检查项 | Phase 3 结论 |
| --- | --- |
| 功能 | Music、Volume、Battery 已通过统一 Activity 路径工作；人工验收未报告状态错乱。 |
| 架构 | 三个 Provider 均经 ActivityManager、IslandRenderer 和 ActionRouter；没有新增直接操纵 Notch UI 的业务路径。 |
| 并发 | 后台入口由 MainActor 串行化；100 个并发 source 的自动化压力测试排空且无残留。 |
| 性能 | T17 已保存 100 Activity 自动化样本；人工 Release App 验收完成，未报告阻塞性回退。 |
| 能耗 | Music 使用单一 1.5 秒轮询，Volume/Battery 使用系统事件；未新增每插件或每 Activity 高频轮询。 |
| 安全 | Activity 输入仍受模型、HostPolicy、Renderer 和 ActionRouter 生命周期检查约束。 |
| 隐私 | Music 权限错误与业务状态分离；没有新增 Token、剪贴板或文件内容日志。 |
| 兼容 | 人工验收覆盖多显示器、睡眠唤醒及系统服务交错；自动化矩阵覆盖 8 种屏幕配置。 |
| 测试 | 最终 Phase 3 CI 为 278 tests、1 skipped、0 failures，Release build passed；稳定性矩阵 49 tests 通过，生成 104 张截图。 |
| 回滚 | Provider 由 Runtime 组合根持有，移除注入即可关闭对应 Activity 路径；没有新增用户数据迁移。 |

## 门禁结论

T14–T17 标记为 `verified`，Phase 3 完成。可以按照计划进入 Phase 4，从 T18 PluginManifest 开始；该结论不提前认可 T19 的包路径/文件验证或任何 JavaScript 执行能力。
