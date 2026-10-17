# Phase 8 — T37 SuperIsland 兼容范围准备

日期：2026-10-17。状态 `in progress`，本页记录 T37 第一步的来源核对与范围准备，后续已完成[有界 View 转换](phase-8-t37-view-conversion.md)、[显式模式](phase-8-t37-manifest-profile.md)、[同 VM 模块闭环](phase-8-t37-module-runtime.md)和[Host 展示请求](t37-presentation-requests.md)。限制详情与真实上游插件验收尚未完成。T35 的实际完成提示按[人工验收安排](MANUAL_ACCEPTANCE.md)延期；遵循 [PROGRESS 中的用户例外](PROGRESS.md)推进自动工作。

## 范围准备时的 Host 边界（历史快照）

- [PluginManifest](../../DynamicIsland/Plugins/PluginManifest.swift) 的 engine 当前只有 `javascriptcore`；未知字段 / capability / permission 拒绝整个 Manifest。兼容输入不能靠放宽现有 V1 解码进入。
- [PluginRuntime](../../DynamicIsland/Plugins/PluginRuntime.swift) 每次执行拥有独立 VM，先安装 Host bootstrap，再执行验证后保留的 `entrySource`。适配器应有明确版本与启用路径，在该隔离环境中运行。
- [IslandNode](../../DynamicIsland/IslandUI/Schema/IslandNode.swift) 已提供 text、icon、hStack、vStack、progress、button 等有限节点。转换仍经过 [PluginIslandNodeConverter](../../DynamicIsland/Plugins/PluginIslandNodeConverter.swift)，保留深度 8、节点 128、每层子节点 16 和文本 256 UTF-8 字节的限制。
- [PluginActivityConverter](../../DynamicIsland/Plugins/PluginActivityConverter.swift) 负责限定优先级、生命周期和显示数据；[ActivityManager](../../DynamicIsland/Core/Activity/ActivityManager.swift) 拥有调度、工具选择、展示期限和实例身份。当前源码没有单独的 `PresentationRequest` 类型，也没有 SuperIsland Adapter。
- [ActionRouter](../../DynamicIsland/IslandUI/ActionRouter.swift) 与 [PluginActionSession](../../DynamicIsland/Plugins/PluginActionSession.swift) 验证真实呈现的实例和注册。兼容按钮也必须经过此路径；保存 JS 回调不能制造用户 activation。
- [管理页](../../DynamicIsland/Plugins/PluginExtensionsUI.swift) 当前只展示“原生 JavaScriptCore”。后续 Native / Compatible / Limited Compatibility 由 Host 按实际加载模式与能力计算，不能直接相信包自报的兼容等级。

## 上游来源核对

固定 [shobhit99/SuperIsland](https://github.com/shobhit99/SuperIsland/tree/68cce87205a88a004e74e33f40bbcb253f8287e9) 的 commit `68cce87205a88a004e74e33f40bbcb253f8287e9`（2026-09-13）作为首批协议目标；未确认其正式稳定性承诺。依据现行 [Builder Guide](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/SUPER-ISLAND-EXTENSION-API.md#L7-L31) 与实际 Runtime；旧 `EXTENSIONS-API.md` 包含规划内容，不能单独当作已实现契约。

| 实际上游接口 | 固定实现位置 / 语义 |
| --- | --- |
| `SuperIsland.registerModule(config)` | [Runtime 205–211](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift#L205-L211)；不是计划示意中的独立 Module 构造器。 |
| compact / expanded 回调 | [Runtime 128–130](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift#L128-L130)；返回节点，expanded 缺省复用 compact。 |
| activate / deactivate / action 回调 | [Runtime 100–109、174–182](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift#L100-L182)；动作接收 action ID 与可选 value。 |
| `View.hstack(children, opts?)` / vstack | [View 定义 695–709](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift#L695-L709)；spacing 分别默认 8 / 4。 |
| text / icon / progress 工厂 | 同上；首参数分别为 value / name / value，第二参数为可选 opts；默认 style=body、size=14、total=1。 |
| button 工厂 | 同上；参数顺序为 label 节点、action ID，回调由模块 action 方法接收。 |

上游 `island.activate(autoDismiss=true)` 请求全局 HUD 展开；`dismiss()` 收起全局窗口，不能解释为卸载或结束本模块。实现会检查拖拽 / 锁定等状态，见 [Runtime 279–299](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift#L279-L299) 与 [AppState](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/SuperIsland/App/AppState.swift#L514-L531)。DynamicIsland 只转换为由 Host 裁决的请求；不能照搬全局窗口控制。模块生命周期与悬停展开也须分别处理。

本次固定树未找到仓库级 LICENSE / LICENCE / COPYING / NOTICE，GitHub 仓库 API 的 license 为 null。7 个内置插件 Manifest 声明 MIT，例如 [Pomodoro 的 license 字段](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/Extensions/pomodoro/manifest.json#L12)，但未找到对应许可正文 / 版权声明；这个字段不证明 Host 源码的许可。后续按公开协议独立实现；复制或分发上游代码 / 示例前另补许可依据。当前只引用来源，未复制上游实现或样本。

Builder Guide 的最小 Hello 是固定复现候选；本轮未构建或运行上游，也没有把文档示例标成兼容通过。

## 范围准备时的初期映射候选（历史快照）

下表是已核对接口的首批适配候选；尚未实现或运行，细节差异必须记录为 Limited Compatibility。

| 计划中的输入能力 | Host 输出与规则 | 初期范围 |
| --- | --- | --- |
| text / icon | 有界文本与受限系统 symbol，交给 IslandNode 校验 | 候选 |
| hstack / vstack | 有序 children，保留深度 / 数量配额；布局样式只映射现有 token | 候选 |
| progress | value / total 转为 0…1；拒绝非有限值、非正 total 与越界输入，不编造百分比 | 候选 |
| button | 有界 action ID 映射，模块 callback 留在当前 VM；通过 ActionRouter 回调 | 候选 |
| compact / expanded | `ActivityPresentation` 中的两种数据布局；相机安全区继续由 Host 负责 | 候选 |
| activate / dismiss | 转成有界展示请求，由 ActivityManager 决策；dismiss 不能收起其他来源或结束其他 Activity | 需先定义请求合约 |
| 任意窗口、原生 View、文件 / 网络 / 剪贴板直通 | 无直接映射；所需操作必须走现有 Broker、声明与独立授权 | 不支持 |

兼容层放在独立 `Compatibility/SuperIslandAdapter` 边界，转换为现有 Plugin API 数据。上游扩展不能反向改变核心 Activity 语义、授予权限、跳过包校验或强制展开 / 关闭刘海。

## 初始实施顺序与验收门槛

1. 根据以上固定签名实现独立协议夹具，并列出不支持的样式 / 数值行为；复制上游样本前补齐许可依据。
2. 实现有界 View 转换，再接 Module 生命周期与动作注册；在同一 VM 中运行适配器和插件，复用 Host 执行撤销。
3. 定义 PresentationRequest 的申请 / 拒绝 / 降级 / 撤销规则；验证 activate 无法抢走 Host 窗口或绕过调度。
4. Host 保存实际模式并显示兼容等级；对不支持的输入明确标记 Limited 或拒绝，不能静默成功。
5. 运行若干固定版本的简单上游插件，覆盖文本 / 堆栈、按钮和 progress；再验证旧实例按钮、停用、权限撤销、超限树和跨插件 ID 隔离。自写夹具与真实上游样本分别记录。

上述顺序的 View、显式模式、Module 生命周期、动作和 PresentationRequest 已接入，当前继续位置见[展示请求子步骤](t37-presentation-requests.md)。限制详情和真实上游样本验收仍待完成；当前 T37 不标为 `verified`，T38 稳定 SDK 的两款官方插件实际验收门槛仍保留。
