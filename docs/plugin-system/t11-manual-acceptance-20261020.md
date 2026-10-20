# T11：真实 Timer 的 minimal → compact → expanded 验收

日期：2026-10-20。M04 第三轮使用普通 Release 隔离副本，真实按钮开始五分钟 Host countdown，用户移出后取得连续收起观察，再移回核对展开状态，最后用真实按钮结束。结果见[结构化归档](evidence/manual-remaining-20261019/m04-result.json)。原证据目录沿用准备时的日期，时间戳以本次实际 2026-10-20 记录为准；前两轮记录保留，不将第三轮结果反写为前两轮已通过。

## Host、原包与身份边界

[本日复核](evidence/manual-remaining-20261019/preflight-20261020.json)与[原构建预检](evidence/manual-remaining-20261019/preflight.json)共同记录 `Dynamic Island Acceptance.app`、bundle ID `com.rong5.dynamic-island.acceptance.20261019`、对应生产源码提交 `0fa8da4fde4f788e9717d16ced81bf054c1f3a0d`、101 个生产源码摘要匹配及 strict / deep 签名通过。当前 PID 仍为 7794，可执行文件 SHA-256 为 `5ba2f9371f63c2c993b5baa6331a24dee6fde8e448fbb65050bdc71a942cae38`。App 营销版本的历史开发元数据与内部 Host 0.6.0 范围保持原说明，不称作已公开发布的 App 0.6.0。

验收包 ID `com.dynamicisland.acceptance.timer-presentations`，版本 0.1.0，permissions 为空。原 `.dip` SHA-256 为 `307e53f9fa895bc0bb5b637638f0c1de73588fc347feb5f6ef90621d4f1a19e4`；[已安装记录](evidence/final-app-install-20261019/result.json)中的 `index.js` 摘要 `d555f742cfe0179560b404eb1dcb1dd8ccb00596270e85fbd95a3a1f8bdf51e5`、Manifest 摘要 `7de0e93046864c0d43af170285f1448d800e7f806ff54e14eb05b8ea8360e1a8`与未改动的[验收源码](examples/timer-presentations/index.js)相符。

源码只在启动时发布 Activity `timer`，之后使用 `activity.update`；所有三态 countdown 叶引用同一个 `timer.id` / `generation`。一次 `requestRefresh(30000)` 回执后，只有重新读取的 generation 仍相等且计时运行中，才添加 compact 树。[Host 更新实例契约](../../DynamicIslandTests/PluginActivityBridgeTests.swift)、[Countdown 绑定契约](../../DynamicIslandTests/PluginCountdownNodeBridgeTests.swift)、[Broker generation 契约](../../DynamicIslandTests/PluginCountdownBrokerTests.swift)及[同一正式 IslandView 三态测试](../../DynamicIslandTests/IslandTimerShellRenderingTests.swift)的既有[自动回归](evidence/final-regression-20261019/result.json)作为绑定证据。

**本次没有从原生 UI 读取 opaque Activity instance 或 countdown generation。** 同 Activity / generation 的判断来自上述真实未改动源码与正式 Host 合约，连续计时是额外可见证据，不能表述为已在 UI 直接观察到内部标识。没有通过私有入口开表、模拟时钟或重新发布新计时来制造三态。

## 实际观察与计时推进

[动作记录](evidence/manual-remaining-20261019/actions.json)以开始按钮调用时刻 `1792474449062 ms`（北京时间 13:34:09.062）为相对时间零点。它是工具调用起点，包含输入与 Host 处理时间，不是精确 countdown 开始 deadline。

| 相对开始按钮调用 | 真实界面与原始证据 |
| --- | --- |
| +0.669 秒 | 展开态显示 `minimal · 计时中`、05:00，进度近零：[AX](evidence/manual-remaining-20261019/m04-run3-started.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-started.jpg)。 |
| +20.015 秒，0 号观察 | 用户已移出；收起态只有 Countdown 叶，04:41，无 timer 图标：[AX](evidence/manual-remaining-20261019/m04-run3-frame-0.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-frame-0.jpg)。 |
| +31.882 秒，293 号 | 仍只有 Countdown，04:29：[AX](evidence/manual-remaining-20261019/m04-run3-frame-293.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-frame-293.jpg)。 |
| +31.929 秒，294 号 | AX 首次出现 timer image 与 Countdown，仍为 04:29；与前一条相隔 47 ms：[AX](evidence/manual-remaining-20261019/m04-run3-frame-294.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-frame-294.jpg)。该原图尚未检测到左侧青色图标，不能把 AX 出现直接等同于图标像素已绘制。 |
| +32.311 秒，304 号 | 保存的原图已可见左 timer 图标和右侧 04:29：[AX](evidence/manual-remaining-20261019/m04-run3-frame-304.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-frame-304.jpg)。这是已保存关键图中的首个可见图标，不将它写成精确动画终点。 |
| +44.973 秒，608 号 | 收起态保持左图标 / 右时间，倒计时继续为 04:16：[AX](evidence/manual-remaining-20261019/m04-run3-frame-608.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-frame-608.jpg)。 |
| +109.732 秒 | 用户重新展开并选择工具；显示 `compact · 计时中`、Host 刷新策略 `background`、03:12，AX progress 为 0.36302425639（显示 36%）：[AX](evidence/manual-remaining-20261019/m04-run3-reexpanded.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-reexpanded.jpg)。 |
| +118.486 秒调用结束按钮 | 真实按钮停止本轮，随后返回 `idle · 等待开始`、05:00 静态初值及进度 0：[停止动作](evidence/manual-remaining-20261019/m04-run3-stop.json)、[AX](evidence/manual-remaining-20261019/m04-run3-stopped.txt) / [图像](evidence/manual-remaining-20261019/m04-run3-stopped.jpg)。该 05:00 是等待开始提示，不是新一轮自动计时。 |

[连续观察文件](evidence/manual-remaining-20261019/m04-run3-observation.json)保存 **609 条 AX 观察，609 条均为收起态**，以及 0、293、294、304、608 五张未改写关键图。0 至 293 号共 294 条只有 Countdown；294 至 608 号共 315 条包含 timer 与 Countdown。全部记录都有倒计时，数值非递增，相邻最大下降 1 秒，无归零或向上重置。

首末观察跨 **24.958 秒**，可见时间从 04:41 推进到 04:16，下降 25 秒，与整秒显示的取整一致；最大相邻工具观察间隔为 67 ms。609 条工具采样不代表屏幕渲染帧率，也不将 AX 转换的 47 ms 区间冒充动画耗时。展开进度乘以 300 秒得到已用约 **108.907 秒**，与 03:12 剩余时间相符；它不是更高精度的独立时钟测量。

30 秒是刷新请求值，实际由 Host 背景策略、处理与合并决定。本轮实际返回 `background`，并完成同一计时的 minimal → compact → expanded；没有以 30 秒整点作为必须达标的期限。

## 原图中的前景位置

只读解析原始 JPEG，未编辑图片。图像为 520×240 像素；在截图区域 `x ∈ [40,480)`、`y ∈ [0,56)`，采用 deviceRGB 的 `R < 190、G ≥ 60、G−R ≥ 15、B−R ≥ 15` 识别青色前景，再以图像宽度中点区分左右半幅。以下范围为包含端点的**截图像素坐标**：

| 原图 | 左半幅青色前景 | 右半幅青色前景 |
| --- | --- | --- |
| 0 号 minimal | 无 | x 433–460，y 24–31 |
| 293 号 minimal | 无 | x 433–461，y 24–31 |
| 294 号首次 compact AX | 无 | x 441–469，y 24–31 |
| 304 / 608 号 compact | x 51–61，y 23–33 | x 441–469，y 24–31 |

这客观描述了保存图中单独右侧时间与左右分列内容；没有记录实际相机的屏幕坐标，因此不从这些范围推算物理相机边缘、间距或屏幕 point 数值。先前受控几何测试的相机间隔继续保留原测试范围。

## 结论与未扩大的范围

M04 第三轮已完成真实按钮开始、连续 minimal → compact、重新展开后的计时 / 进度连续以及真实按钮停止。结合既有身份和渲染合约，T11 已在任务总表标为 `verified`，满足同一 Timer Activity 三态显示的完成标准。

本轮未更改 Reduce Motion，未新增系统外观、多显示器、无刘海、睡眠或热拔插矩阵；既有历史可访问性证据不扩大为本次重测。未重新运行测试或修改生产源码。无需等待五分钟自然到期，也不重跑此前已完成的十五分钟 Pomodoro；T39 作者体验及 SDK / Registry 发布状态分别追踪。
