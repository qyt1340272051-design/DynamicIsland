# T37 子步骤：有界 View 数据转换

日期：2026-10-17。基于[固定上游范围](phase-8-t37-superisland-scope.md)独立实现首批视图转换；这是兼容层底座，整个 T37 仍为 `in progress`。

[SuperIslandViewConverter](../../DynamicIsland/Compatibility/SuperIslandAdapter/SuperIslandViewConverter.swift) 只接收 `PluginBridgeJSON` 纯数据，输出 Host `IslandNode`、有限的限制原因集合和动作 ID 引用。数据不携带 JSValue、回调或原生对象。字段依据固定版本的[上游 ViewNode 解析](https://github.com/shobhit99/SuperIsland/blob/68cce87205a88a004e74e33f40bbcb253f8287e9/ExtensionHost/ExtensionViewNode.swift)，不是复制上游实现。

| 上游描述 | Host 节点 | 规则 |
| --- | --- | --- |
| text / value | text / content | 有界 UTF-8 文本；已知字体与行数选项记录为 Host 外观限制。 |
| icon / name | icon / symbolName | 有界系统符号；已知大小与颜色记录外观限制。 |
| hstack / vstack | hStack / vStack | 递归转换 children；有限 spacing、align、distribution 选项按 Host 布局降级并记录原因。 |
| progress / value / total | progress / value | total 默认 1；有限数值、total > 0、0 ≤ value ≤ total，转换为比值。 |
| button / label / action | button / label / actionID | 递归转换标签，收集有界 action ID；实际注册和授权仍属于 Host ActionRouter。 |

不支持的节点、属性、类型或样式返回固定错误；未知字段与 RGBA / 任意颜色输入不会静默进入 Host。已知外观差异作为 typed limitation 返回，后续兼容等级显示必须保留这些差异。

转换先做有界纯值校验，再按节点递归限额映射，最后重新经过现有 `PluginIslandNodeConverter`。沿用节点深度 8、总数 128、每层子节点 16、文本 256 UTF-8 字节、symbol 128 字节、action ID 80 字节的限制；JSON 辅助入口检查 64 KiB 及重复字段。没有改变现有 Bridge 请求、网络或存储配额。

## 验证与当前边界

[转换测试](../../DynamicIslandTests/SuperIslandViewConverterTests.swift)覆盖真实协议字段、布局与按钮引用、进度比值、外观限制、未知输入、重复字段及边界值。转换器 11 项与 Manifest 17 项选测共 **28 passed / 0 skipped / 0 failures**，普通 Release 编译与 strict / deep 签名校验通过，见[验证结果与源码哈希](evidence/t37-view-20261017/result.json)。

同时修正公开 Manifest Schema 的过期数组上限：权限 8 项、capability 9 项，与现有 Swift 有限集合一致。此前 7 项上限会误拒绝分别声明 8 项 capability 的 Pomodoro / GitHub 官方示例；新增回归覆盖全部 7 份示例和完整枚举集合。此项没有改变 Host 运行时资源配额。

本转换子步骤完成时尚未接入 Module 生命周期、Manifest 模式、运行时动作回调、PresentationRequest 或管理页兼容标识。后续已完成[显式模式](phase-8-t37-manifest-profile.md)和[同 VM 模块闭环](phase-8-t37-module-runtime.md)；PresentationRequest 与真实上游插件验收仍待完成。自动转换测试不代表真实上游插件已在兼容模式运行。
