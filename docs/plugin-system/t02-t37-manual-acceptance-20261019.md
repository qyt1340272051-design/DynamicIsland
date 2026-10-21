# T02 / T37：菜单与兼容子集实机验收

日期：2026-10-19。本轮用户恢复人工验收，完成 M03 菜单隐藏 / 显示、三个原创兼容示例及独立 AI 作者工具的真实按钮检查。[结构化结果](evidence/manual-remaining-20261019/m03-result.json)、[动作时间记录](evidence/manual-remaining-20261019/actions.json)和[截图 / AX 索引](evidence/manual-remaining-20261019/screenshots.json)分别保存结果、输入与原始观察。索引后续也可包含 M04 记录，本页仅归并 M03。

## Host 与范围

[本轮预检](evidence/manual-remaining-20261019/preflight.json)记录普通 Release 隔离副本 `/tmp/dynamic-island-final-20261019/Dynamic Island Acceptance.app`，bundle ID 为 `com.rong5.dynamic-island.acceptance.20261019`。源码身份为 `0fa8da4fde4f788e9717d16ced81bf054c1f3a0d`；101 个生产源码摘要匹配，strict / deep 签名通过，可执行文件 SHA-256 为 `5ba2f9371f63c2c993b5baa6331a24dee6fde8e448fbb65050bdc71a942cae38`。

App 营销版本仍为历史开发元数据 `0.5.0`，内部插件 Host 版本为 `0.6.0`。这是隔离副本的实机验收，不是已公开发布的 App 0.6.0 二进制。此前五个包实际导入、安装后停用、逐个明确启用且无额外权限的过程见[安装记录](evidence/final-app-install-20261019/result.json)；本轮继续使用已安装示例，没有通过启用隐式批准权限。

T37 范围采用用户明确选定的“交付兼容子集，用独立编写的简单插件完成实机验收”。[三个示例](t37-independent-examples.md)均为本项目原创、附 MIT 许可。未把原样上游插件运行或其许可缺口计为本次通过项，也未宣称完整 SuperIsland 兼容。

## T02：菜单隐藏 / 显示

用户在验收副本菜单执行隐藏，先确认已点击，随后明确确认隐藏时刘海消失、现已显示并展开。本轮保留了[隐藏操作记录](evidence/manual-remaining-20261019/m03-hide.json)及[恢复显示后的实际截图 / AX](evidence/manual-remaining-20261019/m03-shown-expanded.txt)。

**隐藏状态没有取得截图。** 隐藏后的 AX 读取超时，超时本身不能证明窗口消失；此项消失 / 恢复依据用户直接确认，恢复后的 UI 另有原始截图。没有生成隐藏像素或将 AX 超时写成已观察到窗口不存在。

结合既有[基线清单与量化归档](t02-t08-acceptance-20261019.md)，本次关闭 T02 最后保留的菜单隐藏 / 显示条件。旧资源采样仍是本轮 UI 修正前的冻结起点，不因菜单验收通过而变成新 UI 资源对照，也不重新声明全设备场景实测。

## T37：三个原创兼容示例

下列操作使用 CUA 原生控件输入，结果对应未改写的截图与 AX 记录；真实按钮没有替换为直接调用 JavaScript 或 Host 私有入口。

| 检查 | 实际结果与证据 |
| --- | --- |
| 状态切换 | 初始“就绪”经“切换状态”变为“暂停”，再切回“就绪”；见[暂停](evidence/manual-remaining-20261019/m03-status-paused.txt)及[恢复](evidence/manual-remaining-20261019/m03-status-restored.txt)。 |
| 计数更新 / 归零 | “加一”使 0 → 1，“归零”回 0；见[加一](evidence/manual-remaining-20261019/m03-counter-one.txt)及[归零](evidence/manual-remaining-20261019/m03-counter-reset.txt)。 |
| 四步进度 | 从 0/4 逐次到 4/4，AX progress 值依次为 0、0.25、0.5、0.75、1，对应 0% 至 100%；随后归零，见[起点](evidence/manual-remaining-20261019/m03-progress-zero.txt)、[终点](evidence/manual-remaining-20261019/m03-progress-4.txt)及[重置](evidence/manual-remaining-20261019/m03-progress-reset.txt)。中间帧及原始图像见索引。 |
| Host 展示意图 | “请求展示”得到“已请求”，“撤回请求”得到“已撤回”；撤回后用户已选择的工具仍可见，见[请求](evidence/manual-remaining-20261019/m03-progress-request.txt)与[撤回](evidence/manual-remaining-20261019/m03-progress-dismiss.txt)。这些文字表明意图提交，不代表插件获得窗口控制权。 |
| 跨工具隔离 | 操作进度后返回状态仍为“暂停”、计数仍为 1；返回进度仍为 4/4 和“已撤回”。三个示例共用 `increment` 动作名，未发生串线；见[状态](evidence/manual-remaining-20261019/m03-status-isolated.txt)、[计数](evidence/manual-remaining-20261019/m03-counter-isolated.txt)、[进度](evidence/manual-remaining-20261019/m03-progress-isolated.txt)。 |
| 停用移除工具 | 先使三包分别处于暂停、1 次和 1/4 的非初始值，再逐个停用；三包均从真实工具菜单消失，见[停用后的菜单](evidence/manual-remaining-20261019/m03-disabled-tools-absent.txt)。 |
| 明确再启用重置 | 逐包明确再启用并重新选择；状态恢复“就绪”、计数为 0、进度为 0/4 且意图“未发送”，见[状态](evidence/manual-remaining-20261019/m03-reenabled-status-reset.txt)、[计数](evidence/manual-remaining-20261019/m03-reenabled-counter-reset.txt)、[进度](evidence/manual-remaining-20261019/m03-reenabled-progress-reset.txt)。 |

停用后旧实例动作拒绝、critical 抢占和同实例更新，已有[真实示例 Runtime / Router 集成测试](../../DynamicIslandTests/SuperIslandModuleRuntimeTests.swift)及[完整回归](evidence/final-regression-20261019/result.json)覆盖。本次实机证明停用工具从菜单移除和再启用初值；**没有直接调用保留的旧动作，也没有制造新的真实 critical 事件**。自动状态机证据与本次真实 UI 证据分别保留。

## 独立 AI 作者包的实际按钮

独立作者原包先前的[资料开发过程](evidence/t39-independent-20261019/result.json)与[正式 Host 自动闭环](t38-independent-host-20261019.md)之外，本轮实际选择“双按钮状态”，从“待选择”点击专注按钮得到“专注中”，再点击休息按钮得到“休息中”；对应[初始](evidence/manual-remaining-20261019/m03-independent-initial.txt)、[专注](evidence/manual-remaining-20261019/m03-independent-focus.txt)及[休息](evidence/manual-remaining-20261019/m03-independent-rest.txt)的原始 AX / 图像记录。

这补充了原包在普通 Release 实际 UI 中可用的证据；不把助手操作算作人类新作者独立构建安装，也不把先前 137.7 秒离线开发时间扩写为本轮 UI 用时或十分钟目标通过。

## 启动期间的状态观察

管理页最初显示五个已启用包为“已加载”，随后在**未重启**的同次验收中显示全部“运行中”，见[较早状态](evidence/manual-remaining-20261019/m03-startup-loaded-not-running.txt)与[后续诊断](evidence/manual-remaining-20261019/m03-diagnostics-running.txt)。后续[供电快照](evidence/manual-remaining-20261019/power-current.txt)为 AC Power、29%、正在充电；源码中的低电量执行门槛与观察最吻合。

初始时刻没有直接供电记录，不能据后续快照确认当时阻止执行的原因。本轮未将该观察认定为已确认缺陷，也未修改源码、宣称修复或归因于重启。

## 状态结论

M03 已通过：T02 的剩余菜单条件关闭；T37 在用户批准的原创兼容子集范围内完成真实 UI，与既有 Runtime / Router 证据共同满足若干简单兼容插件可运行且受 Activity 调度约束的标准。T02、T37 已在任务总表标为 `verified`。T11 的真实计时三态、T39 的作者体验及 T38 / T40 发布门槛仍由各自记录判断，本结果不自动关闭它们。
