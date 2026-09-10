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
- Developer ID Archive、公证、DMG、SHA-256、manifest、Tag 和 GitHub Release 自动化。
- 菜单栏脱敏调试报告、Beta 反馈入口和诊断信息单元测试。
- 可由 CI 校验的 9 类真机 Beta 矩阵、验收手册和 `S0`–`S3` 问题分级流程。

### Changed

- 紧凑面板高度改为屏幕顶边与普通窗口可用顶边之间的保留区域高度。
- 面板展示状态切换改由 SwiftUI 驱动动画，避免与 AppKit frame 动画冲突。
- 音乐、文件托盘和计时工具之间加入一致的缓入缓出转场。
- 音乐播放与计时运行时使用更宽的紧凑岛展示实时状态。
- 项目、App、target、scheme、源码目录和测试目录统一改为英文 Dynamic Island 命名。
- 首个签名公测版本设为 App 版本 `0.4.0`、Tag `v0.4.0-beta.1`。
- Release 构建启用 Hardened Runtime，并禁止注入 `get-task-allow` 调试 entitlement。

### Fixed

- 修复悬停延迟期间过早展开、离开后延迟任务未取消的问题。
- 修复音量、错误和指针反馈等普通状态触发多余面板 frame 更新的问题。
- 修复 Spaces、全屏、隐藏菜单栏、合盖切屏和 Apple Music 权限拒绝场景下的稳定性问题。
