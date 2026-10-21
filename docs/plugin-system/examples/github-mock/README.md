# GitHub Mock — T24 验收示例

这是纯本地的构建进度示例。`manifest.json` 与 `index.js` 是可经正式 PluginValidator 校验的展开插件包内容，插件 ID 为 `com.example.github-mock`，最低 Host 兼容版本为 `0.6.0`。它只声明 `activity.publish`、`activity.update`、`activity.end`，没有权限声明，也不访问 GitHub API。

## 运行流程

测试 Host 将仓库中的示例复制到独立临时受控插件容器，经 PluginValidator 校验其中的 `github-mock` 包后，使用真实 PluginRuntime、PluginJSBridge 与 ActivityManager 执行同一份 `index.js`。测试结束后清理该容器。

1. Runtime 调用 `onStart`，函数同步返回 `undefined`，Promise 链发布本地 `build` Activity：`normal` 优先级、`progress` 生命周期、进度 `0.1`，成功后记录 `mock.ready`。
2. 测试 Host 在该 Runtime 的工作线程执行 `void mockBuildProgress(0.5)`，等待日志 `mock.progress:0.5`，并检查同一 Activity 的进度为 `0.5`。
3. 执行 `void mockBuildProgress(1)`，等待日志 `mock.progress:1`，检查进度为 `1`、标题为「GitHub Mock 构建完成」。进度达到 `1` 不会自动结束 Activity。
4. 执行 `void mockEnd()`，等待日志 `mock.ended`，检查 Activity 已由正式 Core 移除。

Host 实际 ID 为 `plugin:com.example.github-mock:build`，source 来自可信执行会话。`mockBuildProgress` 与 `mockEnd` 是这个 fixture 的 JavaScript 全局函数，供测试 Host 推进场景；它们不是新增的 Host Bridge API。

所有 Promise 链显式捕获失败，失败时尝试记录 `mock.error:<code>`；日志失败也会被捕获。测试必须检查预期日志与 Core 状态，不能把「没有抛异常」作为场景成功。`onStop` 不请求 Host 能力，会话撤销与 Activity 清理由 Host 统一完成。

## 范围

示例没有网络请求、定时器、GitHub Token、持久化存储、IslandNode Tree 或动作 handler。声明式布局按 T25、动作回传按 T26、持久化 Storage 按 T27、正式 GitHub 插件按 T36 继续实现。当前示例用于 T24 自动化验收；真实刘海设备的视觉效果需要单独验收。

完整 API 与限制见 [T24 实现文档](../../phase-5-t24-js-activity.md)。
