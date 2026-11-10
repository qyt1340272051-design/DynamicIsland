# 透明毛玻璃外观

2026-11-02：在「设置 → 外观」选择「透明毛玻璃」，立即生效并保存到本机。原有默认外观、封面流光继续可选。

[设置页截图](transparent-settings.png)记录三种选项及选择恢复后的界面。

背景使用 `NSVisualEffectView` 的深色 HUD 材质、`behindWindow` 混合模式和 `active` 状态，在非激活面板中持续模糊桌面及后方窗口。该模式的采样范围见 [Apple 文档](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow)。它不读取音乐封面，也不需要屏幕录制权限。背景没有不透明黑色底板；开启系统「减少透明度」时改为实色深色背景。

原生材质自身使用透明度遮罩，匹配紧凑态直角顶部、底部圆角和展开态圆角；遮罩在尺寸和动画变化时更新，进度等无关刷新不会重新创建遮罩。装饰视图不接收鼠标命中，保持操作和拖放事件路径。

## 验证

本轮 23 项定向 XCTest 全部通过，无失败、无跳过，包括：

- 实际 IslandView 中存在且复用单个原生背景，材质、窗口背后采样与非激活状态正确。
- 紧凑、展开及音乐、托盘、计时、工具页面切换后的遮罩范围和上下圆角正确；岛体下方保留透明区域。
- 毛玻璃不接受命中；切换回其他外观时移除背景模糊视图。
- 减少透明度时使用不透明深色，关闭后恢复毛玻璃。
- 原生设置窗口真实点击、重建后的第三外观选择保存，以及前一轮封面流光和几何回归。

结果包：`/tmp/dynamic-island-frosted-glass-tests-v2.xcresult`。

Debug 与 Release 构建均通过；Release 日志：`/tmp/dynamic-island-frosted-glass-release.log`。

原生背景采样由系统合成，离屏控件位图无法完整记录桌面背后的模糊效果；本轮未将离屏截图当作真实桌面效果证明。不同壁纸、后方窗口、物理刘海边缘及透明强度的主观观感仍待人工体验。本轮未重跑完整 CI。
