# QQ 音乐与 Spotify 可选插件验证记录

日期：2026-11-04。Host：0.6.1/build21。本目录为本地开发产物，未上传 Release，也未加入 Registry。

## 可导入产物

| 包 | 插件 ID | 固定播放器 |
| --- | --- | --- |
| [qq-music-0.1.0.dip](qq-music-0.1.0.dip) | `com.dynamicisland.qq-music` | `com.tencent.QQMusicMac` |
| [spotify-0.1.0.dip](spotify-0.1.0.dip) | `com.dynamicisland.spotify` | `com.spotify.client` |

安装包及 helper 摘要见 [packages.json](packages.json)。两份 ZIP 均核对恰好包含 manifest、入口、helper、README、LICENSE，逐文件与源码字节一致。构建完成的本机 Release App 在 `/tmp/dynamic-island-qq-spotify-build21/Dynamic Island.app`，版本与 build 已核对，`codesign --verify --deep --strict` 通过。没有替换或重启用户当前运行的 App。

旧 Host 0.6.1 的 Manifest 解析可能通过，但缺少新增 helper pin 时不能启用；请使用本次源码构建的 build21。当前清单只支持语义版本最低限制，不支持最低 build 号。

## 行为与边界

两包沿用网易云可选 provider 接口，接入现有主页音乐层，读取歌曲、歌手、专辑、状态、时长、进度和系统可用封面；控制播放/暂停、上一首、下一首与进度跳转。插件按需安装，Host 只增加可信摘要，不捆绑 helper 资源。不需要账号、Cookie、网络、辅助功能或额外自动化权限。

读取与控制分别受 `media.read` / `media.control` 授权约束。安装默认停用，启用不授予权限或启动 helper。切换来源、撤销权限、停用及卸载会取消在途调用；选中来源不可用时不会将命令发给其他播放器。

固定 Bundle ID 的 helper 仅接受五项操作；控制前核对目标已运行且持有系统当前活动媒体会话，seek 另核对曲目与时长，并在读取后再次检查活动目标。它依赖 macOS 私有 MediaRemote 接口；客户端或系统更新可能影响功能。Spotify 的本机脚本字典虽提供公开接口，但本次统一沿用本地媒体会话方案，以避免新增 Apple Events 授权与封面网络下载路径。

## 已完成验证

- 两个 helper 经 JXA 编译通过；错误目标、未知操作和额外参数拒绝；未运行播放器时读取空状态，控制拒绝。测试未启动播放器或改变播放状态。
- `./Scripts/check-plugin-sdk.sh`：45 项 Python 测试、全部示例预检、三个媒体 helper/入口语法、节点和 TypeScript 合约通过。该脚本新增三款媒体插件的持续预检。
- Xcode 定向测试：69 passed / 0 failed，结果 `/tmp/dynamic-island-qq-spotify-focused.xcresult`。
- `./Scripts/validate-release-config.sh`：0.6.1/build21 配置通过。
- Release 构建通过，日志 `/tmp/dynamic-island-qq-spotify-release.log`；未跑全量 CI。

| XCTest 测试类 | 通过数 |
| --- | ---: |
| OptionalMusicPluginIntegrationTests | 7 |
| PluginMusicControlServiceTests | 25 |
| MusicRefreshLatencyTests | 6 |
| IslandCompactMusicRefreshTests | 3 |
| MusicActivityProviderTests | 7 |
| MusicControlServiceTests | 21 |

7 项安装集成测试使用三个真实源码包和生产可信摘要，通过真实 Installer、Manager、Runtime、Permission、Lifecycle、Registry 与 Router 链路。只替换系统 helper runner，不控制真实客户端。覆盖三包安装默认禁用、独立授权、禁用/卸载取消，以及 QQ/Spotify 共存时全部五项操作精确路由和切源取消。

复现命令（结果目录需不存在）：

```sh
xcodebuild test -project DynamicIsland.xcodeproj -scheme 'Dynamic Island' \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -resultBundlePath /tmp/dynamic-island-qq-spotify-focused.xcresult \
  -only-testing:DynamicIslandTests/OptionalMusicPluginIntegrationTests \
  -only-testing:DynamicIslandTests/PluginMusicControlServiceTests \
  -only-testing:DynamicIslandTests/MusicRefreshLatencyTests \
  -only-testing:DynamicIslandTests/IslandCompactMusicRefreshTests \
  -only-testing:DynamicIslandTests/MusicActivityProviderTests \
  -only-testing:DynamicIslandTests/MusicControlServiceTests
```

## 待真实客户端验收

本机未安装 QQ 音乐，Spotify 1.3.6.1921 已安装但未运行。没有将本次插件安装到用户正在使用的 Host，也没有自动批准媒体权限。

- 两个客户端的真实歌曲、封面、播放状态、暂停/继续、上下曲及进度拖动。
- 自动换歌、仅封面变化、持续收起且不悬停时的刷新。
- 其他播放器抢占媒体会话后的拒绝控制，以及恢复目标播放后的可用性。
- 真机撤权、停用、卸载时的显示与取消反馈，以及不同 macOS/客户端版本兼容性。

自动化测试不代替这些验收。源码和使用说明见 [QQ 音乐](../../examples/qq-music/README.md)与 [Spotify](../../examples/spotify/README.md)。
