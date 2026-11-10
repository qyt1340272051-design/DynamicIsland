# 网易云音乐可选插件 0.1.0

插件 ID：`com.dynamicisland.netease-music`。最低 Host：0.6.1。适配 macOS 网易云客户端 `com.netease.163music`，无需网易云账号、Cookie 或网络权限。主程序不预装本插件；需要时单独下载、导入 `.dip` 并启用。

## 使用与授权

在 Host 的扩展管理中导入插件，并分别批准两项权限：

- `media.read`：读取网易云当前歌曲、歌手、专辑、时长、进度、播放状态与封面。
- `media.control`：向网易云现有媒体会话发送播放/暂停、上一首、下一首和拖动进度命令。

启用不自动授权。拒绝读取时不读取歌曲；仅批准读取时可显示歌曲，控制仍受独立权限限制。关闭、卸载插件或撤销权限后，Host 应取消对应 helper 调用并撤销会话。读取所得数据不写入日志或持久化存储。

先在网易云客户端播放一首歌。Host 0.6.1/build23 起自动识别音源，无需手动选择；旧 Host 仍使用音乐设置中的来源选择。插件使用现有音乐界面，不另建一个播放器工具页。`index.js` 的生命周期为空；Host 根据 `mediaProvider` 描述符接入音乐服务。

控制只接受系统当前活动媒体会话属于网易云时的操作，同时显式将命令路由到网易云 Bundle ID。它不会启动网易云、切换前台应用或把指令发给其他播放器。其他播放器成为活动会话后，应先回到网易云恢复该会话。

## 可选 helper

`media-helper.js` 是本项目新写的 JXA 源码，不是任意 shell 命令或动态库。Host 仅执行校验后保存的不可变源码，使用固定系统解释器 `/usr/bin/osascript`，并核对目标 Bundle ID 与内置可信 SHA-256；路径和描述符纳入包校验及授权指纹。这个信任策略不验证插件发布者身份；其他插件可复用相同可信 helper，但仍须独立批准权限，不能改变其固定目标和操作范围。修改 helper 内容和清单中的摘要不能自行取得 Host 的可信授权；变更后须随 Host 更新可信摘要，并重新审核权限。

helper 源码 SHA-256：

```text
37c306a675aa34419a34bc03a412a934953f2b5243c96ee3f9855d5b537a9d32
```

它通过系统 `MediaRemote.framework` 的私有接口按网易云 Bundle ID 请求数据。私有接口依赖 macOS 版本，系统变化可能使适配暂时不可用。封面是可选字段；系统未提供时应显示占位图。这里没有网易云搜索、歌单管理、登录或音源播放服务。

## 本地打包

在仓库根目录运行，输出位置必须不存在：

```sh
python3 SDK/tools/package_plugin.py docs/plugin-system/examples/netease-music /tmp/netease-music-0.1.0.dip
```

该包必须由支持 `mediaProvider` 的 Host 0.6.1 或以上版本导入。旧 Host 不能识别新增字段、权限及能力，应拒绝安装。

## 验证边界

初期已通过 JXA 语法编译、只读调用及实际元数据 / 状态 / 封面回调检查。2026-10-26 至 2026-10-27 经用户明确临时授权，当前设备的歌曲与封面显示、播放暂停、上下曲、进度跳转和真实鼠标拖动已验证；Host 0.6.1/build10 的封面缓存实测通过。最终已撤销两项媒体权限并恢复 Apple Music 来源，见[完整播放记录](../../evidence/u04-optional-music-20261026/playback-verification.json)。

系统可能暂时不提供封面，Host 会复用同曲目已收到的封面；首次未缓存曲目仍可能显示占位图。此结论不代替跨 macOS 版本和其他设备的兼容验证。

源码使用本目录 [MIT License](LICENSE)。接口研究来源与 ABI 见 [U04 helper 记录](../../u04-netease-optional-helper-20261026.md)。没有复制或分发第三方 helper 或 framework。
