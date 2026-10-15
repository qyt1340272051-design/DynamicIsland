# T35 子步骤 2A / 2B — Host 倒计时与公开 API

日期：2026-10-15。属于 T35 的通用能力，适用于任何声明 `countdown` capability 的插件。声明式时间节点、官方 Pomodoro 包及生产专用 Swift 删除仍待实施，T35 保持 `in progress`。

## 公开合约

Manifest 的 `capabilities` 可以包含 `countdown`；这是受限的 Host 能力，不是权限，不获得 Storage、网络或系统通知授权。开始和继续还需要 `actions.handle`，以及真实 Action 事件的 `activation`。公共命名空间和方法均冻结，`apiVersion` 沿用 `1.0.0`，`supported === true`。

| 方法 | 输入 | Promise 成功值 |
| --- | --- | --- |
| `island.countdown.get(id)` | 本地 ID | snapshot 或 null |
| `start({id, durationMs, activation})` | 整数 1000…86400000 ms、一次性凭证 | running snapshot |
| `pause({id, generation})` | 当前 running generation | 新 paused snapshot |
| `resume({id, generation, activation})` | 当前 paused generation、一次性凭证 | 新 running snapshot |
| `stop({id, generation})` | 当前 generation | null |
| `onComplete(handler)` | 一个函数，替换当前监听 | null |
| `offComplete()` | 无参数 | null |

snapshot 精确包含 `id`、`generation`、`state`、`durationMs`、`remainingMs`；state 为 running / paused / completed，generation 为 Host 生成的小写 UUID。对象冻结且无原型，completed 的 remainingMs 为 0。本地 ID 允许 ASCII 字母、数字、`-._`，长度 1…80。所有对象拒绝额外字段、错误类型和类型转换；SDK 安全快照不调用 getter、toJSON 或不可信 thenable，Host 独立验证。

每插件仅一个业务记录；同 ID 的合法 start 可原子重开，不同 ID 需先 stop。全局 owner / 记录各最多 128。start、pause、resume 生成新 generation，旧命令及完成事件不能修改替代记录。停止、禁用、卸载或直接 Runtime teardown 会清除相应记录；shutdown 清空全部。记录仅保存在当前 Host 进程，不持久化跨 App 重启的单调时钟 instant。

```javascript
// 函数本身同步返回；异步工作在公开 Promise 链中处理。
function onStart() {
  void island.actions.on('start', event =>
    island.countdown.start({id: 'focus', durationMs: 25 * 60 * 1000,
                            activation: event.activation})
  ).catch(handleError);
  void island.countdown.onComplete(snapshot => {
    // 通过公开 Activity API 发布完成提示；此事件没有 activation。
    showCompletion(snapshot);
  }).catch(handleError);
}
```

## 动作凭证

只有已准入的真实按钮、toggle 或 sliderCommit 动作会附带凭证；连续 slider 中间值没有凭证。每执行会话只保留最新一张，ContinuousClock 有效期 5 秒，绑定执行、动作注册、Activity source / ID / instance token / action ID。消费时再次检查当前动作准入。匹配的消费尝试先烧毁凭证，再检查过期和状态；伪造 token 不能销毁合法凭证。

onStart、后台刷新、完成通知、旧 VM、旧 Activity 或旧注册不能自行 start / resume。完成回调不能重用开始时的凭证循环创建一秒倒计时。动作 authorizer 可同步重入：凭证消费返回后，Host 在资源准入锁内再次校验执行并完成无回调的 start / resume，撤销失败不留下 running 记录。普通 PluginScheduler 的 30 / 60 秒下限与合并规则保持原值。

## Host 时间、暂停与完成投递

Broker 使用 [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) 的相对 Duration 持有截止时间，与墙钟无关，睡眠时间计入运行倒计时。pause 保留精确 Duration；只在 JSON 展示值向上取整毫秒，resume 不累计取整误差。所有活跃记录共用一个最近截止 alarm，没有每 VM 的秒级 Timer；暂停、完成、空闲或所有 owner 被 suspend 时不留 alarm。

睡眠 / 低电池关闭执行准入并销毁旧 VM，业务记录保留。条件全部解除后，在 factory 同步回调通过最终准入检查后才激活 owner；新执行注册完成回调时交付已过期记录，不复活旧 VM / lease。禁用 / 重启则旋转 owner，旧上下文不能操作新记录。

完成事件通过现有 64 项 FIFO 与动作共享容量，载荷固定且不包含 activation；交付前后检查执行、资源、owner、注册代次及 countdown generation，无需工具当前可见。Host offer 与 VM receipt 分离：真正调用当前 JS handler 后才确认接收；排队后 suspend、换注册、队列拒绝或 JS 容量不足不会消费完成通知。offer 在回调前预留以防同步 get 重入；拒绝仅释放 offer，后续 get / pump / 新注册可重试，避免立即递归。

确认接收后不再重放该 generation。若 VM 已调用 handler，但 Host 确认前执行被撤销，新执行仍可再次收到同 generation；插件可用 generation 去重。handler 自身抛出或 Promise 拒绝属于已接收，使用既有固定错误诊断与 watchdog，不读取异常的 message / stack / toString。

## 验证和后续边界

新增 Broker、activation、typed delivery、真实 JavaScript / Lifecycle 集成、SDK 安全边界测试。证据汇总见 [CI 与源码 SHA256](evidence/t35-countdown-20261015.json)。覆盖精确暂停、截止边界、owner / generation / 注册替换、未接收补发、资源撤销原子性、factory 重入睡眠、双 owner 隔离及不可信回调。

确定性时钟和真实 VM 测试验证 Host/API；本子步骤没有实机睡眠、低功耗或能耗结论。下一步是通用声明式时间节点及仅可见节点的共享显示 tick，然后官方 JS 包、存储拒绝 / 撤销处理、完整原生迁移和实际 `.dip` / UI 计时验收。T36 仍 pending。
