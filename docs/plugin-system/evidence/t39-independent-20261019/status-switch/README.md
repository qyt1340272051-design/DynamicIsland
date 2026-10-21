# 双按钮状态

从独立 SDK 1.0.0 发布候选的文档、类型和 Hello 模板编写的演示插件。
`com.example.independent-status` 是走查用示例 ID，分发前应替换为作者控制的标识。

预期操作：导入并安装后单独启用，展开刘海，从工具菜单选择“双按钮状态”。
初始文字为“当前状态：待选择”；“专注”选择“专注中”，“休息”选择“休息中”。
两个按钮在同一行。状态仅存于当前执行内；停用、重启或新的执行会恢复“待选择”。

插件仅调用 `island.actions.on`、`island.activity.publish/update`。
不使用存储、网络、链接、倒计时、刷新、文件、系统资源或 JavaScript 计时器。
Manifest 的 permissions 为空。声明的四项 capability 与 Hello 一致。
两个动作先完成注册，再发布 Activity；更新等待确认后提交本地状态，拒绝时保留旧状态。
初始化拒绝会被捕获，需在 Host 查看诊断。此走查仅完成离线校验和语法检查，尚未验证实际安装和展示。

使用 SDK 工具校验和打包：

```sh
python3 /tmp/dynamic-island-sdk-1.0.0-walkthrough-20261019/DynamicIslandSDK/tools/di_plugin.py validate /tmp/dynamic-island-independent-author-20261019/status-switch
python3 /tmp/dynamic-island-sdk-1.0.0-walkthrough-20261019/DynamicIslandSDK/tools/di_plugin.py package /tmp/dynamic-island-independent-author-20261019/status-switch /tmp/dynamic-island-independent-author-20261019/status-switch-0.1.0.dip
```

输出路径须尚不存在。类型引用只供编辑器使用，指向本次走查的独立 SDK，并不参与运行。
