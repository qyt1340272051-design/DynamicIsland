# Phase 5 — JavaScriptCore Runtime 阶段检查

日期：2026-10-10。范围 T22–T27。已建立独立 VM → Promise Bridge → Activity / IslandNode → SwiftUI 动作回传 → 持久化 KV 的最小闭环。分项证据见 [T22](phase-5-t22-javascript-runtime.md)、[T23](phase-5-t23-js-bridge.md)、[T24](phase-5-t24-js-activity.md)、[T25](phase-5-t25-js-island-node.md)、[T26](phase-5-t26-js-action-bridge.md)、[T27](phase-5-t27-plugin-storage.md)。

## 统一检查

| 项目 | 当前证据与边界 |
| --- | --- |
| 功能 | 真 JS 测试覆盖注册、发布、部分更新、节点三态、四种动作和两个插件相同 key 的持久化恢复。原 Music / Volume / Battery 等测试包含于完整 CI。真实控件鼠标闭环已在 T26 解锁会话成功；当前锁屏自动跳过该单项。 |
| 架构 | JS 仅有受控 island；数据进入 Host 校验后由 ActivityManager / Renderer / Router 处理。插件不能取得 NSWindow、SwiftUI View、文件路径或自行决定壳尺寸与优先级。生产 factory 和存储注入已验证。 |
| 并发 | VM / Context / JSValue 归各自工作线程；Bridge / Activity 在 MainActor，KV I/O 在独立 actor。Transport FIFO await，动作表与工作队列有界；停止撤销执行、注册、请求和最终 KV 提交资格。regrant 等权限行为由 T28 扩展。 |
| 性能 | JSON、树复杂度、Activity 数量 / 更新频率、64 请求 / 动作 / callback、128 注册 / key、64 KiB KV 均有边界测试。当前未记录正式 App 的空闲 CPU / 内存、动画帧率与同设备性能基线比较，继续保留 T02 / T08 等证据缺口。 |
| 能耗 | T22–T27 没有新增周期 Timer / polling；请求、回调和磁盘写入由事件触发。睡眠 / 低电量沿用环境关闭执行。实际新增插件能耗及后台调度按 T31 验收。 |
| 安全 | 参数在 JS wrapper / Host 双重验证；声明与 capability、执行 token、渲染实例、注册 generation 和 KV admission 由 Host 强制检查。JavaScriptCore 不承诺无限循环、进程级 OOM 或 VM 崩溃隔离；授权及 Broker / Watchdog 按 T28–T32。 |
| 隐私 | 异常和磁盘错误使用固定消息，不把原生异常、路径、文件 bytes 交给 JS。插件显式 log 的内容采用 OSLog private；内存日志仍含插件主动提交内容。普通 KV 明文，不提供 secret storage。未来诊断导出需继续审查。 |
| 兼容 | Host 原有几何路径未新增插件窗口能力。生命周期模拟覆盖睡眠、低电量、禁用和重启；新增 JS 插件真实多屏 / 睡眠 / 热拔插实测仍待设备验收，不能用模拟替代。 |
| 测试 | T27 最终 CI 488 total、486 passed、2 skipped、0 failures，普通 Release build / 签名通过。Release 定向覆盖 Runtime 和四类 Bridge、Storage，详见 T27。新增 skip 仅因锁屏不能接收真实鼠标事件。 |
| 回滚 | 禁用 / 删除 runtime factory 可停止执行，包、启用状态和 Storage 目录分别管理。卸载保留 KV，显式 clear 才清空；原子写前失败保留旧 bytes。V1 schema 错误拒绝覆盖，当前未承诺多进程并发合并或断电目录持久性。 |

Phase 5 分项标准已验收；上述实际设备 / 性能边界单独追踪，不关闭先前仍为 in progress 的任务。T28 起加入 requested / granted / denied / revoked 用户授权状态，Manifest 声明不等于用户同意。官方插件、安装与管理 UI、SDK、兼容生态按后续计划推进。未发布 0.6.0、tag 或 DMG。
