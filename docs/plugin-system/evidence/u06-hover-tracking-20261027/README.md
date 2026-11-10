# U06 悬停修正证据

范围：App 0.6.1 / build12，2026-10-27。本轮仅修正 Host 悬停、隐藏动画与测试测量，不更改网易云插件文件、权限、来源或播放。

- 旧代码复现：`/tmp/dynamic-island-u06-red3.xcresult`，2 项回归中 tracking 内展开失败（两条断言），离开取消通过。
- 首批相关回归：`/tmp/dynamic-island-u06-focused.xcresult`，84 项 / 0 失败。
- 首轮完整检查：`/tmp/dynamic-island-u06-full.xcresult`，1208 项 / 1203 通过 / 3 跳过 / 2 个布局测试失败；6 项新悬停测试全部通过。失败保留于记录。
- 几何补充后定向：`/tmp/dynamic-island-u06-native-review.xcresult` 与 `/tmp/dynamic-island-u06-exact-layout.xcresult` 保留布局测量问题的再次复现；新悬停测试通过。
- 测量修正：`/tmp/dynamic-island-u06-pixel-grid.xcresult`，两个既有原生布局检查均通过；不通过降低音乐像素数量断言精度解决。

最终完整检查和运行状态见本目录 `result.json`。详细机制与验证边界见[U06 记录](../../u06-hover-tracking-20261027.md)。

当前实机音乐 compact 在展开范围以内；宽两翼回归属于其他几何配置的确定性问题，不将它当作当前实机偶发故障的唯一原因。自动化输入通过注入位置驱动真实面板，不替代物理鼠标下的长期复发观察。

## 实体鼠标确认

2026-10-27，用户对 build12 的实体鼠标移入停留约 1 秒、移出并重新移入数次的复验问题明确回复：“现在可以正常展开”。当前设备的实际收展确认通过；此结果与注入位置的自动回归分别记录。
