# Phase 3 — T16 Battery Provider 验证记录

初始记录日期：2026-09-28。范围：T16 Battery Provider；记录建立时代码与聚焦自动化测试已完成，设备验收尚待进行，最终结论见文末。

## 事件驱动的电池服务

- `IOKitBatteryService` 在启动时读取一次 IOKit power source 快照，随后通过 `IOPSNotificationCreateRunLoopSource` 接收电源变化事件，并在 `NSWorkspace.didWakeNotification` 后重新读取。实现中没有定时器或轮询循环。
- `BatteryState` 只保留归一化电量、`ac`/`battery` power source、正在充电和已经充满四项状态。没有内置电池的 Mac 返回 `nil`，不会伪造电池 Activity。
- Provider 将连续硬件通知合并 250 ms 后读取最新状态，避免一次电源切换引起的多次 IOKit 回调反复重建 Activity。
- 正式 App 的 composition root 显式向 `IslandActivityRuntime` 注入 `IOKitBatteryService`。普通 Runtime 默认不连接硬件，测试、预览及其他调用方可注入可控服务。

## 分类、优先级与生命周期

- Battery Provider 固定复用 `builtin.battery` 和 `builtIn/battery` source，不声明动作；minimal、compact、expanded 都使用受限 `IslandNode` 显示电池图标、电量进度和百分比。
- 初始 healthy 和 charging 状态保持静默，避免应用启动时弹出普通提示；初始 low 或 critical 会立即告警，避免启动时漏掉需要处理的低电量状态。运行期间进入 charging 会发布 `normal/transient` Activity，展示 3 秒。
- 使用电池供电时，电量不高于 20% 进入 low，发布 `important/transient` Activity 3 秒；不高于 10% 进入 critical，发布 `critical/critical` Activity。critical 的可见时间由 Host 统一限制为最多 5 秒。
- 阈值带有迟滞：low 进入阈值为 20%、退出阈值为 22%；critical 进入阈值为 10%、退出阈值为 12%。这避免电量在边界附近波动时反复改变优先级。
- 分类变化时，Provider 先结束旧 Activity，再用同一固定 ID 发布新分类，因此新的生命周期策略和优先级获得新的实例令牌。同一分类中的电量变化只更新原实例并保留令牌。
- 同一分类的更新不会延长最初的 transient 过期时间。transient 已经过期后，后续百分比变化不会在相同分类内重新弹出；critical 被 Host 隐藏后，同类更新也不会重新显示。恢复到其他分类并再次进入告警分类时，才会创建新的实例。
- 达到已充满状态或离开告警分类时，现有 Battery Activity 会结束，ActivityManager 按既有队列规则恢复后台音乐或其他可展示内容。

## 当前自动化证据

- [BatteryActivityProviderTests](../../DynamicIslandTests/BatteryActivityProviderTests.swift) 共 9 项，覆盖启动静默与启动告警、charging/low/critical 映射、同实例更新、迟滞、分类切换、过期后不重弹、critical 隐藏后不重显、250 ms 通知合并、观察注销、固定 ID、无动作和三态 HostPolicy。
- [BatteryServiceTests](../../DynamicIslandTests/BatteryServiceTests.swift) 共 4 项，覆盖 IOKit 内置电池解析、无效或非内置 power source、数值归一化，以及真实服务返回 `nil` 或有界电池状态。
- `./Scripts/ci.sh`：268 tests、1 skipped、0 failures；Release build passed。
- `./Scripts/generate-screen-matrix.sh`：8 种屏幕配置 × 13 种状态，共 104 张截图生成成功。新增 `compact-battery-charging`、`expanded-battery-low` 和 `expanded-battery-critical`；检查 MacBook Air 13 与外接 1080p 场景，电池图标、状态标题、进度条和百分比均位于 Host 外壳内，没有裁切。

## 当时尚未覆盖

- 需要在带内置电池的真实 Mac 上验证 AC 接入、拔出、充电和低电量变化确实触发 IOKit 回调，并确认应用沙盒环境不会阻止回调注册或快照读取。
- 需要覆盖 macOS 优化电池充电导致的“连接电源但暂未充电”、充满后停止充电等真实状态组合，确认不会出现重复或错误的 charging 提示。
- 需要执行睡眠后唤醒验收，确认 `NSWorkspace.didWakeNotification` 能刷新睡眠期间变化的电量和电源状态，且不会重复注册观察者。
- 需要测量长时间空闲和频繁电源切换时的 CPU、唤醒次数与能耗，确认事件驱动实现没有隐藏轮询或回调风暴。
- T17 仍需完成 Activity 压力、能耗、多显示器和睡眠唤醒的统一回归，因此 T16 保持 `in progress`，本记录不代表 Phase 3 已完成。

## 最终验收

上述人工项目已于 2026-09-29 由用户确认验收完成，且未报告阻塞问题。统一结论与证据边界见 [Phase 3 真机验收结论](phase-3-acceptance.md)；T16 状态更新为 `verified`。
