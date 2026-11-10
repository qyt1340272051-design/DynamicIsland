# U04 网易云可选媒体 helper

日期：2026-10-26。此记录描述可选插件构件及 helper 验证边界；不代表网易云完整实机播放验收。

## 构件与分发边界

源码目录：[examples/netease-music](examples/netease-music/README.md)。插件 ID 为 `com.dynamicisland.netease-music`，版本 0.1.0，目标 `com.netease.163music`，最低 Host 0.6.1。声明 `media.read`、`media.control` 两项独立权限与 `music.provider` capability。

插件清单新增 `mediaProvider` 对象，仅含 `targetBundleIdentifier`、`displayName`、`helperPath`、`helperSHA256`。入口仍为 `index.js`，不在 JavaScriptCore 插件 VM 中执行 JXA。helper 作为普通资源保存在可选 `.dip` 内；主程序不捆绑网易云 helper、不安装动态库、不提供任意 native 插件加载器。

Host 固定可信 helper 摘要与目标 Bundle ID，执行 Validator 保存的不可变 helper 字节；不能在运行时重新读取可替换文件。helper 路径与描述符纳入包校验及授权指纹。清单中的 self-reported SHA-256 只作一致性核验，不能代替 Host 的可信摘要策略，也不验证插件发布者身份。其他插件可复用字节完全相同的可信 helper，但不能改变其固定目标或操作范围，且各自继续受显式权限批准约束。代码或清单变化继续遵守独立重新授权规则。

helper SHA-256 为 `37c306a675aa34419a34bc03a412a934953f2b5243c96ee3f9855d5b537a9d32`。

## 进程 ABI

Host 用 Foundation Process 直接执行系统解释器，不经 shell：

```text
/usr/bin/osascript -l JavaScript -e <verified immutable helper source> -- <targetBundleID> <operation> [position] [trackIdentifier]
```

`targetBundleID` 必须为 `com.netease.163music`；helper 内再次固定核对。只允许 `nowPlaying`、`togglePlayPause`、`skipBackward`、`skipForward`、`seek`。除 `seek` 恰好四个参数外，其余操作恰好两个参数。`seek` 的位置单位为秒，必须是有限非负数且不超过当前曲目时长，同时核对当前曲目身份。

成功读取返回单个 JSON 对象，必有 `isPlaying`、`title`、`artist`、`album`、`duration`、`position`、`trackIdentifier`，封面存在时附加 `artworkBase64`。无客户端或无曲目时，返回 false、空字符串与 0 组成的空快照。缺失封面不使读取失败，单张封面数据最多 2 MiB。

控制成功返回 `{"ok":true}`。seek 曲目变化或位置超出当前时长返回 `{"ok":false}`。固定错误格式为 `{"ok":false,"error":"<code>"}`；错误码为 `invalidArguments`、`unsupportedSystem`、`targetNotRunning`、`targetNotActive`、`queryTimedOut`、`queryFailed`、`commandRejected`、`commandTimedOut`、`helperFailed`。不返回路径、系统错误文本或曲目内容作为诊断信息。

每次异步查询与指令等待上限为 1.25 秒；seek 包含一次曲目查询和一次指令等待，合计最多 2.5 秒异步等待。Host 还必须设置整体进程 deadline 和 stdout/stderr 容量上限，处理系统同步接口阻塞、子进程退出及取消。

## 数据和控制路由

读取用 `MRPlayerPath` 的本地 origin、网易云 Bundle ID 和默认 player 构造 `MRNowPlayingRequest`，独立请求元数据、实际播放状态与封面。不会将全局其他播放器数据回退为网易云数据。优先使用系统内容 ID / 唯一 ID 作为曲目标识；缺失时组合标题、歌手、专辑、时长。进度基于该会话 elapsedTime、timestamp 与实际播放状态计算，并约束到曲目时长内。

控制发送前确认网易云进程仍存在，且 `localNowPlayingPlayerPath` 的 client 或 parent Bundle ID 与网易云匹配。使用 `MRMediaRemoteSendCommandToApp` 明确指定网易云与本地 origin，`appOptions=0`；即使活动会话在核对后发生变化，也不会把命令改发给其他播放器。command 2 / 4 / 5 分别为播放暂停、下一首、上一首；seek 用 command 24 与 `kMRMediaRemoteOptionPlaybackPosition`。等待实际 completion 并检查错误及 handler 返回状态；超时不伪报成功。

不启动网易云，不触发其他播放器，不读网易云数据库、账号或 Cookie，不修改客户端设置，不授予辅助功能或录屏权限。

## 原始资料与许可

以下是私有接口研究资料，不构成 Apple 或网易云的兼容承诺：

- [YohakuCompanion JXA provider，固定提交 470bc72](https://github.com/Innei/YohakuCompanion/blob/470bc72ae78b2465c1ddfb8fcb48f1fff63040b1/YohakuCompanion/Core/MediaInfoManager/JXAMediaInfoProvider.swift)：按 Bundle ID 请求 Now Playing、实际状态和 artwork 的接口及 JXA block 桥接方式。
- [WebKit MediaRemoteSPI.h](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/mac/MediaRemoteSPI.h)：`MRMediaRemoteSendCommandToApp` 参数 ABI 与 seek command 24。
- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)：控制命令编号与 macOS 15.4 之后接口限制的研究背景。没有采用它的 Perl/framework 分发方案。

本插件 helper 是依据接口事实独立编写的源码；没有复制上游实现或引入上游二进制。插件源码使用本项目 MIT License。

## 本轮验证

- `/usr/bin/osacompile -l JavaScript` 编译成功。
- 使用 Host 相同的 `osascript -e ... --` 形式，执行一次只读 `nowPlaying`，退出 0，输出可解析空快照。
- 为避免把客户端未运行时的提前返回当作接口验证，另在内存中把 `running()` 替换为 true，并在查询结束处返回仅含回调标志的诊断结果。实际按网易云 Bundle ID 创建请求，`infoCallback=true`、`isPlayingCallback=true`、`artworkCallback=true`、`error=false`，约 0.145 秒退出 0；元数据与封面均为空。该诊断覆盖 JXA `ObjC.block`、Foundation block holder、`objc_msgSend`、dispatch queue、元数据/状态/封面三个实际异步接口；没有启动客户端或执行控制。未写回源码，无需变更可信摘要。
- 错误 Bundle ID、未知 operation 的只读输入测试返回 `invalidArguments`。
- 本机网易云应用包为 3.0.17 / 2880；该版本号来自应用包只读检查，没有升级客户端。

上述为初期只读探测的历史范围。后续经用户明确临时授权，2026-10-26 至 2026-10-27 已完成当前设备的歌曲 / 封面读取、暂停恢复、上下曲、seek 与真实进度拖动；build10 缓存复测与权限清理见[最终结果](evidence/u04-optional-music-20261026/README.md)。其他播放器并行、长时间自动换曲和睡眠唤醒未据此补记为通过。Host 的清单解析、权限撤销、helper 信任与进程边界测试由 U04 主实现分别记录。
