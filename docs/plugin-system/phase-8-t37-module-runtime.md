# T37 子步骤：同 VM 模块生命周期与动作

日期：2026-10-17。接续[有界 View 转换](phase-8-t37-view-conversion.md)和[显式运行模式](phase-8-t37-manifest-profile.md)。本页记录最小模块闭环；后续已接入[Host 展示请求](t37-presentation-requests.md)，整个 T37 保持 `in progress`。

## 输入与 Host 映射

固定协议来源仍为 [SuperIsland 68cce872 的 Runtime](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionJSRuntime.swift)与[Builder Guide](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/SUPER-ISLAND-EXTENSION-API.md)。适配器独立实现协议；测试夹具自行编写，没有复制或分发上游插件。

| 输入 | 本子步骤行为 |
| --- | --- |
| `SuperIsland.registerModule(config)` | 每次执行只允许注册一个模块；只接受 compact、expanded、onActivate、onDeactivate、onAction 五个字段。compact 必须是函数，其余可选函数；拒绝未知字段和属性访问器。 |
| compact / expanded | 同步返回上游节点数据；expanded 缺省复用本次 compact 数据。经安全快照和 Swift View 转换后，发布或更新 Host 工具 Activity。 |
| onActivate / onDeactivate | 与本次 Host 执行的开始 / 停止绑定；同步且必须返回 undefined。悬停展开不触发新的执行，也不重复调用激活。 |
| onAction | 由现有 ActionRouter 和实例绑定的 PluginActionSession 投递；同步回调后重新生成布局，不接受兼容层制造的 activation。 |
| View 六种工厂 | 支持 text、icon、hstack、vstack、progress、button；节点参数仍经过已有有界转换。 |
| activate / dismiss | 模块子步骤初验时不支持；后续已映射为[由 Host 裁决的 PresentationRequest](t37-presentation-requests.md)，仍不能直接展开或收起窗口。 |

适配器和入口脚本运行在同一个独立 VM 中。Runtime 保留私有生命周期 receiver；兼容脚本定义全局 onStart / onStop 不能替换这些 receiver。Native 模式不注入 SuperIsland / View，不自动探测或回退。

## Host 边界

- 新私有桥接方法 `superisland.render` 仅在已验证的显式模式中接受，参数只能包含 compact / expanded 两份节点快照。插件不能在此指定 Activity 身份、优先级、生命周期、标题或权限。
- Host 固定本地 ID 为 `superisland-module`，加上现有插件命名空间；标题取已验证 Manifest。输出为 background / persistent / tool，compactPolicy 为 selectedOnly。没有更改 ActivityManager 或窗口调度语义。
- 发布 / 更新继续走普通 PluginActivityConverter、能力声明、每插件限频和当前执行撤销检查。Manifest 名称仍须满足 Activity 标题的 256 UTF-8 字节限制，超限拒绝。两种布局的动作 ID 取并集，最多八项；注册完成后才提交可操作布局。
- 新布局被 Host 拒绝时回滚新增动作，保留旧布局和旧动作；只有替换成功后才注销不再使用的旧动作。现有动作 ID 不重复注册，保持实例与注册凭证的有效范围。
- 失败诊断只有 Host 固定类别和文本，不记录插件抛出值。停用、重载与关闭继续撤销会话和旧回调；模式变化后的授权需要重新确认。
- 安装预览和管理页均由 Host 显示「SuperIsland（有限兼容）」，不能由包自报为完整兼容。

模块子步骤只在开始和动作后渲染；后续外部展示请求也经过同一有界渲染管线，不轮询模块或引入 JS 定时器。异步生命周期 / 渲染 / 动作、fullExpanded、minimalCompact、上游资源直通和窗口状态同步未实现；不支持的输入会拒绝。没有请求新的系统权限。

## 验证与继续位置

验证结果和源码身份记录在[本轮证据](evidence/t37-module-20261017/result.json)。17 项模块测试运行真实 VM / ActionRouter，覆盖六种 View、生命周期、配置 / 渲染访问器、Promise 数据拒绝、模式与能力检查、停用重启、双插件隔离、失败替换回滚，以及内建方法 / Promise 污染后的正常动作。另有 4 项转换边界测试及模式、授权、安装、原生 Runtime / 动作回归；选测 **133 passed / 0 skipped / 0 failures**。

模块初验时完整 `Scripts/ci.sh` 为 **962 total / 955 passed / 7 skipped / 0 failures**，普通 Release build 与 strict / deep 签名校验通过，保持普通沙盒与 JIT 配置，没有测试专用权限。测试夹具的真实 VM / ActionRouter 闭环与真实上游插件的产品验收分别记录，前者不能替代后者。7 项 skip 为 5 项锁屏鼠标输入、显式截图矩阵和默认关闭的 live 网络选测；没有把跳过算为通过。后续当前回归结果见[展示请求记录](t37-presentation-requests.md)。

后续 [PresentationRequest 子步骤](t37-presentation-requests.md)和[兼容限制详情](t37-compatibility-details.md)已完成；具备许可依据且匹配子集的固定上游样本验收仍保留，见[审计](t37-upstream-acceptance-audit.md)。T35 补拍与 T36 实机验收继续保留在[人工清单](MANUAL_ACCEPTANCE.md)。本子步骤不提前接受 T37，也不发布稳定 SDK。
