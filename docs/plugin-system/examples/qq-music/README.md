# QQ 音乐可选插件 0.1.0

插件 ID：`com.dynamicisland.qq-music`。适配 macOS 桌面版 QQ 音乐 `com.tencent.QQMusicMac`，不是 QQ 聊天客户端，也不包含 iOS/iPadOS 版。无需 QQ 音乐账号、Cookie 或网络权限。插件单独打包、按需导入和启用，不随 Host 预装。

## 使用

需要包含本 helper 可信摘要的 **Host 0.6.1/build21 或更新版本**；旧 0.6.1 虽能解析清单，却不认识此 helper 摘要，不能启用。

1. 在「设置 → 插件 → 发现」刷新目录，选择 QQ 音乐的「下载并查看」，核对预览后安装；也可从 [plugins-music-0.1.0 Release](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/plugins-music-0.1.0) 下载 `.dip` 后导入。
2. 分别批准 `media.read`（歌曲、歌手、专辑、时长、进度、状态与可用封面）和 `media.control`（播放/暂停、上一首、下一首、拖动进度）。启用不会自动授权；逐项决定后启用插件。
3. 手动打开 QQ 音乐并播放一首歌，在 Host 音乐设置中选择 **QQ 音乐**。

插件接入现有音乐界面，不新增工具页。仅批准读取时仍不能控制播放。撤销权限、停用或卸载会取消对应请求；不会降级到操作其他播放器。

## 控制范围

helper 固定目标 `com.tencent.QQMusicMac`，只接受 `nowPlaying`、`togglePlayPause`、`skipBackward`、`skipForward`、`seek`。控制前会同时核对 QQ 音乐已运行、系统当前活动媒体会话属于 QQ 音乐；跳转进度还会核对曲目标识及有效时长，元数据读取后再检查活动会话。

不会启动播放器、切换前台应用、发送全局媒体键或控制 QQ 聊天客户端。其他应用成为系统活动媒体会话时，请先回到 QQ 音乐恢复播放。播放器未运行时读取返回空状态，控制返回失败。

## helper 与兼容性

`media-helper.js` 复用本项目 NetEase provider 的 MediaRemote 适配结构，通过系统私有 `MediaRemote.framework` 按目标 Bundle ID 读取及发命令。它不是 QQ 音乐官方 SDK；客户端未发布系统媒体会话、私有接口变化或系统未提供封面时，功能可能受限。首次没有封面会显示占位图。

Host 使用固定 `/usr/bin/osascript -l JavaScript` 执行校验后保存的不可变源码，并核对目标 Bundle ID 与以下 SHA-256。修改 helper 或清单不能自行获得 Host 信任，需要更新 Host 摘要及重新授权。插件 VM 无进程、文件系统或任意命令执行接口。

```text
422c5eb11cf94e523c7427b953e83d0e6f1b94850897ffbb529a9abd9d44b9ec
```

没有账号登录、在线搜索、歌单管理、歌词抓取或音源播放服务。

## 本地打包

仓库根目录执行，输出路径必须不存在：

```sh
python3 SDK/tools/package_plugin.py docs/plugin-system/examples/qq-music /tmp/qq-music-0.1.0.dip
```

## 验证记录与边界

2026-11-04：确认本机未安装 QQ 音乐；未启动、安装播放器或改变播放状态。本插件通过 JXA 语法编译，播放器未运行时读取为空，控制失败，错误目标和未知操作被拒绝；SDK 清单验证及打包结果见本次实现记录。以上不代表真实 QQ 音乐元数据、封面及控制已通过验收。

仍需在安装桌面版 QQ 音乐的设备验证：歌曲/封面、播放暂停、上下曲、拖动进度、其他播放器抢占后拒绝控制，以及授权撤销/停用/卸载和持续紧凑态更新。不同客户端、macOS 版本分别验收。

## 来源

- [QQ 音乐官方 Mac 下载页](https://y.qq.com/n/ryqq_v2/download_detail/mac) 确认目标是 macOS 桌面客户端。
- [Apple 官方目录接口](https://itunes.apple.com/lookup?id=595615424&country=cn) 在 2026-11-04 返回桌面版 `bundleId: com.tencent.QQMusicMac`，版本 `11.10.5`；[Mac App Store 页面](https://apps.apple.com/cn/app/id595615424) 对应同一产品。
- MediaRemote 的接口结构沿用本项目已有媒体适配实现。适配 QQ 音乐的可用性仍需真实客户端验证。

本目录源码使用 [MIT License](LICENSE)。不包含第三方播放器或 framework。
