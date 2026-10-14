# Phase 6 — 权限、安全、能耗与稳定性阶段检查

日期：2026-10-14。范围 T28–T32，按 [DevelopmentPlan §15](DevelopmentPlan.md#15-每个阶段的统一检查清单) 复核。分项证据见 [T28](phase-6-t28-permission-manager.md)、[T29](phase-6-t29-network-broker.md)、[T30](phase-6-t30-file-clipboard-broker.md)、[T31](phase-6-t31-plugin-scheduler.md)、[T32](phase-6-t32-crash-watchdog-logging.md)。五项任务目前均为 `verified`，下表保留未覆盖的实机和能力边界。

T31 最新证据来自普通 Release 源码 `da52f69`：修正真实前台判定后完整 CI 为 **703 total / 702 passed / 1 skipped / 0 failures**，普通 Release build 通过；随后固定二进制完成[真实后台测量](evidence/t31-background-20261014.md)。旧的非 background 测量未用于关闭任务，拒绝证据仍保留。

## 统一检查

| 项目 | 当前证据与边界 |
| --- | --- |
| 功能 | 完整 CI 包含原 Music / Volume / Battery、Activity、Renderer 和动作回归。真实 JS 验证四态权限错误、网络 / 文件 / 剪贴板 DTO、刷新和错误插件隔离，正常插件继续工作。T32 原生诊断窗口与刷新 / 重启已验证；T30 系统选择器和用户实际剪贴板尚无手动交互验收。 |
| 架构 | Manifest 声明、Host 明确决定、Broker 每次检查及执行会话准入共同控制访问。插件只提交受限数据，经 ActivityManager / Renderer / Router；网络、用户文件和剪贴板均经 Host Broker。ActivityScheduler 与 PluginScheduler 分离；没有插件私有窗口或 SwiftUI 对象入口。 |
| 并发 | Broker lease 绑定插件、权限和 generation；撤销 / 再批准不会复活旧请求。存储最终提交及读取交付再次检查；网络 / 文件选择 / 刷新等待不阻塞同 VM 的 Core 请求。生命周期、Transport teardown、晚回调及 Watchdog 的过期禁用均有会话 / 包校验，禁止旧执行影响替换插件。 |
| 性能 | 正式 App 同进程、20 项全停用 / 全运行，各约 15 分钟：平均单核心 CPU **1.5598% → 1.9437%**，增加 0.3839 个百分点；峰值 footprint **48.80 → 149.19 MiB**。内存、磁盘和 wakeups 原始计数已保存。不能据此证明长期内存稳定或动画帧率；T02 / T08 等原有性能与真实岛体缺口保留。 |
| 能耗 | Scheduler 共用一个最近截止任务，每插件至多一个待办，强制 active / background / lowPower 下限并向后合并；无每 VM Timer、100ms 轮询或补发错过 tick。真实后台 20 项各有 14 次 INFO，共 280 次，无 WARNING / ERROR，最大间隔 66 秒。归属 CPU 功率 **1.6954 → 3.0869 mW**，增加 1.3915 mW、相对约 82.1%；绝对增量支持本工作负载验收，不能称为没有额外耗电。 |
| 安全 | JS / Host 双侧有界解析，未知权限拒绝，启用不等于授权；文件接口不接受任意路径，剪贴板读写分权，HTTPS 有超时 / 大小 / 并发及 Host allowlist。DNS preflight 未绑定 URLSession 实际连接，不能声称完整 DNS rebinding 隔离。通知 / 日历 Broker 尚未支持；高危权限没有普通批准入口。Watchdog 处理可捕获异常，不提供无限循环 VM 强制抢占、硬 CPU 上限、进程级 OOM 或 VM 崩溃隔离。 |
| 隐私 | T32 丢弃任意 JS 日志正文，不读取异常 message / stack / toString；展示和 OSLog 只保留 Host 固定分类 / 错误。Token、URL、路径、文件和剪贴板正文不进入诊断。日志按插件 / 全局配额限制且仅在进程内；普通 KV 明文，不是 secret storage。 |
| 兼容 | 实机证据来自一台 arm64 MacBook Air、macOS 26.6.2（25G83）。生产前台策略同时检查 NSApp 状态和 Workspace 前台进程，旧 observer generation 已测试。睡眠 / 低电量取消和恢复有生命周期 fixture；本次 AC、lowPower=0 且无 Sleep / Wake 的测量不验收电池、低功耗或睡眠能耗，也不替代多屏、无刘海及外接屏热拔插实测。 |
| 测试 | T28 权限 17、T29 网络 12、T30 资源 17、T31 调度 18，以及 T32 新增 45 项 Watchdog / diagnostics / persistence / UI / 真 JS 集成测试分别见分项记录；最新完整 CI 702 passed，唯一 skip 为既有截图矩阵生成条件项。普通 Release 的 Sandbox / hardened runtime / allow-jit 与严格签名通过；测试 Host 的注入例外不用于生产二进制。 |
| 回滚 | 停用 / shutdown 同步关闭执行、动作和 Broker / 刷新交付资格，结束所属 Activity；可保留包和 KV 后再启用，不自动批准权限。Watchdog 状态保存失败仍保留本进程隔离，不能因磁盘错误重新运行。卸载保留 KV、明确清空才删除数据；授权持久化与卸载原子清理由后续 [T33](phase-7-t33-extensions-settings.md) 补齐，保存失败不宣称跨重启撤销已落盘。 |

## 验收范围

- T31 为单机、一次顺序对照、20 个同类 scheduler-only 插件；每组约 15 分钟，无重复测量或置信区间。计划未设数值门限，接受结论限于已记录的空闲工作负载，不推广到任意网络、存储、UI 或重计算插件，也不把内核归属 CPU 能耗当作整机电耗。
- T29 使用 URLProtocol 的 GitHub 格式响应和真实 JS，未验收真实公网 GitHub / 系统代理；T30 使用 Host 选择器 fixture 和私有命名 NSPasteboard。其实现与集成测试通过，不等于真实系统选择器、用户剪贴板已手动验收。
- 分项旧记录中“尚无批准 UI / 仅进程内决定”的描述是对应任务完成时状态；当前批准、拒绝、撤销及持久化集成以 [T33](phase-7-t33-extensions-settings.md) 为准。该集成仍不会让未知或尚未实现 Broker 的权限可用。
- 本页完成 Phase 6 的统一证据复核；不关闭 T02 / T08 或其他先前仍为 `in progress` 的设备、视觉、性能任务，不构成 0.6.0 的发布、tag 或 DMG 验收。
