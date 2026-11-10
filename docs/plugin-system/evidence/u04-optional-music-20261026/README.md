# U04 可选音乐适配验证

- [结构化结果](result.json)：build10 最终回归、构件与清理结果；build9 首轮验证保存在独立历史字段中。
- [真实播放补验](playback-verification.json)：临时授权、控制、物理拖动、封面缓存实测与最终恢复；不保存曲名、歌手或封面内容。
- [测试摘要](test-summary.txt)
- [通用设置最小窗口截图](settings-general-minimum.png)：原生 AppKit 测试窗口，不冒充普通 Release 的用户截图。
- [独立网易云插件包及 helper 验证](../u04-netease-helper-20261026/helper-verification.json)

## 自动化与版本边界

build9 首轮完整 `Scripts/ci.sh` 执行 1183 项（1180 通过、3 跳过、0 失败），普通 Release 构建通过；随后新增的沙盒查询测试单独执行 1 项通过，不合并成一次全量运行。完整结果位于 `/tmp/dynamic-island-u04-full.xcresult`，补验位于 `/tmp/dynamic-island-u04-sandbox.xcresult`。此前仓库忽略的 `build/u04/Dynamic Island.app` 副本为 0.6.1/build9，已验证签名。

封面缓存修正后的 build10 最终完整 `Scripts/ci.sh` 执行 1190 项（1187 通过、3 跳过、0 失败），Release 构建通过；结果位于 `/tmp/dynamic-island-u04-build10-full.xcresult`，日志为 `/tmp/dynamic-island-u04-build10-full.log`。媒体服务定向回归为 23 项、0 失败。上述各批次分别留存，不相加，不把旧 App 副本当作新构件。2026-10-27 已实际运行 `build/u04/Dynamic Island.app` 的 0.6.1/build10，核对签名、关于页版本及 App 不含可选脚本；普通 Release 缓存复验通过。

## 安装与真实播放

普通 build9 Release 的真实 GUI 已通过原生输入执行插件导入、预览、安装默认停用、启用及设置来源列表核对。该轮安装后两项权限都是“待授权”，启用后保持不变，Apple Music 仍是所选来源；原有两个插件与托盘数据保留。网易云辅助脚本和资源由独立 `.dip` 提供，未包含在该轮 Release App 中。

用户随后明确批准临时 `media.read` 与 `media.control`。build9 实机已观察到紧凑封面、展开曲目字段和播放 / 暂停按钮状态变化，暂停 / 恢复通过；API 上下曲、跳转进度与过期曲目身份拒绝通过。用户确认真实鼠标拖动进度，记录位置约 1 分 2 秒且保持暂停；原生滑杆增量输入不能替代此物理拖动证据。网易云原暂停歌曲及位置 0 的中间恢复已记录。

## 封面修复及最终清理

真实验证中系统一度同时省略封面回调和原生封面数据，界面显示占位图。build10 使用按播放器、曲目字段及时长匹配的有界内存缓存（8 张 / 8 MiB），并在来源、读取权限或运行会话变化后清理；自动化回归通过。第一次读取且没有缓存的歌曲仍可能因系统省略数据而没有封面。

build10 普通 App 已实际观察到：恢复播放及返回上一首后，系统原始封面为空，紧凑岛仍显示正确的已缓存封面。此次暂停 / 恢复、上下曲及过期曲目拒绝也重新验证通过。

最终已通过真实设置界面撤销 `media.control` 与 `media.read`，核对均为“已撤销”，并恢复 Apple Music 来源；辅助进程计数为 0，插件安装与启用状态保留。由于中断后用户改变了网易云播放，本次恢复继续验收前的曲目、暂停状态及约 13.3 秒位置，没有覆盖为上一轮的 0 秒。其他播放器并行、长时间自动换曲与跨版本兼容未记作已通过。
