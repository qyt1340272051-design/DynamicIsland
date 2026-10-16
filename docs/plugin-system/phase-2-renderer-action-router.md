# Phase 2 — Renderer 与动作路由验证记录

日期：2026-09-22。范围：T12、T13；T10、T11 的正式岛体视觉验收仍在进行中。

## T12：唯一的节点渲染入口

- `IslandRenderer` 在 Host 中映射 IslandNode 的 12 类节点。图片仅由 Host 注入的解析器读取；插件资源 ID 不会在渲染器内变成路径或网络请求。
- Renderer 先经过 `IslandNode` 与 `ActivityPresentation.HostPolicy` 校验，再在 Host 给定的尺寸内渲染；不合法、未知或放不下的布局回退到安全摘要。扩展态在 152/190/200 pt 外壳下分别最多使用 92/130/140 pt 内容高度。
- 定向测试实际创建 `NSHostingView`，覆盖 12 类节点、资源解析回调、非法树回退、同一视图的 minimal/compact/expanded 切换以及三种外壳高度。插件和 Provider 只生成数据节点，不直接生成 SwiftUI 视图。

## T13：实例绑定的动作闭环

本节保留 2026-09-22 的实际验证范围。下述原生计时适配器及其专用测试已在 T35 的 3C 迁移中删除；当前实现与回归证据为 [ActionRouter](../../DynamicIsland/IslandUI/ActionRouter.swift)、[路由测试](../../DynamicIslandTests/ActionRouterTests.swift)及[公开 Pomodoro VM / Router 集成测试](../../DynamicIslandTests/PomodoroPluginTests.swift)。删除范围和对应 CI 见 [T35 记录](phase-7-t35-pomodoro.md)。

- `ActivityManager.currentSnapshot` 将当前 Activity 与 Host 生成的实例令牌一起发布。同一 Activity 更新保留令牌；结束后即使用相同 ID、相同内容和同一时钟重新发布，也换新令牌。
- `ActionRouter` 验证 actionID、有限类型 payload、当前展示状态、来源、实例令牌、到期时间、动作声明、来源启用状态和 Host 授权，然后才调用已注册的来源处理器。旧视图动作、已结束或被抢占的 Activity、禁用来源和非法值均被拒绝。
- 当时的 `PomodoroActivityProvider` 复用 `IslandTimerToolsModel`，发布 persistent Activity，并由 actionID 执行真实的暂停、继续和停止。定向测试从 Activity 快照经 Router 到计时器模型和 Activity 更新/结束完成闭环。
- 当时的 DEBUG Activity 观察窗口可发布样例、启动番茄钟、切换三种展示形态，并把 Renderer 事件连到 Router；这是开发验证入口，正式岛体的内置功能迁移属于 T14–T16。

## 验证结果与边界

- `./Scripts/ci.sh`：220 tests、1 skipped、0 failures；Release build passed。`git diff --check` 通过。
- 离屏 `NSHostingView` 测试确认了渲染边界和视图更新，但不能代替真实鼠标命中、VoiceOver、正式岛体动画、CPU/内存/能耗和多显示器实测。这些仍按 T02、T08、T10、T11、T17 的进度追踪，不据此宣布 Phase 2 全部验收。
- 本次没有接入 JavaScriptCore、插件加载或插件权限；它们仍按 Phase 4 以后执行。回滚点是独立的 T12–T13 提交，不影响 v0.5.0 tag。
