# Phase 5 — T25 JS → IslandNode 实现与验收

后续契约：T26 接入实际 JS callback 注册和回传，见 [T26 实现与验收](phase-5-t26-js-action-bridge.md)。本文保留 T25 完成时的接口与验证记录。

日期：2026-10-10。范围：将 Activity 的 `minimal`、`compact`、`expanded` 声明式 JS 布局安全转换为既有 IslandNode，再交给 Host 的展示策略与 IslandRenderer。计划完成标准为「恶意或错误 UI Tree 不会导致 App 崩溃」；本步验证受控输入转换与实际 JavaScript 请求，完成记录以末尾验证表为准。

## 转换边界与接口兼容

[`PluginIslandNodeConverter`](../../DynamicIsland/Plugins/PluginIslandNodeConverter.swift) 是纯 Swift、`nonisolated`、`Sendable` 的数据转换层。输入是经严格 [`PluginBridgeJSON`](../../DynamicIsland/Plugins/PluginBridgeJSON.swift) 解析的 JSON 值；转换器只构建有限 IslandNode 枚举，不接收 JSValue、原生对象、Swift 类名、selector 或可执行回调。递归进入子节点前检查树容量，构建后再调用 `IslandNode.validate()`。

[`PluginActivityConverter`](../../DynamicIsland/Plugins/PluginActivityConverter.swift) 在 `presentation` 中增加三个可选节点字段。`island.apiVersion`、Activity namespace 与方法版本保持 `"1.0.0"`；这是可选字段的增量扩展，既有 T23/T24 无布局请求继续使用摘要 fallback。`publish`、`update`、`end` 的 Promise、会话、namespace、生命周期与频率限制沿用 [T24](phase-5-t24-js-activity.md)。

```javascript
{
  id: 'build',
  lifecycle: {policy: 'progress'},
  presentation: {
    title: '正在构建',
    progress: 0.5,
    minimal: {type: 'text', content: '50%'},
    compact: {
      type: 'hStack',
      children: [
        {type: 'icon', symbolName: 'hammer'},
        {type: 'text', content: '构建 50%', color: 'accent'}
      ]
    },
    expanded: {
      type: 'vStack',
      children: [
        {type: 'text', content: '正在构建'},
        {type: 'progress', value: 0.5, style: 'linear', color: 'accent'}
      ]
    }
  }
}
```

`presentation.title` 仍必需，不能为空或只有空白；节点 Text、Toggle / Slider 的 title、Button accessibilityLabel 允许空字符串，是否适合展示由 Host 决定。三个布局省略时默认为 `nil`；显式 `null` 会被拒绝。

`update` 仍是顶层补丁。提供 presentation 时替换整个 presentation，必须含 title，省略的摘要和布局字段清空；省略 presentation 时保留现有三种布局。清空布局应提交只含所需摘要字段的新 presentation。即使请求省略布局，Bridge 仍会对更新后实际保留的布局执行 capability 检查。

## 十二种有限节点

每个节点都是包含 `type` 的对象，且只能含该行列出的字段。必需字段缺失、未知 type、未知字段、错误类型、可选字段显式 null 均拒绝；没有动态节点注册机制。

| type | 必需字段（除 type） | 可选字段与默认值 |
| --- | --- | --- |
| `text` | `content` 字符串 | `color`，默认 `primary`。 |
| `icon` | `symbolName` 标识符 | 无。 |
| `image` | `source` 图片来源对象 | `size`，默认 `icon`。 |
| `hStack` / `vStack` / `zStack` | `children` 节点数组，允许空数组 | 无；不接收 spacing / alignment。 |
| `spacer` / `divider` | 无 | 无。 |
| `progress` | `value` 有限数值 `0...1` | `style` 默认 `linear`；`color` 默认 `accent`。 |
| `button` | `actionID` 标识符、`label` 子节点 | `accessibilityLabel` 字符串，默认省略。 |
| `toggle` | `title` 字符串、`isOn` 布尔值、`actionID` 标识符 | 无。 |
| `slider` | `title` 字符串、`value` 有限数值 `0...1`、`actionID` 标识符 | `showsTitle` 布尔值，默认 `true`。 |

有限 token 由既有 Core 枚举定义：

- color：`primary`、`secondary`、`accent`、`success`、`warning`、`danger`。
- progress style：`linear`、`battery`。
- image size：`icon`、`thumbnail`、`artwork`。

插件只能选择这些语义值；物理尺寸、字体、颜色映射、间距、圆角和窗口动画仍归 Host。Bridge 不接受任意 typography、geometry、padding、frame、SwiftUI modifier、颜色分量或类名。

## 容量、类型与错误

| 校验层 | 当前限制 |
| --- | --- |
| 每个布局树 | 根深度为 1，最大深度 8；Stack 每层最多 16 个 children；总节点最多 128。Button label 计作下一层和一个节点，image source 对象不是 UI 节点。 |
| 文本 | 每个 Text content、Toggle / Slider title、Button accessibilityLabel 最多 256 UTF-8 bytes。 |
| 标识符 | 非空；SF Symbol / 图片 ID 最多 128 UTF-8 bytes；actionID 最多 80 UTF-8 bytes。 |
| 数值与布尔 | 数值必须有限且在闭区间 `0...1`；布尔只接受真正的 boolean，数字/字符串不转换。 |
| Bridge 请求总预算 | 整个请求最多 16 KiB JSON、512 个 JSON 值节点，包含三个布局及其他字段。每个 UI 节点及其字段会占用多个 JSON 值节点，不能承诺三个树都达到各自 128 节点上限，或任意字段丰富的 128 节点树都能装入总预算。 |
| JSON / JS 快照深度 | JS 参数快照最大深度 20；Host 请求解析最大深度 22，以容纳节点深度 8 的 image source 与 envelope。总字节和节点预算保持上述限制。 |

未知字段、形状或类型错误、非有限 / 越界数值、非法标识符映射为 `invalidArguments`；树深度、children / 节点数量、UTF-8 文本 / 标识符长度或总预算超限映射为 `quotaExceeded`。失败不会部分提交 Activity，也不会消费成功写入限频额度。

JSON 重复键、访问器、function、symbol、bigint、循环引用、稀疏数组、可执行 toJSON 等继续由 T23 的严格解析 / JS 快照边界拒绝；不会将它们作为 SwiftUI 对象或回调传入 Core。Storage 的独立深度 8、256 节点等限制保持 T23 契约；提高 Activity envelope 深度没有放宽 KV 数据限制。

## 图片来源

source 只允许三种精确对象：

```javascript
{type: 'systemSymbol', name: 'hammer'}
{type: 'pluginAsset', id: 'cover'}
{type: 'brokerResource', id: 'avatar_1'}
```

`systemSymbol.name` 和 icon.symbolName 允许 ASCII 字母、数字、`.`、`_`、`-`、`:`。`pluginAsset.id`、`brokerResource.id` 和 actionID 只允许 ASCII 字母、数字、`.`、`_`、`-`；不接受冒号、斜杠、反斜杠、百分号或其他字符。因此 URL / file / data scheme、含路径分隔符的路径和百分号编码路径不能成为图片 ID，source 也不允许 url / path 等额外字段。

systemSymbol 由 Host 使用 SF Symbol 渲染。pluginAsset / brokerResource 目前只是受控、不透明的数据标识符；正式 runtime 的图片 resolver 对插件来源返回 nil，Renderer 显示现有缺图占位。Bridge 不读取插件文件、请求远程图片或把标识符转换为资源。Broker 的资源能力按 T29 继续实现。

## Capability 与交互引用

发布 / 更新后实际 presentation 含任何布局时，Manifest 必须声明 `ui.islandNode`，并继续声明对应 `activity.publish` / `activity.update`。提交非空动作元数据仍要求 T24 的 `actions.handle`。布局含 Button / Toggle / Slider 时也要求 `actions.handle`；每个控件的 actionID 必须出现在该 Activity 更新后有效 actions 数组中。

actionID 校验在补丁与已有 Activity 合并后进行。更新仅清空 actions，留下引用原动作的布局，会返回 `invalidArguments`；应同时替换 presentation，清除控件或更新引用。失败不改变原模型。布局内重复使用同一个已声明 actionID 可以表达多个控件；actions 元数据自身仍不允许重复 ID。

T25 只转换控件描述和验证引用关系。`island.actions.supported` 仍为 false，`actions.on/off` 在满足 capability 后继续返回 `unsupportedMethod`，没有注册 JS callback。Renderer 的既有 Host action 数据映射保持原样；正式点击回传插件函数按 T26 实现。示例使用无交互节点，避免把控件渲染当作 JS 动作闭环验收。

## Host 展示策略与 fallback

成功转换表示树合法，并不保证任意树都显示在指定 shell。既有 [`ActivityPresentation.HostPolicy`](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift) 继续对每种展示模式限制布局复杂度，[`IslandRenderer`](../../DynamicIsland/IslandUI/IslandRenderer.swift) 使用 Host 尺寸、测量、裁切与摘要 fallback。

- minimal 仅显示一个符合 minimal policy 的 Text / Icon / Image。
- compact 优先 compact，随后尝试符合双方 policy 的 minimal；expanded 优先 expanded，再依次尝试 compact、minimal。
- 合法树超过对应展示模式的节点、行数、图片或控件限制时，跳过该候选并使用较简单布局或摘要。空布局 / 只有 Spacer、Divider 等没有可见内容的树也走现有 fallback。
- 未知或错误树在转换边界拒绝，保留原 Activity；不会靠 Renderer 构建未知类型。

本步没有修改 Host shell 高度、刘海安全区域、视觉动画或展示策略阈值。自动化渲染不能替代真实刘海设备视觉验收。

## Node Mock 与自动化验收

[`examples/node-mock`](examples/node-mock/README.md) 提供实际 Manifest 和入口。它声明四项 Activity / UI capability、权限数组为空，`onStart` 同步返回 undefined，在处理失败的 Promise 链中发布 local build、progress 生命周期与进度 0.1。

三种形式分别用 Text、Icon + Text、Text + Progress 表达同一构建数据。测试 Host 调用示例自己的 `mockNodeProgress(0.5)`、`mockNodeProgress(1)`，每次完整替换三个布局，再调用 `mockNodeEnd()`。成功日志为 `node.ready`、`node.progress:<progress>`、`node.ended`；错误日志使用 `node.error:<code>`，每个 Promise 链显式处理失败。示例没有网络、定时器、图片 materialization 或动作 handler。

[`PluginIslandNodeBridgeTests`](../../DynamicIslandTests/PluginIslandNodeBridgeTests.swift) 的 20 项测试覆盖全部节点和默认值、严格类型 / 未知字段、UTF-8 与树边界、图片 ID、UI / actions capability、更新保留 / 清空布局、动作引用合并，以及真实 JavaScript 与同一 NSHostingView 的三个展示形式。Node Mock 经正式包校验后从临时受控容器加载，核对 0.1 → 0.5 → 1 的具体节点值、九次渲染结果、稳定 Activity 实例及结束清理；正式生产 Runtime 工厂也验证实际 JS 布局发布和更新。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| T25 定向测试与实际 Node Mock | 20 passed、0 failures；全部包含在下列最终 CI 和 Release 验证中。 | `/tmp/dynamic-island-t25-node-tests-final/TestResults.xcresult`；增强节点值断言后的单项记录 `/tmp/dynamic-island-t25-node-mock-final/TestResults.xcresult`。 |
| 完整 `./Scripts/ci.sh` | 453 项，452 passed、1 skipped、0 failures；普通 Release build passed。 | `/tmp/dynamic-island-t25-final-ci/TestResults.xcresult`、`/tmp/dynamic-island-t25-final-ci.log`。 |
| Release Bridge / T25 / 生产 Runtime 回归 | 44 passed、0 skipped、0 failures：T25 20 项、T23 Bridge 23 项、生产 Runtime 工厂 1 项。 | `/tmp/dynamic-island-t25-release-tests/TestResults.xcresult`、`/tmp/dynamic-island-t25-release-tests.log`、`/tmp/dynamic-island-t25-release-build.log`。 |
| 普通 Release App 签名 | `codesign --verify --deep --strict` 通过；flags `0x10002(adhoc,runtime)`；Sandbox / allow-jit 为 true，无 get-task-allow 和 disable-library-validation。 | `/tmp/dynamic-island-t25-derived/Build/Products/Release/Dynamic Island.app`；`/tmp/dynamic-island-t25-release-entitlements.plist`。 |

验证环境为 arm64 MacBook Air，macOS 26.6.2（25G83），SDK 26.5。完整 CI 的一项跳过是需单独执行 `Scripts/generate-screen-matrix.sh` 的截图矩阵生成测试，沿用原配置。

Release XCTest 使用单独的 `/tmp/dynamic-island-t25-release-derived`：以 `ENABLE_TESTABILITY=YES`、注入测试 entitlement 的方式 build-for-testing，并只给该临时测试 Host 加入 `com.apple.security.cs.disable-library-validation` 后重新 ad hoc 签名，以加载 XCTest。普通 CI Release App 单独构建并核验，无上述测试例外；项目生产 entitlement 未修改。

T25 标记为 `verified`：有界错误 / 恶意 UI Tree 在转换与准入阶段拒绝，失败不修改 Core 或消耗成功写入额度；有效布局经真实 JS、Runtime、Bridge、Core 和 Renderer 完成更新与结束闭环。

T22 的进程内 JavaScriptCore Runtime 边界保持：没有为任意恶意 JS 无限循环、进程级 OOM 或引擎崩溃新增隔离保证。T25 的范围是有界 UI 数据转换、准入和 Host 渲染；T26 动作回传、T27 KV 持久化、T28 用户 grant、T29 Broker、T31/T32 调度和 Watchdog 按计划继续推进。
