# Phase 6 — T28 PermissionManager

日期：2026-10-10。依赖 T23 已验收。集中管理 V1 权限声明、Host 决定和每次 Broker 调用的授权；Manifest 声明、发现、启用和 Runtime 启动都不会自动批准。

## Host 合约

[`PermissionManager`](../../DynamicIsland/Plugins/PluginPermissionManager.swift) 位于 MainActor，登记可信 ValidatedPluginPackage，提供四态 `requested / granted / denied / revoked`。V1 权限继续使用 Manifest 闭集：network、storage.local、notifications.publish、clipboard.read、clipboard.write、calendar.read、files.userSelected；未知权限包括未来高危名字默认拒绝。

```swift
let review = permissions.request(package: package)
// 只有 Host 明确批准流程可以调用；没有对应 JS API。
try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
let lease = try permissions.require(permission: .localStorage, package: package)
try permissions.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
```

review 暴露可信名称、ID、版本、声明和不透明 scope，不能由外部自行构造。重复登记同一包保留决定；版本、声明、metadata 或入口 bytes 变化会先撤销旧 gate，再创建新的 requested scope，旧 review 不能批准新代码。声明排序变化不产生新 scope。Broker 热路径比较 immutable manifest / entry bytes，不重复 SHA256；注册时记录入口 fingerprint。

每个 Broker 调用取得独立 Sendable lease，绑定插件 ID、权限种类和 gate generation。Storage 在进入 I/O 前和最终提交 / 读结果返回时验证绑定，不能使用 A.network 授权 A.storage，也不能使用 A.storage 授权 B.storage。每次 Host 决定刷新 generation，旧 lease 永久失效，包括撤销后再次批准。新调用按当前状态返回固定 `permissionNotGranted / permissionDenied / permissionRevoked`；缺声明 `permissionRequired`，旧包 / review `stalePermissionReview`。

生产 IslandActivityRuntime 将同一 Manager 注入 Lifecycle 和 Bridge。Lifecycle 加载先登记，shutdown 同步 revokeAll；禁用 / 暂停 / 恢复不自动授予权限。重载同包保留当前 Host 会话决定；unregister 可由明确的遗忘动作撤销登记。后续安装管理需区分成功卸载与普通重载，再决定是否调用 unregister。

## Broker 强制执行

当前敏感 API 是 storage：Bridge 每次调用先检查声明、capability、执行会话与 granted lease，再进入 Storage actor。get 在数据交付前再次检查；set / remove / clear 在最终原子 rename 或内存赋值时检查。锁固定顺序为 lifecycle admission → permission lease；撤销不反向持有另一把锁。

权限撤销先发生则准备中的写入不能提交，读结果不能交付；提交先完成则已提交 bytes 保留，之后调用失败。错误透传为权限错误，不变成 storageWriteFailed。撤销不停止 VM，所以插件下一次调用能够收到明确错误。旧会话仍由独立生命周期凭证拒绝。

本阶段批准仅有效于当前 Host 进程；App 重启全部 requested。T28 原计划没有授权持久化任务，批准 UI 与持久化策略留给 T33 集成。生产尚无用户批准入口，因此声明 storage 的插件默认收到未批准错误。测试只使用正式 Host API 显式授权，无 DEBUG 默认 grant。通知权限不等同于 Activity 发布 capability；其余实际 Broker 按 T29 / T30 接续。

## 验证

[`PluginPermissionManagerTests`](../../DynamicIslandTests/PluginPermissionManagerTests.swift) 17 项：四态、未知 / 未声明、跨插件、声明排序、metadata / 同长度入口变更、旧 review / 跨 Manager review、重启失去批准、重复 grant generation、revokeAll / unregister、两个真实 VM、四种 storage 方法每次检查、I/O 准备期间撤销 / 再批准仍不提交、get 不交付私有数据及错误权限 / namespace 绑定在进入 I/O 前的拒绝。

测试继续使用 T27 的持久化 / 生命周期 / 固定错误验证，并将既有成功 fixture 改为明确批准实际 package。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 完整 CI / 普通 Release build | 505 total、503 passed、2 skipped、0 failures；Release build passed。 | `/tmp/dynamic-island-t28-final-ci-v2/TestResults.xcresult`、对应 `.log`。 |
| Release 定向 | Permission 17、Storage 17、Bridge 23、Node 20、Runtime 29、生产 factory 1；107 passed、0 skipped、0 failures。 | `/tmp/dynamic-island-t28-release-tests/TestResults.xcresult`、对应 `.log`。 |
| 普通 Release 签名 | strict / deep 核验通过；Sandbox / allow-jit 为 true，无 get-task-allow / disable-library-validation。 | `/tmp/dynamic-island-t28-derived/Build/Products/Release/Dynamic Island.app`、`/tmp/dynamic-island-t28-release-entitlements.plist`。 |

环境同 T27：arm64 MacBook Air、macOS 26.6.2（25G83）、SDK 26.5。CI 两项 skip 为原截图生成及当前锁屏不能接收鼠标的实际控件测试；未增加新的 skip。Release 测试 Host 的注入 entitlement / library-validation 例外只用于临时测试目录，普通生产 App 无该例外。T28 按计划完成标准标记 verified：撤销后 VM 仍运行，下一次调用立即得到明确权限错误；准备中的旧授权不能因再次批准复活。
