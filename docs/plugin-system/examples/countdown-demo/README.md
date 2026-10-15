# Host 倒计时示例

T35 声明式倒计时节点的最小验证包。无权限，只声明 Activity、IslandNode、动作和 countdown capability，全部使用公开 `island` API。

## 使用

安装并启用后，展开刘海，在工具菜单选择「Host 倒计时示例」。四个按钮分别开始 10 秒倒计时、暂停、继续和结束。再次开始会重置为 10 秒；结束会删除 Host 计时记录并恢复等待界面。尚未开始时，暂停、继续和结束保持等待状态。

时间与进度均为 `{type: 'countdown', id, generation, style}` 引用，Host 根据自己的连续时钟显示。JavaScript 没有计时器、每秒刷新或 Scheduler 请求；只在真实动作、Host 完成事件和启动恢复时更新 Activity。开始和继续使用当前真实动作的一次性 `activation`，完成事件不会自动重新开始。

收起、切换页面或隐藏工具会清除工具选择，但不会停止 Host 计时。再次展开后需要重新选择该工具；本例不自动在 compact 状态显示。包提供 minimal、compact 和 expanded 布局，呈现时机由 Host 决定。

`onStart` 同步返回，通过 Promise 注册动作与完成回调，再调用 `countdown.get('clock')` 恢复当前 Host 记录。执行因睡眠等原因恢复时可接回保留的计时；停用、卸载、重载或退出应用会清除计时，本例不提供跨应用重启持久化。

此包用于验证通用能力，尚未替代正式 Pomodoro 官方插件。
