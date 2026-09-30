# Phase 3 — T14 Music Provider 验证记录

初始记录日期：2026-09-23。范围：T14 Music Provider；记录建立时 T15–T17 尚未完成，最终验收见文末。

## 数据与控制迁移

- `MusicActivityProvider` 观察现有 `IslandViewModel` 的音乐、音量、静音与错误状态，继续复用 `AppleMusicControlService` 的 AppleScript、缓存和串行 seek 实现，没有新增第二条媒体控制链路。
- Provider 始终复用 `builtin.music`，发布 `persistent/background` Activity；播放、暂停、切歌、进度、静音和音量变化都更新同一实例。其他 Activity 抢占后，音乐回到前台且实例令牌保持不变。
- `IslandActivityRuntime` 在正式岛体中持有单一 `ActivityManager`、`ActionRouter` 和 Music Provider。`IslandView` 的紧凑态和音乐展开态只渲染当前 Activity 快照，并通过 Router 回传动作；旧的音乐专用 SwiftUI 控件和从 Notch UI 直接调用音乐控制的路径已移除。
- Host 通过当前快照统一判断紧凑态可见性，并按 Activity source 解析 Broker 资源；非音乐来源无法读取或碰撞音乐封面资源。
- 播放进度拖动使用有限的 `slider` payload，松手使用 `sliderCommit`，继续调用原有的节流 seek 与曲目身份校验。Renderer 在拖动期间保留本地滑块值，避免 Activity 更新造成滑块跳动。
- 音乐错误使用独立的 `musicErrorMessage`，后台音乐轮询不会再清除文件拖盘、AirDrop 或系统音量错误。

## 封面与轮询约束

- Activity 只携带固定的 `brokerResource` 标识，不序列化封面字节、路径或 URL。Apple Music 服务在数据进入缓存和 `NowPlayingInfo` 前拒绝超过 4 MiB 或任一边长超过 2048 px 的图片；Provider 只保留一张已通过边界校验的解码图片。
- Host 提供有限的 26 pt thumbnail 和 124 pt artwork token；minimal/compact/expanded 的策略仍限制树深、节点数、文本、图片及动作数量。
- ViewModel 只保留一个 1.5 秒 now-playing 轮询任务。展开时额外运行原有的 250 ms 本地进度推进；打开岛体会立即刷新一次，不创建第二个 AppleScript 轮询器。
- 封面缺失时先按 1 秒重试两次，随后退回 10 秒，避免长期高频读取。

## 验证结果

- `./Scripts/ci.sh`：244 tests、1 skipped、0 failures；Release build passed。
- `./Scripts/generate-screen-matrix.sh`：8 种屏幕配置 × 8 种状态，共 64 张截图生成成功。检查了 MacBook Air 13 的 compact-playing 与 expanded-music：26 pt 缩略图/波形、124 pt 封面占位、曲目信息、进度、时间、播放控制和音量行均位于 Host 外壳内，没有重现 0.5.0 的裁切问题。
- Provider 聚焦测试覆盖固定 ID 更新、paused persistent 状态、抢占恢复、全部动作路由、seek 提交、音量与静音、缓存入口的字节/像素限制、来源隔离、错误隔离和 HostPolicy 三态。

## 当时尚未覆盖

- 真实 Apple Music 自动化权限、真实鼠标拖动和 VoiceOver 仍需要人工设备验收；自动化测试使用可控 MusicService，视觉测试使用屏幕矩阵样例数据。
- T15 已完成系统音量 transient Activity 的代码与自动化闭环，见 [T15 验证记录](phase-3-t15-volume-provider.md)；T16 已完成 Battery Provider 的代码与聚焦自动化测试，但真实设备验收仍在进行，见 [T16 验证记录](phase-3-t16-battery-provider.md)。T17 负责压力、能耗、多显示器和睡眠唤醒回归。因此本记录不代表 Phase 3 已完成。

## 最终验收

上述人工项目已于 2026-09-29 由用户确认验收完成，且未报告阻塞问题。统一结论与证据边界见 [Phase 3 真机验收结论](phase-3-acceptance.md)；T14 状态更新为 `verified`。
