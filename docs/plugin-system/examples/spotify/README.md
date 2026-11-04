# Spotify 可选播放控制插件 0.1.0

插件 ID：`com.dynamicisland.spotify`。适配 macOS Spotify 桌面客户端 `com.spotify.client`。主程序不预装本插件；按需导入 `.dip`、启用，再在音乐设置中选择 Spotify。需要包含本插件 helper 信任摘要的 **Host 0.6.1/build21 或以上版本**；旧 build 的 0.6.1 不支持此 helper。

## 功能与使用

在 Spotify 中先播放一首歌，使 Spotify 成为系统当前活动媒体会话。插件复用Dynamic Island现有的音乐显示与控制，提供歌曲、歌手、专辑、时长、进度、播放状态、系统提供的封面，以及播放/暂停、上一首、下一首和拖动进度。

扩展管理中分别批准：

- `media.read`：读取 Spotify 当前歌曲和本地系统媒体会话中的封面。
- `media.control`：向 Spotify 现有媒体会话发送播放与进度命令。

安装或启用不自动授权。仅批准读取时可显示歌曲，控制仍需独立批准。关闭、卸载或撤销权限后，Host 取消该插件的请求；切换音乐来源不会把失败操作发送给另一个播放器。插件不启动 Spotify，不切换前台应用，不登录账号，不读取 Cookie，不请求网络权限，也不提供歌曲搜索或歌单管理。

控制仅在 Spotify 正在运行且系统当前活动媒体会话属于 Spotify 时执行。其他播放器取得活动会话后，请先回到 Spotify 恢复该会话。拖动进度前会核对曲目标识与时长，切歌后旧曲目的拖动请求返回失败。系统没有提供封面时使用占位图；Host 可复用同曲目已取得的本地封面缓存。

## 实现与兼容性

`index.js` 只提供空生命周期；Host 根据 `mediaProvider` 描述符接入现有音乐界面。`media-helper.js` 仅随可选插件分发，由 Host 核对不可变源码的 SHA-256 与固定 Bundle ID 后，通过系统 `/usr/bin/osascript -l JavaScript` 执行。普通插件 JavaScript 无进程、文件或原生接口；helper 不接受任意脚本、播放器或命令。修改 helper 和 manifest 中的摘要无法自行取得信任，仍需更新 Host 内的可信摘要并重新授权。

当前 helper SHA-256：

```text
d2288f6e59608d8681c3d3b7a6de3f4725e8e3a87fc995c6c31de45c3022141b
```

本机 Spotify 1.3.6.1921 的 `Contents/Resources/Spotify.sdef` 包含公开脚本接口 `current track`、`player position`、`playpause`、`previous track` 和 `next track`；其 `artwork` 属性已废弃，仅提供 `artwork url`。当前插件与网易云适配保持一致，通过本地 `MediaRemote.framework` 读取现有会话和封面并固定路由控制，不发送 Apple Events 或下载封面，所以不额外请求系统自动化或网络权限。该框架属于 macOS 私有接口，系统或 Spotify 更新可能影响兼容性，需逐版本实机验证。

## 本地打包

在仓库根目录运行，输出位置必须不存在：

```sh
python3 SDK/tools/package_plugin.py docs/plugin-system/examples/spotify /tmp/spotify-0.1.0.dip
```

可在「设置 → 插件 → 发现」刷新目录，选择 Spotify 的「下载并查看」，核对预览后安装；也可从 [plugins-music-0.1.0 Release](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/plugins-music-0.1.0) 下载 `.dip` 后导入。安装后仍需单独授权、启用和选择播放来源。

## 验证状态

2026-11-04：核对本机 Spotify 1.3.6.1921 的脚本字典；完成 JXA 语法编译、未知目标/未知命令拒绝、播放器未运行时的空歌曲读取及控制失败检查、SDK 校验和打包。测试没有启动 Spotify 或改变播放状态。

当前设备 Spotify 未运行，因此尚未验收真实歌曲、封面、播放/暂停、上下曲、进度拖动，以及持续收起/不悬停时的刷新。上述实机验证与跨 macOS 兼容验证仍待完成。

源码使用本目录 [MIT License](LICENSE)。沿用本项目原创的网易云可选 provider 协议与 MediaRemote 调用方式，未包含 Spotify 二进制、第三方 helper 或 framework。
