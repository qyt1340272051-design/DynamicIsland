# U02 — 全分辨率自适应计划与实施状态

| 项目 | 安排 |
| --- | --- |
| 状态 | `in progress` |
| 目标版本 | App 0.6.0 / 开发 build6（未发布、未验收） |
| 登记日期 | 2026-10-22 |
| 开始实施 | 2026-10-23，用户授权按本计划开始开发 |
| 来源 | 用户反馈不同分辨率下显示效果有差异，重点是展开岛体和两侧信息 / 图标；要求后续加入适配。 |
| 本轮范围 | 在 build5 大小统一反馈基础上，继续修正 U02-07–10：最终 point 原生渲染、贴顶壳体路径、按内容测量两翼及缩小展开尺寸；本轮推进自动回归与审查，人工复验按用户要求延期。 |

2026-10-24 当前进度见[build6 修正记录](u02-refinement-20261023.md)。以下 build5 实现、阶段自动结果与停止点保留其历史范围；本轮最终v4为1144项/9跳过/0失败、Release成功，144图生成并抽查20张；人工复验延期，不据此将U02标为通过。

U02 是原 T01–T40 之外的用户补充任务。它不改变 SDK 1.0.0、Plugin Runtime、权限或原里程碑的范围，不修改已发布标签与资产。原 T01–T40 仍为 **39 verified / 1 in progress**。T39、现有设备矩阵和干净 Mac 安装的人工门槛分别保留；本计划不将它们标为通过。

## 1. 问题与证据边界

- 2026-10-22 用户确认当时收起状态显示正常。这是当前配置、当前状态的反馈，不推导为其他缩放、展开状态或所有设备通过。
- 用户同时报告不同分辨率下效果有差异，尤其是展开岛体及两翼的信息、图标。2026-10-23 已授权实施；已有已知几何输入可用于复现，但原 build5 的完整成组图像与物理对照当时仍待补齐，不能据此认定唯一根因。后续大小统一反馈及四项待修保留于[原实施记录](u02-resolution-adaptation-20261023.md)，当前修正另按 build6 追踪。
- 现有代码已有屏幕选择、刘海几何回退、模拟屏幕及 Renderer 回归。历史自动检查通过范围见 [App beta.2 发布记录](app-0.6.0-beta.2-release-20261021.md)；几何计算和模拟图通过不等同于物理相机遮挡、实际缩放或多屏交互验收。
- “全分辨率自适应”是后续目标。完成时应列出实际支持与验证的逻辑尺寸、缩放和设备范围；没有证据的组合继续记录为未验证，不承诺任意分辨率已有支持。

## 2. 当前布局来源与需要归并的约束

以下保留 2026-10-22 登记时的只读源码基线，供实施前后对照；它不是已确认的唯一缺陷根因。2026-10-23 的变更见下一小节。

| 来源 | 登记时行为 | U02 核对重点 |
| --- | --- | --- |
| [ScreenEnvironment](../../DynamicIsland/ScreenEnvironment.swift)、[ScreenManager](../../DynamicIsland/ScreenManager.swift) | 保存 `frame`、`visibleFrame`、`safeAreaInsets`、左右 auxiliary area 和 `backingScaleFactor`；监听屏幕参数变化并刷新活动屏幕。 | 各显示器的逻辑坐标、刘海留白与 scale 必须来自同一份有效环境；补齐实际缩放、菜单栏显隐、屏幕切换时的变化证据。 |
| [IslandPanelGeometry](../../DynamicIsland/IslandPanelGeometry.swift) | 紧凑基准从 auxiliary area 的间隔与高度取值，缺失时回退；稳定窗口请求尺寸为 520×240 pt，并按屏幕边界限制。展开窗口保持屏幕顶边对齐。 | 窗口 frame、可见岛体、内容区域各自的约束应一致；不能只限制 NSPanel 后仍用超出预算的固定内容。安全区与菜单栏预留高度分别处理。 |
| [IslandVisualStyle](../../DynamicIsland/IslandVisualStyle.swift) | 展开壳体基准 480×200 pt，内容画布 468×200 pt；按页面 / 状态选用 152、164、190、200 pt 高度。紧凑两翼按 Activity 类型增加固定宽度并设上限。 | 将基准、最小 / 最大尺寸、实际可用空间、内容 chrome 预算和降级规则统一解析，避免窗口、壳体、裁切与子视图各持一套尺寸。 |
| [IslandView](../../DynamicIsland/IslandView.swift) | 使用固定内容画布、外层窗口预算、壳体 mask 和展开页 padding；收起 Activity 通过 Renderer 计算区域，minimal 靠右显示。 | 展开、compact、minimal 及过渡期间都使用同一环境计算的有效布局；不能只调整外壳而留下内容裁切、中心遮挡或透明命中区偏移。 |
| [DesignTokens](../../DynamicIsland/IslandUI/DesignTokens.swift)、[IslandRenderer](../../DynamicIsland/IslandUI/IslandRenderer.swift)、[HostPolicy](../../DynamicIsland/IslandUI/ActivityPresentationPolicy.swift) | Host 管理字体、间距和图像尺寸；Renderer 按三态限制内容，minimal 计算单侧区域，展开扣除 switcher / padding。当前 icon、图像与间距有固定 point 基准。 | 在 Host 内统一图标 / 文字 / 图片、内外边距、截断与内容预算；保持有限 token 和节点语义，不向插件暴露任意尺寸或窗口控制。 |
| [BatteryProgressView](../../DynamicIsland/IslandUI/BatteryProgressView.swift)及内置 Music / Volume / Battery Provider | 电池图形按形态设尺寸；紧凑内容包含业务图标、文字、进度及 spacer。 | 两翼应有明确的中心避让、边缘安全距离与信息优先级；实测 100%、长文本、封面和倒计时等宽内容。 |
| [IslandPanelController](../../DynamicIsland/IslandPanelController.swift)、[IslandPanelHoverRegion](../../DynamicIsland/IslandPanelHoverRegion.swift) | 环境更新后重算窗口、compact 基准和指针包含关系；展开悬停区依据可见壳体，收起区依据紧凑 frame。 | 可见尺寸、控件命中区、展开保持、菜单返回和物理指针判定必须同步更新；保留 U01 已验收的工具菜单返回行为。 |

### 2026-10-23 开发 build5 的布局归并

- 新增 [IslandDisplayLayout](../../DynamicIsland/IslandDisplayLayout.swift)，使用有效 auxiliary 刘海区域高度相对 **32 pt** 设计基准计算布局 scale；无有效刘海时使用 1，并按屏幕宽高预算等比限制。菜单栏显隐不直接决定刘海 scale，`backingScaleFactor` 只参与栅格密度，不作为布局倍率。
- [IslandViewModel](../../DynamicIsland/IslandViewModel.swift)接收同一 `ScreenEnvironment`；compact 保存实际 point 尺寸，再反归一得到设计坐标中的相机间隔。窗口、壳体、文字、图标、内容画布与裁切沿用 Host 设计预算，经同一变换呈现，保持既有 Activity / Renderer 语义。
- [IslandPanelGeometry](../../DynamicIsland/IslandPanelGeometry.swift)和 [IslandPanelController](../../DynamicIsland/IslandPanelController.swift)使用同一布局参数更新稳定窗口及 compact / expanded 悬停区域；保留 U01 工具菜单返回策略，环境变化时同步重算。
- 两小时原生倒计时采用八字符 `02:00:00`。在新像素检查发现右侧时间贴近相机后，[计时两翼扩展预算](../../DynamicIsland/IslandVisualStyle.swift)由 126 调整为 **150 设计 pt**，为原生 58 pt 时间框、padding 和相机间距留出空间；未降低相机遮挡与间距检查。
- [诊断报告](../../DynamicIsland/Diagnostics/DiagnosticReport.swift)新增 `layout_scale`，与原有实际屏幕、panel frame 和 compact point 尺寸分别记录。

这组变更属于未发布的 App 0.6.0 / 开发 build5；SDK 1.0.0 与公开 App build4 不变。完整提交、构建、图像和人工结果另归档于[实施记录](u02-resolution-adaptation-20261023.md)，不能把历史 build4 结果替代为 build5 验收。

### 坐标与尺度约定

1. 布局与命中计算以 macOS 逻辑 point 为基准；分开记录系统显示的缩放选项、逻辑尺寸和 backing scale。不能把“4K”等物理像素名称直接当作可用布局宽高。
2. `backingScaleFactor` 用于清晰度、截图像素与必要的像素边界对齐；不直接按像素倍率整体放大岛体、字体或命中区。`frame × backingScaleFactor` 是 backing 像素估算，不冒充屏幕原生物理像素或实际物理刘海尺寸。
3. 统一处理主屏 / 非主屏、非零或负原点、多屏局部与全局坐标；物理屏幕与模拟环境须明确标识。
4. 窗口可以保持顶边对齐；文字、图标和交互内容必须落在实际可显示的区域。`safeAreaInsets`、auxiliary area、`visibleFrame` 与菜单栏显隐分别参与判断，不能把菜单栏自动隐藏解释为相机遮挡消失。

## 3. 实施任务顺序

2026-10-23 已开始 U02-01–05 的输入整理、布局实现和自动回归；U02-06 已开始本轮真机对照并收到用户反馈，新增四项问题待修。各项是否完成仍按证据单独判断，当前没有 U02 子项标为 verified。

| 顺序 | 任务 | 当前状态 | 交付与完成条件 |
| --- | --- | --- | --- |
| U02-01 | 收集基线与复现配置 | `in progress` | 对用户报告的差异建立成组截图与诊断；记录 App 版本 / build / 来源、逻辑尺寸、缩放选项、backing scale、frame / visibleFrame / 安全区 / auxiliary area、菜单栏状态和当前形态，区分正常与异常配置。 |
| U02-02 | 统一 Host 布局约束 | `in progress` | 整理窗口、壳体、展开内容、中心避让和两翼的尺寸关系；确定可用宽高、chrome 开销、合理上限 / 下限和内容优先级，形成可独立验证的布局输入与输出。沿用 Activity / Renderer 语义。 |
| U02-03 | 适配三态及两翼内容 | `in progress` | 接入 expanded、compact、minimal 和内置页面 / 插件工具；统一图标尺寸、字级、icon-text 间距、边缘留白及可交互控件的命中区域。空间不足时采用已定义的截断 / 简化 / Host 回退，重要百分比、剩余时间和状态仍可辨识，辅助功能标签保留完整含义。 |
| U02-04 | 环境变化与交互同步 | `in progress` | 核对缩放切换、主屏 / 指定屏幕变化、外接屏拔插、菜单栏显隐、Space / 全屏及恢复后的环境更新；重算内容和命中区域，避免沿用旧屏幕参数、抖动或丢失工具选择。优先复用现有事件刷新，不新增高频轮询。 |
| U02-05 | 自动布局与截图回归 | `in progress` | 扩充实际差异所需的几何 / Renderer / 悬停测试和可重复截图 fixture；覆盖窄逻辑宽度、不同 scale、刘海 / 无刘海、负原点、混合缩放以及长内容。分别比较基准与变更后结果，避免以更新截图基线掩盖裁切或中心遮挡。 |
| U02-06 | 真机对照与范围确认 | `in progress` | 在同一机器默认与非默认缩放下完成 B01 / B02 对照，并按可用设备补充外接屏组合；保存截图、诊断、操作结果和实际覆盖范围。未实测的组合继续保留，验收后才更新 U02 状态。 |

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

自动部分复用[模拟配置](../../DynamicIsland/SimulatedScreenProfile.swift)、[几何测试](../../DynamicIslandTests/IslandPanelGeometryTests.swift)、[Renderer 测试](../../DynamicIslandTests/IslandRendererTests.swift)、[屏幕更新测试](../../DynamicIslandTests/ScreenManagerTests.swift)、[悬停测试](../../DynamicIslandTests/IslandPanelHoverRegionTests.swift)及[截图矩阵](../../DynamicIslandTests/ScreenSnapshotMatrixTests.swift)。[生成入口](../../Scripts/generate-screen-matrix.sh)仍需显式运行；现改为 UTC 日期唯一目录或指定的新 / 空绝对输出目录，并按 manifest 中的文件集合和数量校验，避免覆盖或混入旧的 104 张基线。当前测试保留 8×12＝96 张配置矩阵，另编写三档各 12 态的分辨率对照，预期共 132 张；实际生成、图像检查和结果以实施记录为准。

每组对照固定 Activity / 插件输入、时间显示点、颜色外观、动画稳定时点与截图比例，保留原始 PNG 和同一时点的环境诊断。先检查边界、中心避让、文字 / 图标可见范围和命中区域，再做视觉比较；像素数、逻辑 point 与设备物理遮挡分开说明。截图中的私有曲名、文件名等须换用受控样例或在分享前脱敏，诊断沿用[现有报告](../../DynamicIsland/Diagnostics/DiagnosticReport.swift)的数据边界。

### build5 首轮分辨率 fixture 与自动验证进度（历史）

已知同机几何为 **1470×956 / 179×32 pt 刘海间隔**及 **1280×832 / 156×28 pt 刘海间隔**。另设 **1710×1112 / 207×37 pt** 合成输入，明确标为 synthetic，不记作真机测量或硬件覆盖。生成图同时记录 backing scale、布局 scale、逻辑画布和 panel 尺寸，并提供相同 point 比例的顶部裁图及完整逻辑宽度视图。

以下保留 build5 首轮检查时的阶段记录；后续结果见[build5 实施记录](u02-resolution-adaptation-20261023.md)，当前 build6 结果见[修正记录](u02-refinement-20261023.md)。不同版本与批次分别记录：

- 定向 v2 已通过 **57 total / 56 passed / 1 skipped / 0 failures**。这轮结果限于当时的布局、几何、悬停、菜单、诊断及截图等定向范围，不代表完整 UI / 物理验收。
- 首轮全量为 **1114 total / 3 skipped / 4 failures**；四个失败均为既有测试中旧的 126 pt 计时预算预期。预期已随新的 150 pt 相机间距预算修正，像素遮挡断言保留；**完整重跑尚未完成**，不能将首轮记作通过。
- 原生控件专项仍在修正测试；新普通 Release 已构建成功。隔离副本 `/Users/rong5/Applications/Dynamic Island U02.app` 已准备、尚未启动，不能据此声称实际控件或物理交互已通过。
- 本轮用户原始显示设置为 **2560×1664**，已由用户切至 **1470×956**。验收后须恢复本轮原始 2560×1664；不能沿用历史 build4 的“恢复默认 1470”记录。系统设置读取工具发生 SCStream 错误，可能需要用户协助切换 / 确认；工具错误不记为产品布局失败或切换成功证据。

[公开 build4 的 B02 记录](evidence/b02-nondefault-20261022/README.md)与其 **1 passed / 8 pending** 设备矩阵保持原来源，不因 build5 开发更新而改写。T39、其他设备和干净 Mac 门槛继续独立保留。

## 6. U02 完成标准与本轮状态

只有在目标版本确定、上述布局归并实现、相应自动回归通过、用户报告的成组差异完成对照，以及 B01 / B02 对应的真实配置完成验证后，才依据证据评定 U02。报告需列出仍未覆盖的硬件 / 缩放组合及回退表现；不将局部通过表述为任意分辨率保证。

U02 当前为 **`in progress`**，实施目标为未发布的 **App 0.6.0 / 开发 build6**。本轮继续完成四项反馈的代码、自动回归、受控截图与审查，精确运行及提交结果集中于[build6 修正记录](u02-refinement-20261023.md)。真实屏幕的大小观感、清晰度、动画及交互确认按用户要求延期至[人工清单 M-U02-A–C](MANUAL_ACCEPTANCE.md)，不以自动结果替代；当前未验收，不标 verified，不改变原 T01–T40 的 39 verified / 1 in progress。

## 2026-10-23 实机反馈与停止点（历史）

用户确认各分辨率显示大小已统一，新增两翼过宽、展开岛体偏大、高分辨率收起/展开内容模糊及膨胀时顶部缝隙四项问题，详见[U02-07至U02-10待办](u02-followup-todo-20261023.md)。用户要求本轮停止实现，后续处理；U02保持`in progress`，不标记验收通过。模拟图和自动测试通过不抵消这些实机反馈。

用户随后恢复工作，2026-10-24 继续自动验证；上段保留原停止点，当前安排以本页摘要及[build6 修正记录](u02-refinement-20261023.md)为准，人工操作仍延期。
