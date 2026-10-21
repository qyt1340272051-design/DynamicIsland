# T37 子步骤：由 Host 裁决的展示请求

日期：2026-10-17。接续[同 VM 模块闭环](phase-8-t37-module-runtime.md)。本子步骤映射 activate / dismiss；T37 仍为 `in progress`，兼容限制详情与真实上游插件验收尚未完成。

## 独立能力与同步协议

兼容包须明确声明 `presentation.request` capability。这不是新增系统 permission，不授予文件、网络或窗口操作权限。现有包没有这项声明时，请求返回拒绝；不改变已安装官方包的声明或授权。能力变化仍使既有权限审阅失效。

| 上游调用 | 本子步骤映射 |
| --- | --- |
| `SuperIsland.island.activate()` / `activate(undefined)` | 请求默认自动撤回的临时展示。 |
| `activate(true)` | 同上，默认 Host 期限 3 秒。 |
| `activate(false)` | 请求较长展示；Host 仍施加默认 30 秒上限，回执为 degraded / boundedDuration。 |
| `dismiss()` | 仅撤销本执行、同一 Activity 实例获准的临时展示，不结束模块数据，不清除用户选择或收起窗口。 |

这些调用严格检查参数并同步返回 undefined。对象、字符串、数值和多余参数不会被隐式转换；`supported=true` 表示可申请，不表示保证展示。onDeactivate 清理期间的无参 dismiss 作为无副作用操作接受，停止后发起的新调用拒绝。

## Host 许可和调度

[PresentationRequest / PresentationDecision](../../DynamicIsland/Core/Activity/PresentationRequest.swift) 是纯数据；[ActivityManager](../../DynamicIsland/Core/Activity/ActivityManager.swift) 单独保留至多一个请求租约，用户选择仍由 selectedTool 表示。请求不会走用户选择的防抖 / 源限速豁免。

[生产 Runtime](../../DynamicIsland/Core/Activity/IslandActivityRuntime.swift) 使用六路实际发布值给出允许状态：面板可见、已经展开、tools 页、无拖动、无锁定拖盘、无原生计时完成提示。其他状态默认拒绝，不排队等待自动出现；不写悬停、展开状态、原生页面或窗口。

- 有用户工具选择、其他实例租约、重要 / 关键 / 普通 transient 状态时拒绝新请求；重要状态出现会撤掉已有租约，不在状态结束后自动恢复。
- 每次 Host 从不允许进入允许状态，只提供一次新展示机会。重复 activate 不续期；到期或 dismiss 不返还本次机会，不能靠反复调用长期占据页面。
- 期限从 Host 获准时开始，并纳入现有集中 ActivityScheduler；没有增加每插件定时器。普通最短展示时间、防抖和来源限速继续生效，获准只表示进入候选，不保证立即可见。
- 收起、切换旧页或工具、面板隐藏、拖动、锁定拖盘、完成提示、来源停用、实例结束、睡眠及执行撤销会撤回请求。到期只清除租约，模块 Activity 仍保留。

## 精确实例和渲染事务

私有 `superisland.render` 成功回执增加 opaque presentationHandle。Host 在执行上下文中至多保留一个绑定：来源、执行和精确 ActivityInstanceToken。更新保留同一 handle；结束后重建相同 ID 必须产生新 handle。旧执行、旧句柄和其他插件的句柄均不能重定向。

私有 `superisland.presentation` 只接收 operation、handle，以及 activate 的原始布尔 autoDismiss；拒绝额外身份、时长、优先级或窗口字段。上游代码不能获得或指定 Host token。

适配器把本轮最后一条意图绑定到对应的布局请求，成功渲染后才提交；渲染失败、合并替换或停止会丢弃相应意图。仍最多一个在途布局和一个替代布局。生命周期、动作和视图回调内的请求先完成本帧；回调外请求也经过同一有界流程。

Host 回执为 accepted / degraded / rejected 及有限原因，诊断使用固定文本。缺能力、Host 场景拒绝和正常限频不计入严重故障隔离；限频也不会破坏旧布局和按钮。私有 Promise 回执继续使用已捕获的内建方法。

## 同步通知撤销与验证

回归发现：`@Published` 的同步状态通知中撤销 Host 许可或移除来源后，外层旧更新会把已撤回的工具写回当前展示。修复前两项真实测试失败，原始结果和源码身份随[本轮证据](evidence/t37-presentation-20261017/result.json)保留。修复采用串行 reconcile drain，同步回调只标记需要重算；调度元数据在发布前提交，来源移除后不会被外层补回。待处理撤回期间拒绝动作授权，返回获准前再检查租约、实例、来源与执行。两项复现及补充重入 / deadline 回归均已通过。

选测 **144 passed / 0 skipped / 0 failures**，其中 Core 请求 23 项、原始 Host 桥接 6 项、真实 VM 请求 12 项；另含生产 Runtime、Manifest / 授权、原生调度和生命周期回归。完整 `Scripts/ci.sh` 为 **1009 total / 1002 passed / 7 skipped / 0 failures**，普通 Release build / strict / deep 签名通过，没有测试专用权限。7 项 skip 仍为 5 项锁屏鼠标输入、显式截图矩阵和默认关闭的 live 网络选测。结果见[本轮证据](evidence/t37-presentation-20261017/result.json)。未启动 T35 / T36 验收副本；人工步骤继续保留在[清单](MANUAL_ACCEPTANCE.md)。

[兼容限制详情](t37-compatibility-details.md)已完成；具备许可依据的固定上游样本验收仍保留，见[来源审计](t37-upstream-acceptance-audit.md)。本子步骤不提前接受 T37 或发布稳定 SDK。
