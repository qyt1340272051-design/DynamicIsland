# Node Mock — T25 验收示例

这个展开插件包用同一个 Activity 展示 `minimal`、`compact`、`expanded` 三种声明式布局。插件 ID 为 `com.example.node-mock`，最低 Host 兼容版本为 `0.6.0`。Manifest 只声明 `activity.publish`、`activity.update`、`activity.end`、`ui.islandNode`，权限数组为空。

## 测试流程

测试 Host 将本目录复制到独立临时受控插件容器，通过正式 PluginValidator 校验包，再使用真实 PluginRuntime → PluginJSBridge → ActivityManager 执行同一份 `index.js`。测试结束后清理容器。

1. Runtime 调用 `onStart`，函数同步返回 `undefined`；其 Promise 链发布本地 `build` Activity，进度为 `0.1`，生命周期为 `progress`，成功后记录 `node.ready`。
2. `minimal` 使用百分比 Text；`compact` 使用 Icon + Text 的 HStack；`expanded` 使用标题、说明和 Progress 的 VStack。窗口尺寸与样式由 Host 决定。
3. 测试 Host 在 Runtime 工作线程执行 `void mockNodeProgress(0.5)`，等待 `node.progress:0.5`，检查同一 Activity 的三种布局及进度均已更新。
4. 执行 `void mockNodeProgress(1)`，等待 `node.progress:1`，检查完成标题、成功色与进度 `1`。完成进度不自动结束 Activity。
5. 执行 `void mockNodeEnd()`，等待 `node.ended`，确认正式 Core 已移除 Activity。

实际 Host ID 为 `plugin:com.example.node-mock:build`，source 使用可信执行会话。`mockNodeProgress` 和 `mockNodeEnd` 是示例自己的 JavaScript 函数，测试 Host 用它们推进场景；它们不是生产 Bridge API。

所有 Promise 链都捕获失败并尝试记录 `node.error:<code>`，日志失败也会被捕获。验收要等待成功日志并检查模型、Renderer 输出及结束状态；没有抛异常不能代替成功条件。`onStop` 同步返回 `undefined`，撤销与清理由 Host 完成。

## 运行自动化测试

在仓库根目录运行测试类：

```sh
xcodebuild test \
  -project DynamicIsland.xcodeproj \
  -scheme 'Dynamic Island' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/dynamic-island-t25-node-mock-derived \
  -parallel-testing-enabled NO \
  -only-testing:DynamicIslandTests/PluginIslandNodeBridgeTests
```

完整回归与普通 Release 构建使用 `./Scripts/ci.sh`；最终验证结果见 [T25 实现与验收](../../phase-5-t25-js-island-node.md)。这些命令通过 Runtime 的测试入口加载示例；生产插件安装 UI 按 T33 继续实现，当前 README 没有提供生产安装入口。

## 当前范围

示例没有网络、定时器、私有 KV、图片资源解析或交互控件。T25 验收覆盖数据转换、真实 JavaScript 请求及 Host 渲染；真实刘海设备的裁切、动画和视觉效果需要单独验收。动作回传按 T26、KV 持久化按 T27、权限 grant 按 T28、Broker 按 T29 继续实现。
