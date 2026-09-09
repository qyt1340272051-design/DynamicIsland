# Dynamic Island

[![CI](https://github.com/qyt1340272051-design/DynamicIsland/actions/workflows/ci.yml/badge.svg)](https://github.com/qyt1340272051-design/DynamicIsland/actions/workflows/ci.yml)

一个贴合 Mac 刘海区域的 SwiftUI 交互模块。应用常驻菜单栏，通过无标题 `NSPanel` 在屏幕顶部提供系统音量、Apple Music、文件托盘、AirDrop 和计时工具，并在活动进行时保留紧凑状态提示。

> 当前版本目标为 `v0.4.0-beta.1`。发布链路已建立，但在 Developer ID 凭据和干净 Mac 验收完成前不会提供正式安装包。

## 界面预览

### Apple Music

![Apple Music 控制界面](docs/images/expanded-music.png)

### 文件托盘与番茄钟

| 文件托盘 | 番茄钟 |
| --- | --- |
| ![文件托盘界面](docs/images/expanded-file-tray.png) | ![番茄钟界面](docs/images/expanded-tools-pomodoro.png) |

### 紧凑播放状态

![紧凑播放状态](docs/images/compact-playing.png)

## 当前功能

- 刘海顶部 `NSPanel`：悬停延迟展开、拖入文件展开、状态切换动画与触觉反馈。
- 系统音量：实时读取和调节默认输出设备音量，支持增减、滑杆与静音。
- Apple Music：读取封面、曲名、歌手和播放进度，支持播放、暂停、上一曲与下一曲。
- 文件托盘：把拖入文件复制到沙盒临时目录，并通过系统 AirDrop 分享面板发送。
- 计时工具：秒表、多个番茄钟时段和可长按快速调节的倒计时。
- 紧凑活动态：音乐播放时显示微缩封面与六点动态指示，计时运行时显示功能图标和实时数据。
- 多屏适配：按当前屏幕、刘海安全区、菜单栏可见状态和显示器变化重新计算面板位置。
- 调试矩阵：内置模拟屏幕配置，可生成 8 种屏幕环境、8 种界面状态的 64 张快照。

## 环境要求

- macOS 26.0 或更高版本
- Xcode 26.6
- Swift 5

刘海 MacBook 是主要使用场景；无刘海内建屏幕和外接显示器也有对应的几何回退与模拟测试。

## 本地运行

```bash
git clone https://github.com/qyt1340272051-design/DynamicIsland.git
cd DynamicIsland
open DynamicIsland.xcodeproj
```

在 Xcode 中选择共享 scheme `Dynamic Island`，然后运行应用。应用使用 `LSUIElement` 作为菜单栏配件启动，不会显示普通主窗口；可通过菜单栏图标重新显示或退出。

也可以直接从命令行构建：

```bash
xcodebuild build \
  -project DynamicIsland.xcodeproj \
  -scheme 'Dynamic Island' \
  -destination 'platform=macOS'
```

## 权限说明

- **Apple Music 自动化**：首次读取或控制音乐时，macOS 会请求允许“Dynamic Island”控制“音乐”。拒绝后可前往“系统设置 > 隐私与安全性 > 自动化”重新开启。
- **用户选择的文件**：文件托盘使用沙盒的用户所选文件读写权限；导入内容会复制到应用临时托盘目录。
- **AirDrop**：分享由系统 `NSSharingService` 提供，实际可用性取决于当前 Mac 的 AirDrop 状态。

项目启用了 App Sandbox，只声明上述功能所需的文件和 Apple Events 权限。

## 工程结构

| 区域 | 主要文件 | 职责 |
| --- | --- | --- |
| 应用入口 | `DynamicIslandApp.swift` | 菜单栏生命周期、服务装配与 accessory 模式 |
| 面板 | `IslandPanelController.swift`、`IslandPanelGeometry.swift` | `NSPanel` 创建、命中区域、屏幕顶边定位和状态尺寸 |
| 状态 | `IslandViewModel.swift` | 展示状态、服务调用、悬停与活动态协调 |
| 界面 | `IslandView.swift`、`IslandTimerToolsView.swift` | 音乐、文件、音量、计时工具和紧凑态 UI |
| 系统服务 | `DynamicIsland/Services/` | CoreAudio、Apple Music、文件托盘、AirDrop 和触觉反馈 |
| 屏幕适配 | `ScreenManager.swift`、`ScreenEnvironment.swift` | 多屏选择、拓扑变化和模拟环境 |
| 测试 | `DynamicIslandTests/` | 几何、状态机、系统服务适配和快照矩阵 |

## 验证

运行与 GitHub Actions 相同的完整测试和 Release 构建：

```bash
./Scripts/ci.sh
```

运行 Spaces、全屏、隐藏菜单栏、合盖和权限拒绝等稳定性场景：

```bash
./Scripts/run-stability-matrix.sh
```

生成屏幕快照矩阵：

```bash
./Scripts/generate-screen-matrix.sh
open artifacts/screen-matrix/index.html
```

生成的矩阵位于被 Git 忽略的 `artifacts/screen-matrix/`，不会污染提交。

## 发布

本地可用下列命令验证 Archive、通用架构 DMG、SHA-256 和 manifest 生成流程：

```bash
./Scripts/release.sh --local
```

该命令产生的是未公证的本地测试包，不可分发。Developer ID、公证凭据、Tag workflow 和干净 Mac 验收步骤见 [发布指南](docs/RELEASING.md)。

## 已知限制

- 音乐集成目前只支持 macOS 自带的 Apple Music，不支持 Spotify 等第三方播放器。
- 秒表、番茄钟和倒计时状态不会跨应用重启恢复。
- 正式 Developer ID 签名与公证需要发布团队凭据；自动更新尚未实现。
- 屏幕矩阵覆盖常见几何组合，但真实硬件、缩放和多显示器排列仍需要持续收集反馈。

## 参与开发

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。Bug 报告、功能建议和屏幕兼容性反馈都有对应的结构化 Issue 模板；Pull Request 会自动执行测试和 Release 构建。

## 许可证

本项目使用 [MIT License](LICENSE)。
