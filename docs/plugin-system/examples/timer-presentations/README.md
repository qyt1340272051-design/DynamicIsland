# T11 真实计时三态验收包

本项目自行编写的验收示例，使用原生 `javascriptcore` 模式和公开 Host API，不是 SuperIsland 上游样本。此包用于验证 T11，不加入正式 Registry。

**无资源权限。** Manifest 的 `permissions` 为空；不读取或写入 Storage、不联网、不读剪贴板或文件。开始必须由真实按钮提供 activation；启用和 App 重启不会自动开始。倒计时、显示 tick 和一次刷新均由 Host 管理，没有 JS 定时器。

## 打包

在项目根目录运行：

```sh
python3 SDK/tools/di_plugin.py validate docs/plugin-system/examples/timer-presentations
python3 SDK/tools/di_plugin.py package docs/plugin-system/examples/timer-presentations /tmp/timer-presentations-0.1.0.dip
```

## 一次集中验收

1. 在隔离验收 App 中导入 `.dip`，确认权限为空、安装后停用；启用并选择工具「计时三态验收」。
2. 点击「开始三态验收」。它使用真实 activation 开始 **5 分钟** Host countdown，并更新同一个 Activity `timer`。不用等五分钟结束，完成三态观察后即可结束。
3. 立即移出刘海。先看到右侧单独时间，只有一个 `minimal` 时间叶，**没有 compact 树**；时间应持续推进且位于物理相机右侧。
4. `requestRefresh(30000)` 的 **30 秒是请求值**。等 Host 集中 Scheduler 真正完成这次刷新后，示例只给同一 Activity 添加 compact 树。收起态应平滑变为左侧 timer 图标、右侧原计时；不会重新开始、改变 countdown generation 或发布新实例。当前 background 下限为 30 秒、lowPower 下限为 60 秒，并有向后合并；策略切换等还可能继续延后。以实际完成及 Host 回执 `policy` 为准，不按 30 秒准点判定失败。
5. 再次展开并选择本工具。expanded 显示相同计时的时间和进度、`compact` 阶段及本次 Host 回执策略；点击「结束验收」清除记录，再正常退出隔离 App。

记录原包 / Host 构建身份、启用与权限状态、连续 minimal → compact 帧、展开帧、同一 Activity / countdown 身份及时间推进。Reduce Motion 开启时核对不会出现非必要模式动画；不通过修改用户设置来冒充该场景已测。正式物理岛体与受控 NSHostingView 回归分别记录。

结束时若先前一次刷新仍在等待，示例不会申请第二个刷新，也暂不展示新的开始按钮；Host 原请求完成后恢复。停用 / 退出由 Host 撤销当前执行、计时和待刷新，迟到回复不能启动新一轮。

此目录本身不是已通过的实机证据。只有实际导入、真实按钮开始、收起 / 展开观察和归档结果完成后，才能关闭 T11 的剩余门槛。
