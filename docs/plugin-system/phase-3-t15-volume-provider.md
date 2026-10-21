# Phase 3 — T15 Volume Provider 验证记录

初始记录日期：2026-09-28。范围：T15 Volume Provider；记录建立时代码与自动化闭环已完成，真实 Core Audio 验收尚待进行，最终结论见文末。

## 事件边界与回声抑制

- `IslandViewModel` 继续复用现有 `VolumeService` 与 Core Audio 监听，只在监听回调读取到真实状态变化时发布 `VolumeActivityEvent`。初始化读取和岛内主动刷新保持静默，不会在启动时显示音量 Activity。
- 岛内音乐滑块、音量按钮和静音按钮先更新本地模型，再记录 1 秒的预期 Core Audio 回声；相同静音状态且音量误差不超过 `0.01` 的回调会被消费，不会反过来抢占正在操作的音乐界面。写入失败会清除预期回声并回滚本地状态。
- Provider 不按事件值去重。外部音量 A、岛内本地调整到 B、外部再次回到 A 时，第二次 A 仍是有效系统事件并会重新发布。

## Activity 生命周期与正式岛体接入

- `VolumeActivityProvider` 固定复用 `builtin.volume` 与 `builtIn/volume` source，发布 `normal/transient` Activity；连续事件取消前一次待发布任务，经过 40 ms debounce 后只提交最新值。
- 每次发布将 `expiresAt` 更新到当前时间后 1.5 秒，并续展当前 transient 展示。更新保留同一实例令牌；ActivityManager 的连续展示上限仍然生效，因此连续调节不会创建新 ID 或堆积队列。
- minimal、compact、expanded 都使用受限 `IslandNode`，仅包含系统音量图标、百分比和 Host 进度条，不声明动作。三种形态均通过 `ActivityPresentation.HostPolicy`。
- `IslandActivityRuntime` 长期持有 Volume Provider。当前非音乐 Activity 会在 compact 和 expanded 中暂时覆盖旧计时、拖盘或工具内容；隐藏 compact 的 Activity 不会错误压缩计时器宽度。Volume 过期后，后台 Music Activity 恢复且原实例令牌不变。
- 音量布局继续走统一 `IslandRenderer`、Host token 和来源隔离的资源解析路径，没有新增专用 SwiftUI 音量视图。

## 验证结果

- `./Scripts/ci.sh`：254 tests、1 skipped、0 failures；Release build passed。
- Provider 测试覆盖初始静默、40 ms debounce、固定 ID、同实例更新、1.5 秒续期与过期、音乐恢复、无动作、三态 HostPolicy，以及 A → 本地 B → 外部 A 的重复语义事件。
- ViewModel 与 Runtime 测试覆盖外部音量发布、音量与静音本地回声抑制、岛内音乐音量操作不显示系统 HUD、正式 Runtime 抢占状态及 compact 可见性。
- `./Scripts/generate-screen-matrix.sh`：8 种屏幕配置 × 10 种状态，共 80 张截图生成成功。新增 `compact-volume` 和 `expanded-volume`；检查 MacBook Air 13 与外接 1080p 场景，图标、进度条和百分比均位于 Host 外壳内，没有裁切。

## 当时尚未覆盖

- 仍需在真实 Core Audio 输出设备上连续使用键盘音量键、控制中心和岛内滑块，确认设备量化、多声道回调与默认输出设备切换不会产生反馈 Activity，并观察连续动画和 Reduce Motion 行为。
- T16 已完成 Battery Provider 的代码与聚焦自动化测试，但真实设备验收仍在进行，见 [T16 验证记录](phase-3-t16-battery-provider.md)。T17 压力、能耗、多显示器及睡眠唤醒回归尚未完成，因此本记录不代表 Phase 3 已完成。

## 最终验收

上述人工项目已于 2026-09-29 由用户确认验收完成，且未报告阻塞问题。统一结论与证据边界见 [Phase 3 真机验收结论](phase-3-acceptance.md)；T15 状态更新为 `verified`。
