# Debugging

先校验并打包，然后使用插件管理的「查看诊断」。诊断保留 Host 选择的错误代码、级别与阶段；`island.log` 的消息正文不会进入保留记录，任意 JS 异常文本也不会作为诊断正文展示。请按稳定 code 分类，不依赖 Error 原型或 stack。

| 现象 / code | 检查与处理 |
| --- | --- |
| CLI invalidManifest / duplicateField | 确认 JSON 类型、必填字段、重复键和声明闭集。看 CLI path；它是开发预检，不等同 Host 安装错误。 |
| 安装失败 / 最低版本不符 | 使用支持 minimumHostVersion 的开发 Host；确认根目录 Manifest、入口和规范路径。 |
| 启用后没有 UI | 检查初始化拒绝；tool 需展开后从工具菜单选择。Hello 隐藏 compact，不自动展开。 |
| capabilityRequired / permissionRequired | 添加确实需要的声明后重新打包、导入；权限还要单独确认。 |
| permissionNotGranted / permissionDenied / permissionRevoked | 在插件管理查看该项状态；业务采用有限降级，不循环弹窗或自动重试授权。 |
| invalidArguments | 对照类型与节点 Schema；不要传 null 替代省略、undefined、非有限数、未知字段或假的 generation。 |
| activityNotFound / staleCountdown | 旧实例或旧 generation 已结束；重新查询当前资源，不复用旧按钮。 |
| activationRequired | 在当前真实动作回调中立即提交票据；缺省时不执行受保护操作。 |
| networkPolicyDenied / linkPolicyDenied | 检查 HTTPS、允许的域名、方法、URL 和目标；公开 SDK 不接受任意目标。 |
| networkTimeout / networkTransportFailed / networkResponseTooLarge | 显示有限错误，减少响应，退避；不能自动增加 Host 限额。 |
| storageReadFailed / storageWriteFailed | 使用默认值或内存状态，显示未保存；不要启动时覆盖不明数据。 |
| quotaExceeded / rateLimited | 减少在途工作、合并更新、延后重试。不要 tight loop。 |
| inactiveExecution | 本次执行已停止，结束该 Promise 链；不要继续操作新执行。 |
| 启动 / 动作故障，随后自动停用 | 检查同步 hook、未捕获异常和耗时循环。修复后通过 Host 诊断重启 / 启用，不绕过隔离。 |

纯 JSON 校验不会解释 JavaScript，类型检查也不能证明业务正确。可选执行 SDK 的 npm 安装锁定开发依赖，再运行 package.json 中的 check:types；插件本身不需要这些依赖。最小复现优先从 Hello 开始，每次只增加一个资源或节点。

报告问题时附 Host / 插件版本、有限错误 code、复现步骤以及是否发生在启用、动作或恢复阶段。不要把凭据、私人存储、网络响应或插件包内未授权资料直接贴进公开问题。UI 问题记录展开 / 收起状态及预期布局，真实相机遮挡需要设备检查。
