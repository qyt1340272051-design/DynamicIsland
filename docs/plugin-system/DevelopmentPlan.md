DynamicIsland 插件系统

详细开发执行方案与任务注意事项

Activity-first · JavaScriptCore · Declarative UI · Permission Broker ·
SuperIsland Compatibility

| 文档用途 \| 作为 DynamicIsland 插件系统从架构重构到公开 SDK
  的开发执行手册 \|

| --- \| --- \|

| 推荐主路线 \| Activity Engine → Renderer → Built-in Migration → Plugin
  Core → JavaScriptCore → Security → Installer → Compatibility → SDK \|

| 首版插件技术 \| JavaScriptCore + Manifest + 声明式 IslandNode UI \|

| 核心原则 \| 插件发布 Activity，不直接控制 NSWindow/SwiftUI；系统能力经
  Permission Broker 提供 \|

| 版本策略 \| Alpha：Activity
  底座；Beta：第三方插件闭环；1.0：兼容层、SDK、Registry \|

## 1. 开发目标与不可破坏的架构原则

本次开发不是简单增加"插件加载"功能，而是将 DynamicIsland
重构为统一的实时 Activity
平台。内置音乐、音量、电池、文件等能力与第三方插件最终都通过同一
Activity Engine 进入调度和渲染层。

-   Activity 是纯数据模型，不携带 AnyView、NSView、NSWindow 或任意
    SwiftUI View。

-   第三方插件只能发布、更新、结束 Activity；不能直接 open/close/expand
    刘海窗口。

-   Renderer 由 Host 掌握，插件只能使用受控的 IslandNode 声明式组件。

-   权限由 Host 的 PermissionManager/Broker 强制执行，Manifest
    声明本身不等于授权。

-   优先使用事件驱动；限制高频 Timer、轮询、网络请求和 Activity 刷新。

-   先让内置模块使用新 API，再开放给第三方，避免发布一套自己都不好用的
    SDK。

-   SuperIsland 仅作为兼容输入，不作为 DynamicIsland 核心 API
    的设计约束。

-   第一版不做 Native Swift/XPC 插件商店；先完成 JavaScriptCore
    插件闭环。

## 2. 总体阶段与依赖顺序

``` text
Phase 0  项目审计与基线
   ↓
Phase 1  Activity Engine
   ↓
Phase 2  IslandNode + Renderer
   ↓
Phase 3  内置功能迁移 / Dogfooding
   ↓
Phase 4  Plugin Core + Manifest
   ↓
Phase 5  JavaScriptCore Runtime + Bridge
   ↓
Phase 6  Permission / Security / Scheduler
   ↓
Phase 7  .dip 安装与 Extensions UI
   ↓
Phase 8  SuperIsland Compatibility Layer
   ↓
Phase 9  SDK / 示例插件 / Registry / 文档
```

强依赖阶段不要跳过。尤其 Phase 1--3 必须先稳定；否则 PluginManager
会建立在仍然变化的 UI 和窗口逻辑之上，后续返工成本很高。

## 3. 任务总表

| 编号 \| 任务 \| 阶段 \| 重要度 \| 关键前置 \|

| --- \| --- \| --- \| --- \| --- \|

| T01 \| 项目架构审计 \| 0 \| ★★★★★ \| 无 \|

| T02 \| 开发分支与基线测试 \| 0 \| ★★★★ \| T01 \|

| T03 \| IslandActivity \| 1 \| ★★★★★ \| T01 \|

| T04 \| ActivityPriority \| 1 \| ★★★★★ \| T03 \|

| T05 \| ActivityLifecycle \| 1 \| ★★★★ \| T03 \|

| T06 \| ActivityManager \| 1 \| ★★★★★ \| T03--T05 \|

| T07 \| Priority Queue \| 1 \| ★★★★★ \| T06 \|

| T08 \| Activity Scheduler \| 1 \| ★★★★★ \| T07 \|

| T09 \| IslandNode \| 2 \| ★★★★★ \| T03 \|

| T10 \| DesignTokens \| 2 \| ★★★★ \| T09 \|

| T11 \| Presentation Model \| 2 \| ★★★★★ \| T09 \|

| T12 \| IslandRenderer \| 2 \| ★★★★★ \| T09--T11 \|

| T13 \| ActionRouter \| 2 \| ★★★★★ \| T12 \|

| T14 \| Music Provider \| 3 \| ★★★★★ \| T06--T13 \|

| T15 \| Volume Provider \| 3 \| ★★★★ \| T14基础 \|

| T16 \| Battery Provider \| 3 \| ★★★★ \| T14基础 \|

| T17 \| Activity 压力与回归测试 \| 3 \| ★★★★★ \| T14--T16 \|

| T18 \| PluginManifest \| 4 \| ★★★★★ \| T17 \|

| T19 \| PluginValidator \| 4 \| ★★★★★ \| T18 \|

| T20 \| PluginManager \| 4 \| ★★★★★ \| T18--T19 \|

| T21 \| Plugin Lifecycle \| 4 \| ★★★★ \| T20 \|

| T22 \| JavaScriptCore Runtime \| 5 \| ★★★★★ \| T20 \|

| T23 \| JS Bridge \| 5 \| ★★★★★ \| T22 \|

| T24 \| JS → Activity \| 5 \| ★★★★★ \| T23 \|

| T25 \| JS → IslandNode \| 5 \| ★★★★★ \| T23 \|

| T26 \| JS Action Bridge \| 5 \| ★★★★★ \| T23 \|

| T27 \| Plugin Storage \| 5 \| ★★★★ \| T23 \|

| T28 \| PermissionManager \| 6 \| ★★★★★ \| T23 \|

| T29 \| NetworkBroker \| 6 \| ★★★★★ \| T28 \|

| T30 \| File/Clipboard Broker \| 6 \| ★★★★ \| T28 \|

| T31 \| PluginScheduler \| 6 \| ★★★★★ \| T22 \|

| T32 \| Crash Watchdog / Logging \| 6 \| ★★★★ \| T22 \|

| T33 \| Extensions Settings UI \| 7 \| ★★★★ \| T20 \|

| T34 \| .dip Installer \| 7 \| ★★★★ \| T19,T28 \|

| T35 \| Pomodoro 官方插件 \| 7 \| ★★★★★ \| T24--T34 \|

| T36 \| GitHub 官方插件 \| 7 \| ★★★★★ \| T35 \|

| T37 \| SuperIsland Adapter \| 8 \| ★★★ \| T35 \|

| T38 \| DynamicIsland SDK \| 9 \| ★★★★ \| T36 \|

| T39 \| 开发者文档与模板 \| 9 \| ★★★★ \| T38 \|

| T40 \| Plugin Registry \| 9 \| ★★★ \| T38 \|

## 4. Phase 0 --- 项目审计、分支与基线

目标：在不改变现有用户行为的前提下，识别窗口、状态、动画、音乐和系统事件之间的耦合关系，并建立后续重构可比较的性能与功能基线。

#### T01 项目架构审计

任务方向：画出当前代码的真实依赖图，找出所有直接操作刘海窗口、展开状态、动画和业务状态的位置。

开发步骤：

1.  列出现有 Target、目录和关键 Swift 文件。

2.  搜索
    NSWindow/NSPanel、isExpanded、show/hide、withAnimation、音乐状态、通知监听等入口。

3.  标记每个功能的数据源、状态持有者、UI 渲染者和窗口控制者。

4.  输出"现状依赖图"和"准备迁移到 Activity Engine 的调用点清单"。

注意事项：

-   不要边审计边大规模重构。

-   特别关注全局单例、NotificationCenter、Combine publisher 和直接修改
    UI state 的代码。

-   记录多显示器、无刘海设备、外接显示器时窗口定位逻辑，后续 Activity
    层不能破坏它。

完成标准：能够明确回答：谁控制窗口、谁控制展开、每个内置功能如何触发
UI、哪些调用必须被 ActivityManager 替代。

#### T02 开发分支与基线测试

任务方向：为插件架构建立可回退的开发环境和量化基线。

开发步骤：

1.  创建 feature/plugin-architecture 分支。

2.  记录 App 启动、空闲
    CPU/内存、音乐播放、动画、多显示器、睡眠唤醒等表现。

3.  为核心功能建立最小回归清单。

4.  必要时添加 Debug 菜单或日志开关。

注意事项：

-   不要直接在 main 上重构。

-   性能指标至少保持相同数量级；插件架构不能显著增加空闲能耗。

-   每完成一个阶段都回跑基线。

完成标准：存在可重复执行的基线清单，并可在每个阶段比较是否发生功能或性能回退。

## 5. Phase 1 --- Activity Engine

目标：所有功能从"直接操作刘海"转为"发布
Activity"。这是插件系统的核心，不应被 JavaScript 或 SuperIsland API
反向约束。

#### T03 IslandActivity

任务方向：定义与 UI 框架解耦的 Activity 纯数据模型。

开发步骤：

1.  创建 Core/Activity/IslandActivity.swift。

2.  定义
    id、source、priority、lifecycle、presentation、createdAt、expiresAt、actions
    等字段。

3.  确保模型可 Sendable/Codable 的部分尽量可序列化，为 JS Bridge
    做准备。

4.  为更新语义定义稳定 ID：同一事件更新必须复用 Activity ID。

注意事项：

-   禁止 AnyView、NSView、NSWindow、Closure 等不可跨边界对象进入模型。

-   source 必须能区分 built-in、plugin 和 external event。

-   不要过早加入几十个字段；优先稳定最小语义。

完成标准：可以仅用数据构造 Music、Battery、Download 三类 Activity。

#### T04 ActivityPriority

任务方向：建立有限、可预测的抢占等级。

开发步骤：

1.  定义 background、normal、important、critical。

2.  为内置场景建立默认映射。

3.  定义同优先级排序：创建时间、当前显示状态、是否可中断。

注意事项：

-   不要暴露任意整数优先级给插件。

-   critical 只能用于少数系统级场景；未来第三方 critical 应受权限或 Host
    降级。

完成标准：多个 Activity 同时进入时顺序可预测、可测试。

#### T05 ActivityLifecycle

任务方向：明确瞬时、持久、进度型 Activity 的状态变化。

开发步骤：

1.  定义 queued、presented、background、dismissed、ended。

2.  定义 transient、persistent、progress、critical 等行为策略。

3.  规定 expiresAt、用户 dismiss、source end 三种结束路径。

注意事项：

-   dismissed 与 ended
    不应混淆：前者可能仅隐藏，后者代表数据生命周期结束。

-   避免生命周期 callback 过多导致状态机复杂。

完成标准：AirPods 3
秒提示、持续音乐、下载进度和低电量都能用统一生命周期表达。

#### T06 ActivityManager

任务方向：成为唯一 Activity 写入口和当前 Activity 状态源。

开发步骤：

1.  实现 publish、update、dismiss、end。

2.  对 ID 冲突、非法状态转换和过期 Activity 做保护。

3.  向 UI 暴露只读 current/presented state。

4.  加入结构化日志，记录 source、id、transition、reason。

注意事项：

-   插件和内置模块都不能绕过 Manager 直接修改当前展示状态。

-   确保主线程 UI 更新与后台事件之间的并发边界清晰。

完成标准：Debug Provider 可发布/更新/结束 Activity，UI 层只观察 Manager
输出。

#### T07 Priority Queue

任务方向：解决多个 Activity 同时出现时的排序、抢占和恢复。

开发步骤：

1.  实现队列排序。

2.  记录被抢占的 persistent Activity。

3.  定义 critical/important 对 normal/background 的抢占规则。

4.  定义过期和重复事件合并策略。

注意事项：

-   避免连续事件造成刘海闪烁。

-   相同 source 的高频 update 应更新原 Activity，而不是不停创建新项。

完成标准：Music → GitHub → AirPods → Battery Critical → 恢复 Music
的顺序稳定。

#### T08 Activity Scheduler

任务方向：控制显示时长、恢复、自动结束和 Presentation 调度。

开发步骤：

1.  建立 duration policy。

2.  实现 transient 自动返回上一个 persistent Activity。

3.  加入 debounce/coalescing。

4.  为未来插件设置每 source 的展示频率限制接口。

注意事项：

-   Scheduler 与 PluginScheduler 是不同层：前者调度 UI
    Activity，后者调度插件后台执行。

-   不要使用大量独立 Timer；优先集中调度。

完成标准：快速连续触发 20
个普通事件时不会疯狂闪烁，关键事件仍能及时显示。

## 6. Phase 2 --- 声明式 UI 与 Renderer

目标：插件和 Activity 只描述"显示什么"，Host 决定"如何用 SwiftUI 显示"。

#### T09 IslandNode

任务方向：定义可序列化的声明式 UI 树。

开发步骤：

1.  首版支持
    Text、Icon、Image、HStack、VStack、ZStack、Spacer、Divider、Progress、Button、Toggle、Slider。

2.  为每种节点定义 Codable 数据结构。

3.  限制树深度、children 数量和字符串长度。

注意事项：

-   第一版不要追求网页级自由度。

-   Image 要区分本地插件资源、系统 symbol、远程资源；远程加载必须走
    Broker。

完成标准：能够用纯 IslandNode 构造计时器、构建状态和音乐摘要 UI。

#### T10 DesignTokens

任务方向：统一字体、颜色、间距、圆角和状态色。

开发步骤：

1.  定义 typography：caption/body/headline/title/metric。

2.  定义 spacing：xs/sm/md/lg。

3.  定义 semantic
    color：primary/secondary/accent/success/warning/danger。

4.  定义 compact/expanded 的尺寸约束。

注意事项：

-   禁止插件自由设置任意字号、padding、cornerRadius。

-   Design Token 需要支持深色模式和可访问性。

完成标准：不同插件使用同一组件时具有一致视觉语言。

#### T11 Presentation Model

任务方向：统一 minimal、compact、expanded 三种展示形态。

开发步骤：

1.  定义 ActivityPresentation。

2.  规定每种状态允许的最大复杂度和高度。

3.  定义缺失某个 presentation 时的降级规则。

注意事项：

-   不要允许插件直接给窗口 width/height。

-   expanded 不是任意大窗口；需要保留刘海产品定位。

完成标准：同一 Timer Activity 可从 minimal 平滑进入 compact/expanded。

#### T12 IslandRenderer

任务方向：将 IslandNode 唯一地映射为 SwiftUI。

开发步骤：

1.  创建 IslandRenderer。

2.  逐节点实现 ViewBuilder 渲染。

3.  统一动画、hover、transition、accessibility label。

4.  加入非法节点/未知节点 fallback。

注意事项：

-   Renderer 是唯一知道 IslandNode → SwiftUI 映射的地方。

-   不要在插件 Bridge 或业务 Provider 中散落 SwiftUI。

-   必须防止过深树造成性能问题。

完成标准：测试 UI 树均能稳定渲染，无插件代码接触 SwiftUI。

#### T13 ActionRouter

任务方向：把声明式按钮 actionID 路由回 Activity source。

开发步骤：

1.  ActivityAction 使用字符串/结构化 actionID。

2.  用户交互 → ActionRouter → source handler。

3.  支持 payload，但限制大小和类型。

4.  处理 source 已结束、插件已禁用等失效动作。

注意事项：

-   不要在 Activity 中保存 Swift Closure。

-   Action 必须经过权限与生命周期检查。

完成标准：Pomodoro 的 pause/resume/stop 可通过 actionID 完成闭环。

## 7. Phase 3 --- 内置功能迁移与 API 自测

目标：先让自己的功能成为 Activity API
的第一批消费者。如果内置功能迁移困难，应修改
API，而不是把困难留给第三方。

#### T14 Music Provider

任务方向：将音乐状态转换为 persistent/background Activity。

开发步骤：

1.  把当前音乐数据源封装为 MusicActivityProvider。

2.  播放/暂停/切歌只更新同一 Activity。

3.  将控制动作接入 ActionRouter。

4.  验证其他 Activity 抢占后音乐可恢复。

注意事项：

-   不要重写底层媒体控制，只重构 UI 发布路径。

-   封面更新频率和图片缓存要受控。

完成标准：音乐功能与当前版本等价，且不再直接操作 Notch UI。

#### T15 Volume Provider

任务方向：将音量变化变成短生命周期 transient Activity。

开发步骤：

1.  监听现有音量事件。

2.  复用固定 Activity ID 更新数值。

3.  设置约 1--2 秒自动消失。

4.  连续调音量时 debounce 并延长同一 Activity。

注意事项：

-   不要每个音量刻度创建新 Activity。

-   避免与系统 HUD 监听形成反馈循环。

完成标准：连续调音量动画稳定，不产生队列堆积。

#### T16 Battery Provider

任务方向：验证不同优先级与生命周期。

开发步骤：

1.  Charging → normal transient。

2.  Low battery → important。

3.  Critical battery → critical。

4.  电量持续变化使用 update。

注意事项：

-   critical 提示不要无限霸占 UI；需要可定义恢复策略。

-   避免频繁读取硬件造成能耗。

完成标准：优先级抢占与恢复符合设计。

#### T17 Activity 压力与回归测试

任务方向：在开放插件前验证 Activity Engine 的稳定性。

开发步骤：

1.  模拟 20--100 个 Activity publish/update/end。

2.  模拟同一秒多个 source 事件。

3.  跑多显示器、睡眠唤醒、音乐播放、窗口动画回归。

4.  记录 CPU、内存、动画掉帧。

注意事项：

-   如果这一阶段仍出现状态竞争，不要进入 Plugin Runtime。

-   优先修复状态机而不是增加补丁延迟。

完成标准：Activity Engine 在压力下无明显泄漏、闪烁、死锁和状态错乱。

## 8. Phase 4 --- Plugin Core

目标：建立插件身份、发现、验证和生命周期，但此阶段仍不急于提供大量系统能力。

#### T18 PluginManifest

任务方向：定义稳定、版本化的插件描述格式。

开发步骤：

1.  加入
    schemaVersion、id、name、version、engine、entry、minimumHostVersion、permissions、capabilities。

2.  定义严格 JSON Schema。

3.  定义 plugin ID 命名规则。

注意事项：

-   必须从 V1 就有 schemaVersion。

-   未知权限默认拒绝，而不是忽略。

-   版本比较使用语义化版本。

完成标准：合法/非法 Manifest 有明确解析结果和错误信息。

#### T19 PluginValidator

任务方向：在执行任何第三方代码之前完成静态验证。

开发步骤：

1.  验证 Manifest。

2.  验证入口文件存在。

3.  检查文件大小、数量、路径、symlink。

4.  检查重复 ID 和 Host 版本。

注意事项：

-   防止 ../ path traversal。

-   不要在验证前执行 index.js。

-   压缩包解压必须限制总展开大小。

完成标准：恶意路径、缺入口、超大包、重复 ID 均被拒绝。

#### T20 PluginManager

任务方向：负责发现、启停、加载和卸载插件。

开发步骤：

1.  实现 discover/load/enable/disable/reload/uninstall。

2.  保存启用状态和版本。

3.  插件异常不能破坏其他插件列表。

注意事项：

-   PluginManager 不负责 UI Renderer。

-   不要把权限、网络、文件逻辑全部塞进 Manager。

完成标准：多个插件可以独立启停，状态重启后可恢复。

#### T21 Plugin Lifecycle

任务方向：统一 installed/loaded/running/suspended/stopped/disabled。

开发步骤：

1.  定义允许的状态转换。

2.  App 睡眠、低电量、插件禁用时进入正确状态。

3.  为 onStart/onStop 等少量生命周期事件建立 Bridge。

注意事项：

-   不要设计过多 callback。

-   卸载前必须结束该插件所有 Activity。

完成标准：禁用插件后不再执行代码、不保留可交互 Activity。

## 9. Phase 5 --- JavaScriptCore Runtime

目标：形成第一个真正的第三方插件执行闭环。V1 以 JavaScriptCore
为主，避免 Swift ABI、签名和 XPC 的早期复杂度。

#### T22 独立 JavaScriptCore Runtime

任务方向：每个插件拥有独立 JSContext。

开发步骤：

1.  创建 PluginRuntime。

2.  每插件创建独立 JSContext。

3.  注入最小 island 全局对象。

4.  设置异常 handler 和 teardown。

注意事项：

-   不同插件禁止共享全局对象。

-   JSContext 不是完整安全沙箱；敏感能力仍必须只通过受控 Bridge 暴露。

完成标准：Plugin A 的异常和全局变量不影响 Plugin B。

#### T23 JS Bridge

任务方向：建立 JavaScript 与 Swift Core 的唯一通信层。

开发步骤：

1.  定义 island.log、island.activity、island.storage、island.actions。

2.  所有参数先验证再进入 Core。

3.  为 Bridge 方法定义版本。

注意事项：

-   不要直接把 FileManager、URLSession、NSWorkspace 暴露给 JS。

-   Bridge 必须假定插件输入不可信。

完成标准：JS 可发布简单 Activity、记录日志和读写插件私有存储。

#### T24 JS → Activity

任务方向：把插件对象转换为 IslandActivity。

开发步骤：

1.  解析 id/priority/lifecycle/presentation/actions。

2.  对 priority 做 Host 限制。

3.  为插件自动添加 source namespace。

4.  限制 publish/update 频率。

注意事项：

-   插件不得伪造 built-in source。

-   critical 等高级行为必须可被 Host 降级。

完成标准：GitHub Mock 插件可发布并更新构建 Activity。

#### T25 JS → IslandNode

任务方向：将声明式 JS UI 安全转换为 UI Tree。

开发步骤：

1.  解析节点类型。

2.  校验属性、children、树深度、文本长度。

3.  未知节点使用 fallback 或拒绝。

注意事项：

-   不能允许任意 Swift 类名或动态 selector。

-   远程图片地址不应由 Renderer 直接请求。

完成标准：恶意或错误 UI Tree 不会导致 App 崩溃。

#### T26 JS Action Bridge

任务方向：把用户交互返回对应插件。

开发步骤：

1.  ActionRouter 找到 plugin source。

2.  调用插件注册的 action handler。

3.  限制 payload。

4.  插件停止后自动丢弃 action。

注意事项：

-   处理重入：action handler 中再次 publish/update 必须安全。

完成标准：按钮、Toggle、Slider 均可从 SwiftUI 回传 JS。

#### T27 Plugin Storage

任务方向：提供每插件隔离的简单 KV 存储。

开发步骤：

1.  定义 get/set/remove/clear。

2.  按 plugin ID 隔离 namespace。

3.  设置容量限制。

4.  后续可扩展 secure secret storage。

注意事项：

-   Token/API Key 不应默认存普通明文 KV；后续应走 Keychain Broker。

-   卸载时明确是否清除数据。

完成标准：两个插件使用相同 key 不会互相读取。

## 10. Phase 6 --- 权限、安全、能耗与稳定性

目标：Manifest 声明、用户同意、Host 强制执行、Runtime 隔离四层同时成立。

#### T28 PermissionManager

任务方向：集中管理权限声明、授权状态和运行时检查。

开发步骤：

1.  V1 定义
    network、storage.local、notifications.publish、clipboard.read/write、calendar.read、files.userSelected。

2.  定义 requested/granted/denied/revoked。

3.  每次 Broker 调用检查权限。

注意事项：

-   未知权限默认拒绝。

-   未来 shell.execute、accessibility、automation、fullDisk
    属于高危能力，不能按普通权限处理。

完成标准：撤销权限后插件下一次调用立即失败并得到明确错误。

#### T29 NetworkBroker

任务方向：所有插件网络访问经 Host 代理。

开发步骤：

1.  实现 fetch 风格 API。

2.  检查 network 权限。

3.  限制 timeout、响应大小、并发数。

4.  可选支持 domain allowlist。

注意事项：

-   防止无限下载和巨型响应。

-   日志避免记录 Authorization token。

-   考虑 SSRF/localhost 访问策略。

完成标准：GitHub 插件无需接触 URLSession 即可访问 API。

#### T30 File/Clipboard Broker

任务方向：把文件和剪贴板能力放在显式授权边界后。

开发步骤：

1.  files.userSelected 通过 NSOpenPanel/系统选择流程获取资源。

2.  clipboard.read/write 分开授权。

3.  定义返回给 JS 的安全数据表示。

注意事项：

-   不要直接给插件 \~/Desktop 等任意路径。

-   限制文件大小和可读取类型。

-   剪贴板读取属于隐私敏感行为，应清楚展示权限。

完成标准：插件无法绕过 Broker 读取任意用户文件。

#### T31 PluginScheduler

任务方向：统一管理插件后台刷新与能耗。

开发步骤：

1.  定义 active/background/lowPower 策略。

2.  提供 requestRefresh 或 scheduled task API。

3.  高频实时场景优先 EventBus。

4.  限制插件自行创建极高频 Timer 的效果。

注意事项：

-   Activity Scheduler 与 PluginScheduler 分离。

-   不要让 20 个插件各自每 100ms 轮询。

完成标准：后台安装多个插件后空闲 CPU/能耗仍接近基线。

#### T32 Crash Watchdog / Logging

任务方向：插件错误可诊断、可自动隔离。

开发步骤：

1.  捕获 JS exception。

2.  按 plugin ID 记录结构化日志。

3.  例如 60 秒内连续 3 次严重失败自动禁用。

4.  Settings 提供 View Log/Restart。

注意事项：

-   日志必须过滤 secret、token 和用户敏感内容。

-   不要因单插件错误 terminate Host。

完成标准：错误插件被自动停止，DynamicIsland 主程序和其他插件继续工作。

## 11. Phase 7 --- 安装、管理与官方验证插件

#### T33 Extensions Settings UI

任务方向：让普通用户可理解地管理插件、权限和状态。

开发步骤：

1.  增加 Installed/Discover（Discover 可后置）页面。

2.  展示 name/version/developer/status/permissions。

3.  提供 Enable/Disable/Uninstall。

4.  显示兼容模式和错误状态。

注意事项：

-   不要只显示技术权限名；给出用途说明。

-   禁用应立即停止 Runtime 和 Activity。

完成标准：用户无需接触文件系统即可管理插件。

#### T34 .dip Installer

任务方向：建立双击或 App 内导入的安装流程。

开发步骤：

1.  定义 .dip 为受控插件包。

2.  导入 → 解压临时目录 → Validator → 权限预览 → 安装。

3.  安装到 Application Support/DynamicIsland/Plugins。

4.  处理升级和回滚。

注意事项：

-   先验证后执行。

-   限制压缩包炸弹、路径穿越、symlink。

-   升级时 Manifest 新增权限必须重新询问用户。

完成标准：合法插件可一键安装，恶意/损坏包被明确拒绝。

#### T35 Pomodoro 官方插件

任务方向：作为无网络插件验证 Activity、UI、Action、Storage、Scheduler。

开发步骤：

1.  实现计时开始/暂停/继续/结束。

2.  提供 compact/expanded。

3.  保存设置。

4.  结束时发布通知 Activity。

注意事项：

-   不要给示例插件特殊私有 API。

-   它必须只使用公开 Plugin API。

完成标准：删除所有 Pomodoro 专用 Swift 代码后插件仍能工作。

#### T36 GitHub 官方插件

任务方向：作为网络插件验证 NetworkBroker、设置、Activity 更新和权限。

开发步骤：

1.  配置仓库/API 凭据或公开 API 示例。

2.  读取 CI/PR 状态。

3.  发布 Build started/progress/result Activity。

4.  提供 Open 动作。

注意事项：

-   Token 使用安全存储，不写普通日志。

-   处理 rate limit、离线和 API 失败。

完成标准：该插件证明第三方开发者可以完成真实网络型扩展。

## 12. Phase 8 --- SuperIsland Compatibility

目标：兼容稳定子集，利用现有生态，但不让兼容 API 直接控制 DynamicIsland
核心窗口和调度。

#### T37 SuperIsland Adapter

任务方向：把 SuperIsland 风格 Module/View API 映射到 DynamicIsland
Activity/IslandNode。

开发步骤：

1.  先列出准备兼容的稳定子集。

2.  View.text/icon/hstack/vstack/progress/button 等映射到 IslandNode。

3.  compact/expanded 映射到 Presentation。

4.  activate/dismiss 等窗口控制调用转换为 PresentationRequest，由
    ActivityManager 决策。

5.  显示 Native / Compatible / Limited Compatibility 标识。

注意事项：

-   不要宣称 100% 兼容，除非完整测试。

-   不要复制对方实现代码而忽略许可证；优先实现协议兼容层。

-   兼容层必须在核心 API 之外，随时可独立更新或移除。

完成标准：至少若干简单 SuperIsland 插件可以在兼容模式运行，同时不能绕过
Activity 调度。

## 13. Phase 9 --- SDK、文档与插件生态

#### T38 DynamicIsland SDK

任务方向：把内部稳定接口整理成开发者可用的版本化 SDK。

开发步骤：

1.  发布 schema/types/examples。

2.  定义 API version 与兼容策略。

3.  提供插件模板和打包工具。

4.  为 Manifest 和 IslandNode 提供校验工具。

注意事项：

-   只有经过 Pomodoro/GitHub 实战验证的 API 才公开。

-   公开后避免频繁 breaking changes。

完成标准：开发者无需阅读主 App 源码即可开发插件。

#### T39 开发者文档与模板

任务方向：降低第三方插件开发门槛。

开发步骤：

1.  编写 Quick Start、Manifest、Activity、UI
    Components、Actions、Storage、Network、Permissions、Settings、Lifecycle、Debugging、Packaging、Publishing。

2.  提供最小 Hello World 模板。

3.  提供常见错误和权限说明。

注意事项：

-   文档示例必须由 CI 实际验证，避免文档与实现漂移。

-   目标是 JavaScript 开发者约 10 分钟跑通 Hello World。

完成标准：新开发者仅按文档即可构建并安装首个插件。

#### T40 Plugin Registry

任务方向：在不急于建设服务器的情况下提供插件发现入口。

开发步骤：

1.  先用 GitHub 仓库维护 registry.json。

2.  记录 id/name/version/download/source/minHostVersion/hash。

3.  App 获取并展示可安装插件。

4.  后续再考虑签名、审核、自动更新服务。

注意事项：

-   Registry 不是信任本身；安装仍需 Validator 和权限审查。

-   下载包应校验 hash；后续可引入开发者签名。

完成标准：App 可以从 Registry 发现、下载、验证并安装官方/审核插件。

## 14. 推荐版本切分与验收门槛

| 版本 \| 范围 \| 必须达到的效果 \| 禁止提前加入 \|

| --- \| --- \| --- \| --- \|

| Plugin Alpha \| T01--T17 \| Music/Volume/Battery 已统一进入 Activity
  Engine；抢占、恢复、Renderer 稳定 \| 插件商店、XPC、复杂权限 \|

| Plugin Beta \| T18--T36 \| .dip + JS 插件可安装运行；Pomodoro/GitHub
  两个官方插件验证公开 API \| 大规模 Registry、Native 插件 \|

| Plugin 1.0 \| T37--T40 \| SuperIsland
  兼容子集、SDK、开发文档、Registry 可用 \| 未经需求验证的高危系统 API
  \|

| Plugin 2.x \| 后续 \| 根据真实插件需求增加 XPC Native
  Extension、签名/审核、更多 Broker \| 为了"功能多"提前扩大攻击面 \|

## 15. 每个阶段的统一检查清单

-   功能：旧功能是否仍然正常？是否出现 Activity 状态错乱？

-   架构：业务模块是否绕过 ActivityManager 或 Renderer？

-   并发：后台事件与 SwiftUI 主线程之间是否存在竞态？

-   性能：空闲 CPU/内存、动画帧率、后台刷新是否回退？

-   能耗：是否新增高频 Timer 或无意义 polling？

-   安全：第三方输入是否在进入 Core 前验证？权限是否由 Host 强制执行？

-   隐私：日志是否可能记录 Token、剪贴板或文件内容？

-   兼容：多显示器、无刘海设备、睡眠唤醒、外接屏拔插是否正常？

-   测试：是否有单元测试/集成测试覆盖本阶段核心状态机？

-   回滚：本阶段改动是否能在不破坏用户数据的情况下关闭或回退？

## 16. 最关键的开发禁区

-   禁止第三方插件直接获得 NSWindow/NSPanel/SwiftUI View。

-   禁止插件直接决定刘海 open/close/expand；只能发布 Activity 或提出
    PresentationRequest。

-   禁止任意数值 Priority；Host 保留降级权。

-   禁止 Manifest 声明即视为授权；每次敏感 Broker 调用仍需运行时检查。

-   禁止未验证插件包就解压到正式目录或执行 index.js。

-   禁止所有插件共享一个 JSContext。

-   禁止把 FileManager、URLSession、NSWorkspace 等原生对象直接暴露给
    JavaScript。

-   禁止高频轮询成为默认方案；优先 EventBus/事件驱动。

-   禁止为了兼容 SuperIsland 修改核心 Activity 语义；兼容逻辑只存在
    Adapter。

-   禁止在 API 尚未经过两个真实官方插件验证前发布稳定 SDK。

## 17. 推荐的最终目录结构

``` text
DynamicIsland/
├── App/
├── Core/
│   └── Activity/
│       ├── IslandActivity.swift
│       ├── ActivityPriority.swift
│       ├── ActivityLifecycle.swift
│       ├── ActivityManager.swift
│       ├── ActivityQueue.swift
│       └── ActivityScheduler.swift
├── IslandUI/
│   ├── Schema/
│   │   └── IslandNode.swift
│   ├── DesignTokens.swift
│   ├── IslandRenderer.swift
│   └── ActionRouter.swift
├── BuiltIn/
│   ├── Music/
│   ├── Volume/
│   ├── Battery/
│   └── FileShelf/
├── Plugins/
│   ├── PluginManifest.swift
│   ├── PluginValidator.swift
│   ├── PluginManager.swift
│   ├── PluginLifecycle.swift
│   └── PluginInstaller.swift
├── Runtime/
│   ├── JavaScriptRuntime.swift
│   ├── JSBridge.swift
│   ├── PluginScheduler.swift
│   └── PluginWatchdog.swift
├── Permissions/
│   ├── PermissionManager.swift
│   └── Brokers/
│       ├── NetworkBroker.swift
│       ├── FileBroker.swift
│       └── ClipboardBroker.swift
├── Compatibility/
│   └── SuperIslandAdapter/
├── Settings/
└── Tests/
```

## 18. 下一步应立即执行的工作

当前最应该执行的是 T01 → T02 → T03，而不是直接创建
PluginManager。先对现有 DynamicIsland
源码进行架构审计，确认窗口、展开/收起、音乐、动画和状态管理的真实实现；随后建立
feature/plugin-architecture 分支与基线测试；最后根据真实调用关系定稿
IslandActivity。

只有当 T03--T13 的 Activity + Renderer 最小闭环跑通，并且 T14--T17
证明现有内置功能可以顺利迁移后，才进入第三方插件执行层。这个顺序能最大程度降低后期推倒重来的概率。

## 19. 用户补充计划

本节记录原 T01–T40 之外的用户补充需求，单独编号与跟踪，不改写原任务的验收结果。

### U01 工具菜单越界与展开保持

- 登记：2026-10-20；状态：`verified`。[实现与验收记录](u01-tool-menu-20261020.md)保留前两轮失败、第三版 96 项定向 / Release，以及当前设备七项菜单的物理返回、清理、键盘、取消、页面切换和正常退出结果。
- 排期：后续工具 UI 优化，安排在下一轮完整作者走查与 0.6.0 对外发布验收前。
- 用户反馈：工具增多后，下拉菜单高于展开岛体。选择靠下的工具后，若没有立即把鼠标移回岛内，岛体会收起并退出所选工具。[用户原始截图](evidence/tool-menu-hover-20261020/user-report.png)展示七项菜单延伸到岛体下方；后续两轮实测反馈仍收起，第二轮日志证明原生选择和完整宽限已执行，进一步触发原因仍未确诊。

实施范围：

1. 将工具菜单的完整交互周期纳入 Host 展开 / 收起判定；指针进入岛体之外的菜单项目时仍能完成选择。
2. 选择结束后提供合理的移回岛体缓冲，保留刚选中的工具，避免菜单关闭后立即因鼠标仍在岛外而收起。具体时间与实现方式在复现后确定。
3. 评估菜单最大高度、可滚动列表与弹出位置，适配更多工具及屏幕可用空间，保证底部条目可达。
4. 菜单取消、正常离开、窗口隐藏和退出时正确结束临时保持；继续沿用正常收起后清除工具选择的既有策略。

后续优先检查 [工具菜单](../../DynamicIsland/IslandView.swift)、[窗口悬停区域](../../DynamicIsland/IslandPanelHoverRegion.swift)、[悬停状态](../../DynamicIsland/IslandViewModel.swift)及[收起时的工具选择清理](../../DynamicIsland/Core/Activity/IslandActivityRuntime.swift)。不通过取消正常清理来掩盖误收起；切换页面、停用插件及旧动作失效规则继续成立。

验收要求：

- 真实安装足够多工具，使列表超过岛体高度；鼠标可移动到最底部菜单项并选择，全程不意外收起。
- 选择靠下工具后，以正常速度移回岛体，保持展开并显示新工具，可继续点击其按钮。
- 长列表可用鼠标及键盘访问；Esc 取消、点击外部和真正离开后仍能正常收起，无永久展开或旧工具残留。
- 回归内置计时、音乐、拖盘、插件工具切换及正常收起后的选择清理；记录实际菜单边界与指针过渡，不仅依赖窗口内自动点击。

用户截图与源码路径已确认原有岛体范围外的指针退出会立即收起。U01 第三版的固定 2 秒宽限、原 30Hz `.common` 采样和到期物理复核已在当前设备七项菜单范围内验收；返回、清理、键盘 / 取消 / 页面切换及正常退出结果保留。自动滚轮未观察变化，不作为独立通过，原一秒失败的唯一根因未确诊。T38 SDK 随后已正式发布，原 T01–T40 当前为 38 verified / 2 in progress，详见 [PROGRESS](PROGRESS.md)。
