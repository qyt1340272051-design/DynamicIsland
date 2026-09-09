# 更新日志

本文件记录项目的重要变化。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号将遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 菜单栏常驻应用和贴合 Mac 刘海顶部的浮动 `NSPanel`。
- 系统音量读取、滑杆调节、增减和静音控制。
- Apple Music 曲目信息、封面、实时进度和播放控制。
- 文件临时托盘、拖放导入和系统 AirDrop 分享。
- 秒表、多个番茄钟时段和支持长按快速调节的倒计时。
- 音乐与计时活动的紧凑状态展示。
- 多显示器选择、拓扑变化监听和模拟屏幕调试器。
- 64 状态屏幕快照矩阵和关键系统场景稳定性测试。
- README、贡献说明、Issue/PR 模板和 GitHub Actions 持续集成。

### Changed

- 紧凑面板高度改为屏幕顶边与普通窗口可用顶边之间的保留区域高度。
- 面板展示状态切换改由 SwiftUI 驱动动画，避免与 AppKit frame 动画冲突。
- 音乐、文件托盘和计时工具之间加入一致的缓入缓出转场。
- 音乐播放与计时运行时使用更宽的紧凑岛展示实时状态。

### Fixed

- 修复悬停延迟期间过早展开、离开后延迟任务未取消的问题。
- 修复音量、错误和指针反馈等普通状态触发多余面板 frame 更新的问题。
- 修复 Spaces、全屏、隐藏菜单栏、合盖切屏和 Apple Music 权限拒绝场景下的稳定性问题。
