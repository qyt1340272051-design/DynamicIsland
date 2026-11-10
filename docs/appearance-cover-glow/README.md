# 封面光晕外观

2026-11-02：在「设置 → 外观」新增「封面光晕」。选择后立即生效并保存到本机；首次使用仍为「默认外观」。

音乐封面的实际显示区域通过 SwiftUI anchor preference 传递给背景，以封面中心为光源。复用 Music Provider 已解码且有大小限制的封面，用 20 × 20 的 sRGB 样本提取四个区域的整体颜色，叠加柔和径向渐变：近处有色，向四周衰减，远处完全回到不透明纯黑。背景不铺开封面细节、不采样桌面，不新增媒体轮询、权限或持续动画。

展开音乐页和播放中的紧凑态均支持；源位置随实际封面、布局和屏幕倍率变化。切歌或仅封面变化时更新色彩；展开与收起时在两种封面位置交叉淡化，减少动态效果时关闭相应动画。无封面、坏封面、其他活动、拖盘、计时与工具页回到纯黑。装饰背景不接收鼠标或文件拖放，不修改岛体尺寸、圆角、控件或悬停区域。

## 验证

- 最终定向 XCTest：50 passed / 0 skipped / 0 failures。包括 `IslandCoverGlowTests`、`IslandCoverGlassTests`、`IslandFrostedGlassTests`、`AppSettingsTests`、`IslandVisualStyleTests`、`IslandRendererTests`、`IslandQuitCancellationTests`。
- 覆盖四向颜色衰减、远端纯黑、圆角外透明、同 track 仅封面更新、展开与紧凑背景、拖拽、缺失／无效封面、其他页面回退、白色封面可读性、黑色封面、默认外观恢复和设置真实点击／重建后保存。
- Debug 与最终 Release 构建通过。Release 日志：`/tmp/dynamic-island-cover-glow-final-release.log`。测试结果包：`/tmp/dynamic-island-cover-glow-final-tests.xcresult`；日志：`/tmp/dynamic-island-cover-glow-final-tests.log`。
- 首轮证据导出被 App Sandbox 拒绝写入普通 `/tmp`；改用测试 Host 的容器临时目录后完成上述最终测试，未变更 entitlement。

以下图片使用合成封面与受控曲目信息，来自真实 SwiftUI 原生测试窗口。已人工查看展开、紧凑、明暗封面、四向光晕及设置页图片；这不替代真实音乐、物理刘海与连续交互动画的设备验收。本轮未执行完整 CI，未重启当前用户正在运行的应用。

- [展开音乐页](expanded.png)
- [紧凑态](compact.png)
- [明亮封面](light-cover.png)
- [黑色封面](dark-cover.png)
- [四向光晕](radial.png)
- [拖拽回退](dragging.png)
- [设置页](settings.png)
