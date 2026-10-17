# T37 显式运行模式与授权合约

日期：2026-10-17。此页记录 Manifest 模式选择，整个 T37 仍为 `in progress`；真实上游插件验收尚未完成。

## 明确选择模式

`PluginManifest.engine` 保持有限枚举：

| 值 | Host 解释 | 管理页标识 |
| --- | --- | --- |
| `javascriptcore` | 原生 Plugin API V1。 | 原生 JavaScriptCore |
| `superisland` | [固定来源范围](phase-8-t37-superisland-scope.md)中的 SuperIsland V1 协议配置，仍在同一隔离 JavaScriptCore VM 内执行。 | SuperIsland（有限兼容） |

不会根据脚本中的 `SuperIsland`、`View` 或其他全局变量自动识别模式，也不会在兼容入口失败后回退执行原生模式。模式声明不代表全部上游 API、视图样式或窗口行为兼容；管理页使用 Host 的有限枚举，不接收包自行声明的兼容等级。

兼容包仍须提供严格的 DynamicIsland Manifest V1 外壳，不直接接收任意上游 Manifest。九个必填字段和可选 developer 保持一致；未知字段、权限、capability、重复字段、非标准路径和输入上限继续拒绝。`schemaVersion` 没有改变。

## 审阅与授权失效

模式属于已验证包的不可变 Manifest。安装预览的整包指纹包含 manifest 文件；模式改变后旧预览不得提交。Manager 的包比较和重新加载比较包含整个 Manifest，模式改变会停用旧启用状态。

权限管理的内存指纹和持久指纹已有 `engine`：仅改变模式也必须撤销旧 lease、使旧授权审阅过期，并将新权限状态恢复为待授权。返回原生模式不会自动恢复同一进程中旧的授权。启用兼容包仍不授予任何权限。

安装预览也读取已验证 Manifest 的 engine，显示同一有限兼容标识；准备和提交仍不运行插件，安装后保持停用。

定向回归覆盖两种模式的编码往返、非法模式、未知字段与声明、escaped 重复 engine，以及模式变更后的持久授权失效和现存 lease / review 撤销。Manifest 18 项、持久权限 16 项及安装 20 项均通过，属于本轮 133 项选测的一部分，见[统一证据](evidence/t37-module-20261017/result.json)。同 VM 接线见[模块子步骤](phase-8-t37-module-runtime.md)，真实上游插件验收仍待完成。
