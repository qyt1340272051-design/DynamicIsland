# Phase 7 — T35 Pomodoro 官方插件

日期：2026-10-14。直接依赖 T24–T34 均已 verified；T31 的真实后台空闲证据已提交。T35 状态为 `in progress`，总体迁移顺序见[准备记录](t35-migration-preparation.md)。

## 子步骤 1A：公开 compact 可见性字段

插件的 `activity.publish` / `activity.update` presentation 现在接受已有数据模型的可选 `showsCompact` 布尔值。false 表示 compact 不显示，true 表示显示；省略保持 nil，沿用 Host 的默认显示行为。插件仍提交受限数据，最终展示由 Host 决定。

```javascript
await island.activity.publish({
  id: 'session', lifecycle: {policy: 'persistent'},
  presentation: {title: '番茄钟', showsCompact: false}
});
```

JS 在安全 snapshot 后验证 presentation 精确字段和布尔类型，再发送请求，不重新读取用户对象或调用 getter；Host Converter 独立校验。null、数字、字符串、数组、对象、未知字段及重复 JSON key 均拒绝，不做类型转换。现有 capability、执行会话、配额和限频仍适用。

update 只修改 priority 等顶层字段时保留原 presentation；提交新的 presentation 时仍整体替换，省略 showsCompact 会恢复 nil。JS API version 沿用 1.0.0：这是可选字段扩展，旧输入保持默认行为。

新增两项 Bridge 测试：Host 对错误类型的 publish / update 原子拒绝，Activity、实例及数量保持不变；真实 JavaScript 的 false 发布、true 更新、顶层 patch 保留和 presentation 替换恢复默认均到达 ActivityManager。既有测试补充默认、重复 key、未知字段与 getter 零调用检查。

## 验证

`./Scripts/ci.sh` 完整 CI 为 **705 total / 701 passed / 4 skipped / 0 failures**，普通 Release build passed；两项新增测试均通过。[汇总与源码 SHA256](evidence/t35-showscompact-20261014.json)已保存。3 项鼠标测试因当前 macOS 会话锁定跳过，另 1 项为既有截图矩阵生成；没有将跳过项宣称为本轮通过。日志 `/tmp/dynamic-island-t35-compact-20261014-ci.log`，结果 `/tmp/dynamic-island-t35-compact-20261014/TestResults.xcresult`。

## 下一步与完成边界

1. 实现通用工具角色、按实例选择及 Host 几何，验证音乐 / 瞬时事件抢占和恢复。
2. 实现通用倒计时记录、声明式秒级显示和真实动作的一次性启动凭证，保持后台刷新下限。
3. 完成 JS 官方包的开始、暂停、继续、结束、预设及存储权限处理。
4. 删除生产番茄钟专用 Swift；从 `.dip` 安装并完成真实 UI / 计时、旧功能回归验收。

本子步骤只完成公开字段的数据闭环，工具选择和计时功能尚未实现，不能将 T35 标为 verified。原生番茄钟继续保留至完整替换验收，T36 仍 pending。
