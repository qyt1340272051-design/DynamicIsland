# Phase 2 — IslandNode、Renderer 与动作路由阶段检查

日期：2026-10-20。范围 T09–T13，按 [DevelopmentPlan §15](DevelopmentPlan.md#15-每个阶段的统一检查清单)归并阶段证据。T09、T12、T13 已有分项验收；[T10 视觉与可访问性归并](t10-t11-acceptance-20261019.md)已完成，[T11 / M04 第三轮实机验收](t11-manual-acceptance-20261020.md)补齐同一真实 Timer 的 minimal → compact → expanded。五项任务的完成标准均已满足，Phase 2 可以闭合。

本页是证据归并，没有重新运行测试、启动 App、操作系统设置或修改产品源码。[2026-09-22 的 T12 / T13 记录](phase-2-renderer-action-router.md)保留其历史范围；其中已删除的原生 Pomodoro 适配器与专用测试不作为当前实现依据。

## 当前证据与来源

- [T10 / T11 自动与历史归并](evidence/t10-t11-20261019/result.json)：有限 Host token、两款官方插件真实图像、历史 VoiceOver / Reduce Motion，以及修正后的 24 项定向回归。受控正式 IslandView 图像中的相机间隔仍是该测试的几何证据，不与真实设备坐标混用。
- [M04 实际结果](evidence/manual-remaining-20261019/m04-result.json)：真实 Start / Stop、609 条连续收起 AX 观察及五张原始关键图、重新展开后的时间和进度。完整过程、前两轮边界及时间解释见 [T11 分项记录](t11-manual-acceptance-20261020.md)。
- [普通 Release 副本准备身份](evidence/manual-remaining-20261019/preflight.json)与[2026-10-20 采集后身份复核](evidence/manual-remaining-20261019/preflight-20261020.json)：同一已知验收副本、101 个生产源码摘要匹配、strict / deep 签名通过。本次没有声称重新编译或公开发布 App 0.6.0。
- [M03 实机按钮与生命周期](evidence/manual-remaining-20261019/m03-result.json)：工具切换、状态隔离、停用后菜单移除、显式重新启用归零，以及两按钮原生工具的实际动作。保留“未在实机直接调用旧动作或制造关键抢占”的范围说明。
- [完整回归与普通 Release](evidence/final-regression-20261019/result.json)：1070 passed / 2 skipped / 0 failures；跳过项为显式截图矩阵与默认关闭的实时 GitHub API。该次完整运行早于后来新增的一项独立作者 Host 测试；后者包含在[另一次 8 项 Host 定向](evidence/t38-independent-host-20261019/result.json)中，不合并改写完整 CI 计数。

## 统一检查

| 检查项 | 实际证据与范围 |
| --- | --- |
| 功能 | [IslandNode](../../DynamicIsland/IslandUI/Schema/IslandNode.swift)、[Host 展示策略](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift)及 [Renderer](../../DynamicIsland/IslandUI/IslandRenderer.swift)提供有限数据节点、三态回退与有界内容。M04 第三轮 609 条收起观察均含 Countdown：先仅右侧时间，后为左 timer 图标与右侧时间；随后真实展开显示 03:12、background 回执和约 36% 进度，真实 Stop 返回 idle。计时未向上重置，满足同一 Timer 三态展示标准；本轮没有重跑全部旧功能，旧功能范围继续见 [Phase 3](phase-3-acceptance.md)与[完整回归](evidence/final-regression-20261019/result.json)。 |
| 架构 | Activity / IslandNode 保持纯数据，插件不持有 NSWindow、SwiftUI View 或自由窗口尺寸。正式 [IslandView](../../DynamicIsland/IslandView.swift)由 Host 选择有效收起模式，将 minimal 放入保留中心之外的右翼；compact / expanded 仍走同一实例绑定 Renderer，保留动作、图像与 countdown 解析。窗口展开、工具选择和 Activity 调度分别由 Host 管理，没有新增插件开关或 Pomodoro 专用 Swift。 |
| 并发 | [ActionRouter](../../DynamicIsland/IslandUI/ActionRouter.swift)、ActivityManager 与共享显示时钟在 MainActor 边界执行；异步插件动作通过现有执行 / 实例绑定进入。Router 在授权可能重入后重新验证当前实例和动作声明，旧注册不能撤销新注册。[路由测试](../../DynamicIslandTests/ActionRouterTests.swift)、[真实 VM / ActionSession](../../DynamicIslandTests/PluginActionBridgeTests.swift)及 [Pomodoro 集成](../../DynamicIslandTests/PomodoroPluginTests.swift)覆盖这些边界；M03 另提供真实工具之间状态不串线的观察，不扩大为已穷尽所有线程竞态。 |
| 性能 | 节点深度、总量、子节点和文本字节受 [IslandNode 限额](../../DynamicIsland/IslandUI/Schema/IslandNode.swift)约束，各展示形态另有 HostPolicy 复杂度与高度预算。24 项定向覆盖有效模式、右翼几何及正式 IslandView 同实例切换。[CPU / 内存基线](t02-t08-acceptance-20261019.md)属于 T11 修改前冻结的普通 Release 起点，不能作为修正后 UI 的量化无回退证明。M04 工具观察间隔与 609 条 AX 记录不等于屏幕帧率；本次没有新增 FPS、GPU 或新 UI 资源回退测量。 |
| 能耗 | [IslandCountdownDisplayClock](../../DynamicIsland/IslandUI/IslandCountdownDisplayClock.swift)只为可见、运行中的叶共享一个秒级 Task；隐藏、静态、失效或退出后释放需求，显示脉冲不调用 JavaScript、不推进业务计时。M04 包仅请求一次 Host 集中刷新，没有 JS Timer 或每秒更新 Activity。相关行为由[倒计时 Renderer 测试](../../DynamicIslandTests/IslandCountdownRendererTests.swift)及[节点契约](../../DynamicIslandTests/PluginCountdownNodeBridgeTests.swift)支撑；本轮没有测量修正后 UI 的整机或电池能耗。 |
| 安全 | 插件输入先经过严格 Bridge / [节点转换器](../../DynamicIsland/Plugins/PluginIslandNodeConverter.swift)再进入 Core，Renderer 只映射有限类型与 token，图像标识通过 Host 解析，不能直接变成路径或 URL。Router 验证当前展示、来源、精确实例、动作声明、payload、启用状态与 Host 授权；countdown 叶受来源 / generation 绑定。[恶意节点测试](../../DynamicIslandTests/PluginIslandNodeBridgeTests.swift)、[Countdown 绑定](../../DynamicIslandTests/PluginCountdownNodeBridgeTests.swift)及旧动作回归保留。M04 无资源权限，启用没有新增授权。 |
| 隐私 | Renderer、展示策略与 Router 没有新增节点正文、Token、剪贴板或文件内容日志，也不自行请求网络或读取任意文件。本轮 M03 / M04 归档是自有演示工具的操作与图像，不是用户文件或外部账户数据。系统能力继续经过既有 Broker，整体日志隐私范围见 [Phase 6](phase-6-acceptance.md)；本阶段不引入新的秘密存储或遥测承诺。 |
| 兼容 | Host 几何和可见命中区域保持统一；minimal 仅使用安全翼，空间不足时不占用保留中心。受控几何 / 图像回归和 M04 原图中的左右分列各保留其范围：本轮没有记录实际相机屏幕坐标，不能把截图像素推算成物理相机 point 间距。多屏、缩放、睡眠 / 唤醒、外接屏拔插及 VoiceOver / Reduce Motion 继续引用 [Phase 3 的历史用户验收](phase-3-acceptance.md)；本次没有重新切换这些设备或系统设置，不声称完成新的全矩阵。 |
| 测试 | [T09 节点测试](../../DynamicIslandTests/IslandNodeTests.swift)、[token 测试](../../DynamicIslandTests/IslandDesignTokensTests.swift)、[Presentation 测试](../../DynamicIslandTests/ActivityPresentationTests.swift)、[Renderer 测试](../../DynamicIslandTests/IslandRendererTests.swift)、[正式 IslandView 回归](../../DynamicIslandTests/IslandTimerShellRenderingTests.swift)及当前 Router / VM 契约共同覆盖阶段核心。T11 定向为 24 passed / 0 skipped / 0 failures；完整运行仍为 1070 passed / 2 skipped / 0 failures；M04 是后续实际 UI 验收，不是新增测试计数。早期 fixture 时序与 OCR 失败、修正和定向结果保留在[原生 UI 回归记录](evidence/native-ui-regression-20261019/README.md)中。 |
| 回滚 | T11 改动局限于 Host 的有效布局选择、右翼区域和正式视图接线，不改变 Manifest、wire schema、插件存储或授权记录。可独立撤回显示改动并按原回归检查重验；停用 / 退出仍由现有生命周期撤销来源、动作、倒计时及待刷新。M03 已观察停用移除与重新启用清零，M04 真实 Stop 回到 idle。没有新增用户数据迁移或要求删除已有插件数据。 |

## 阶段结论

T09–T13 的任务完成标准与阶段统一检查已归并，Phase 2 的展示与动作闭环可以标记完成。M04 的关键来源为：相同未改动验收包的 Activity 更新 / generation 检查、正式 Host 的实例契约，以及真实连续计时观察；没有从原生 UI 读取 opaque instance 或 generation，也没有将工具采样频率当成显示帧率。

本阶段结论不自动关闭 T38 稳定 SDK 发布、T39 首次独立作者体验、T40 公开 Registry 下载，亦不构成新的性能基线、设备矩阵或主 App 公开发布验收。其他任务和后续人工安排继续由各自分项记录与主进度表追踪。
