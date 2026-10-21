# U02 — 全分辨率自适应后续计划

| 项目 | 安排 |
| --- | --- |
| 状态 | `pending` |
| 目标版本 | `TBD` |
| 登记日期 | 2026-10-22 |
| 来源 | 用户反馈不同分辨率下显示效果有差异，重点是展开岛体和两侧信息 / 图标；要求后续加入适配。 |
| 本轮范围 | 记录问题、现有布局来源、后续任务和验收方式；未开始实现或测试。 |

U02 是原 T01–T40 之外的用户补充任务。它不改变 SDK 1.0.0、Plugin Runtime、权限或原里程碑的范围，不修改已发布标签与资产。T39、现有设备矩阵和干净 Mac 安装的人工门槛分别保留；本计划不将它们标为通过。

## 1. 问题与证据边界

- 用户本轮确认当前收起状态显示正常。这是当前配置、当前状态的反馈，不推导为其他缩放、展开状态或所有设备通过。
- 用户同时报告不同分辨率下效果有差异，尤其是展开岛体及两翼的信息、图标。本轮尚未收集覆盖不同缩放的成组对照图与完整环境数据，不能据此认定唯一根因。
- 现有代码已有屏幕选择、刘海几何回退、模拟屏幕及 Renderer 回归。历史自动检查通过范围见 [App beta.2 发布记录](app-0.6.0-beta.2-release-20261021.md)；几何计算和模拟图通过不等同于物理相机遮挡、实际缩放或多屏交互验收。
- “全分辨率自适应”是后续目标。完成时应列出实际支持与验证的逻辑尺寸、缩放和设备范围；没有证据的组合继续记录为未验证，不承诺任意分辨率已有支持。

## 2. 当前布局来源与需要归并的约束

以下为登记时的只读源码核对，不是新的实现方案或已确认的缺陷根因。

| 来源 | 当前行为 | U02 后续核对重点 |
| --- | --- | --- |
| [ScreenEnvironment](../../DynamicIsland/ScreenEnvironment.swift)、[ScreenManager](../../DynamicIsland/ScreenManager.swift) | 保存 `frame`、`visibleFrame`、`safeAreaInsets`、左右 auxiliary area 和 `backingScaleFactor`；监听屏幕参数变化并刷新活动屏幕。 | 各显示器的逻辑坐标、刘海留白与 scale 必须来自同一份有效环境；补齐实际缩放、菜单栏显隐、屏幕切换时的变化证据。 |
| [IslandPanelGeometry](../../DynamicIsland/IslandPanelGeometry.swift) | 紧凑基准从 auxiliary area 的间隔与高度取值，缺失时回退；稳定窗口请求尺寸为 520×240 pt，并按屏幕边界限制。展开窗口保持屏幕顶边对齐。 | 窗口 frame、可见岛体、内容区域各自的约束应一致；不能只限制 NSPanel 后仍用超出预算的固定内容。安全区与菜单栏预留高度分别处理。 |
| [IslandVisualStyle](../../DynamicIsland/IslandVisualStyle.swift) | 展开壳体基准 480×200 pt，内容画布 468×200 pt；按页面 / 状态选用 152、164、190、200 pt 高度。紧凑两翼按 Activity 类型增加固定宽度并设上限。 | 将基准、最小 / 最大尺寸、实际可用空间、内容 chrome 预算和降级规则统一解析，避免窗口、壳体、裁切与子视图各持一套尺寸。 |
| [IslandView](../../DynamicIsland/IslandView.swift) | 使用固定内容画布、外层窗口预算、壳体 mask 和展开页 padding；收起 Activity 通过 Renderer 计算区域，minimal 靠右显示。 | 展开、compact、minimal 及过渡期间都使用同一环境计算的有效布局；不能只调整外壳而留下内容裁切、中心遮挡或透明命中区偏移。 |
| [DesignTokens](../../DynamicIsland/IslandUI/DesignTokens.swift)、[IslandRenderer](../../DynamicIsland/IslandUI/IslandRenderer.swift)、[HostPolicy](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift) | Host 管理字体、间距和图像尺寸；Renderer 按三态限制内容，minimal 计算单侧区域，展开扣除 switcher / padding。当前 icon、图像与间距有固定 point 基准。 | 在 Host 内统一图标 / 文字 / 图片、内外边距、截断与内容预算；保持有限 token 和节点语义，不向插件暴露任意尺寸或窗口控制。 |
| [BatteryProgressView](../../DynamicIsland/IslandUI/BatteryProgressView.swift)及内置 Music / Volume / Battery Provider | 电池图形按形态设尺寸；紧凑内容包含业务图标、文字、进度及 spacer。 | 两翼应有明确的中心避让、边缘安全距离与信息优先级；实测 100%、长文本、封面和倒计时等宽内容。 |
| [IslandPanelController](../../DynamicIsland/IslandPanelController.swift)、[IslandPanelHoverRegion](../../DynamicIsland/IslandPanelHoverRegion.swift) | 环境更新后重算窗口、compact 基准和指针包含关系；展开悬停区依据可见壳体，收起区依据紧凑 frame。 | 可见尺寸、控件命中区、展开保持、菜单返回和物理指针判定必须同步更新；保留 U01 已验收的工具菜单返回行为。 |

### 坐标与尺度约定

1. 布局与命中计算以 macOS 逻辑 point 为基准；分开记录系统显示的缩放选项、逻辑尺寸和 backing scale。不能把“4K”等物理像素名称直接当作可用布局宽高。
2. `backingScaleFactor` 用于清晰度、截图像素与必要的像素边界对齐；不直接按像素倍率整体放大岛体、字体或命中区。`frame × backingScaleFactor` 是 backing 像素估算，不冒充屏幕原生物理像素或实际物理刘海尺寸。
3. 统一处理主屏 / 非主屏、非零或负原点、多屏局部与全局坐标；物理屏幕与模拟环境须明确标识。
4. 窗口可以保持顶边对齐；文字、图标和交互内容必须落在实际可显示的区域。`safeAreaInsets`、auxiliary area、`visibleFrame` 与菜单栏显隐分别参与判断，不能把菜单栏自动隐藏解释为相机遮挡消失。

## 3. 后续任务顺序

全部任务当前均为 `pending`，具体尺寸与可支持下限在 U02-01 / 02 得到可复现依据后确定。

| 顺序 | 任务 | 交付与完成条件 |
| --- | --- | --- |
| U02-01 | 收集基线与复现配置 | 对用户报告的差异建立成组截图与诊断；记录 App 版本 / build / 来源、逻辑尺寸、缩放选项、backing scale、frame / visibleFrame / 安全区 / auxiliary area、菜单栏状态和当前形态，区分正常与异常配置。 |
| U02-02 | 统一 Host 布局约束 | 整理窗口、壳体、展开内容、中心避让和两翼的尺寸关系；确定可用宽高、chrome 开销、合理上限 / 下限和内容优先级，形成可独立验证的布局输入与输出。沿用 Activity / Renderer 语义。 |
| U02-03 | 适配三态及两翼内容 | 接入 expanded、compact、minimal 和内置页面 / 插件工具；统一图标尺寸、字级、icon-text 间距、边缘留白及可交互控件的命中区域。空间不足时采用已定义的截断 / 简化 / Host 回退，重要百分比、剩余时间和状态仍可辨识，辅助功能标签保留完整含义。 |
| U02-04 | 环境变化与交互同步 | 核对缩放切换、主屏 / 指定屏幕变化、外接屏拔插、菜单栏显隐、Space / 全屏及恢复后的环境更新；重算内容和命中区域，避免沿用旧屏幕参数、抖动或丢失工具选择。优先复用现有事件刷新，不新增高频轮询。 |
| U02-05 | 自动布局与截图回归 | 扩充实际差异所需的几何 / Renderer / 悬停测试和可重复截图 fixture；覆盖窄逻辑宽度、不同 scale、刘海 / 无刘海、负原点、混合缩放以及长内容。分别比较基准与变更后结果，避免以更新截图基线掩盖裁切或中心遮挡。 |
| U02-06 | 真机对照与范围确认 | 在同一机器默认与非默认缩放下完成 B01 / B02 对照，并按可用设备补充外接屏组合；保存截图、诊断、操作结果和实际覆盖范围。未实测的组合继续保留，验收后才更新 U02 状态。 |

## 4. 形态与交互验收要求

- **展开**：音乐、文件托盘、秒表 / 倒计时、官方插件及工具菜单均有完整布局预算；顶部控件、正文、进度和底部按钮不被壳体或相机遮挡，不因页面高度切换跳出屏幕。检查实际内容与其 mask / clip 的对应关系。
- **compact**：左右信息处于可显示的两翼，百分比 0% / 100%、图标、电池进度、封面与计时文本有稳定的边缘间距；左右无需等量内容，但视觉基线和留白规则应一致。
- **minimal**：单侧区域由 Host 计算，时间或单图标不会穿过中心刘海；从 minimal 切回 compact / expanded 时使用最新布局，不串用旧区域宽度。
- **尺寸与可读性**：基准以 point 定义，实测不同缩放下的文字清晰度、图标重量、内外边距、长中英文 / 数字宽度、系统较大文字与对比度设置；不靠无限缩小字体满足“不越界”。
- **命中与状态**：图标视觉范围与按钮命中范围分别有明确预算；缩放或屏幕更新后，悬停、菜单选择、返回岛内、正常移出收起、拖放及滑块操作均与可见内容一致。U01 的菜单返回宽限与正常离开清理回归继续保留。

## 5. 复用设备矩阵与可重复截图

以[设备矩阵](../beta-device-matrix.json)和 [Beta 手册](../BETA_TESTING.md)为原记录入口，U02 另保存其实施版本的布局对照证据。已有版本的通过 / 待验证状态保持来源，不以 U02 规划或当前单次收起反馈改写它们。

| 范围 | 后续至少覆盖 | 证据边界 |
| --- | --- | --- |
| DI-B01 | 刘海内建屏、默认缩放、菜单栏可见；展开各页、compact / minimal、启动与悬停。 | 记录实际配置和二进制来源；当前收起正常的用户反馈只是其中一项，不替代完整 B01 场景。 |
| DI-B02 | 同一内建屏非默认缩放、自动隐藏菜单栏；菜单栏显隐、展开 / 收起、Space 与全屏转换，随后恢复默认配置复核。 | 逐个系统提供的实际缩放选项记录逻辑尺寸；需要真实切换和物理指针验证，模拟配置不能替代。 |
| 补充组合 | 按现有 B03 / B04 / B08 等可用设备覆盖外接屏、主屏变化、混合 scale 与负原点；无刘海配置验证回退。 | 只记录实际执行的组合，不通过修改分辨率名称制造设备覆盖。 |

自动部分复用[模拟配置](../../DynamicIsland/SimulatedScreenProfile.swift)、[几何测试](../../DynamicIslandTests/IslandPanelGeometryTests.swift)、[Renderer 测试](../../DynamicIslandTests/IslandRendererTests.swift)、[屏幕更新测试](../../DynamicIslandTests/ScreenManagerTests.swift)、[悬停测试](../../DynamicIslandTests/IslandPanelHoverRegionTests.swift)及[截图矩阵](../../DynamicIslandTests/ScreenSnapshotMatrixTests.swift)。[现有生成入口](../../Scripts/generate-screen-matrix.sh)是显式运行的工具；后续执行前先归档原基线，按版本 / 日期保存新输出。本轮没有运行它或重写既有截图。

每组对照固定 Activity / 插件输入、时间显示点、颜色外观、动画稳定时点与截图比例，保留原始 PNG 和同一时点的环境诊断。先检查边界、中心避让、文字 / 图标可见范围和命中区域，再做视觉比较；像素数、逻辑 point 与设备物理遮挡分开说明。截图中的私有曲名、文件名等须换用受控样例或在分享前脱敏，诊断沿用[现有报告](../../DynamicIsland/Diagnostics/DiagnosticReport.swift)的数据边界。

## 6. U02 完成标准与本轮状态

只有在目标版本确定、上述布局归并实现、相应自动回归通过、用户报告的成组差异完成对照，以及 B01 / B02 对应的真实配置完成验证后，才依据证据评定 U02。报告需列出仍未覆盖的硬件 / 缩放组合及回退表现；不将局部通过表述为任意分辨率保证。

U02 本次仅登记计划，状态保持 `pending`、版本保持 `TBD`，实施和专用回归尚未开始。U02 不修改布局代码、SDK、Runtime 或原 T01–T40 状态；同期设备验收按独立证据管理，不因本计划登记关闭任何人工门槛。
