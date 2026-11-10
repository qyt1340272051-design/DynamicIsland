# U05 验证记录

- [用户提供截图](user-report.png)：展开页仅有曲名。
- 修复前结果：`/tmp/dynamic-island-u05-before.xcresult`。长曲名场景的封面及控制区域绘制缺失；测试辅助的本地无障碍后端另作稳定性修正，不将其空结果当作生产缺陷。
- [修复前原生测试窗口](before.png) / [修复后原生测试窗口](after.png)：使用同一曲名及长副标题，红色方块是测试封面；验证完整布局，不冒充用户实际歌曲的封面。
- [滚动起始帧](marquee-start.png) / [1.75 秒后帧](marquee-moving.png)：来自实际可见的原生测试窗口，文字位移且保持在固定区域。
- [结构化结果](result.json) / [测试摘要](test-summary.txt)。

完整回归执行 1201 项（3 跳过、0 失败），Release 构建通过；之后的收起态无障碍可见性微调单独复验 33 项、0 失败并重新构建 Release。对应结果分别为 `/tmp/dynamic-island-u05-full.xcresult` 与 `/tmp/dynamic-island-u05-final-visibility.xcresult`，不合并为一次全量测试。

普通 App 已运行 `build/u05/Dynamic Island.app` 的 0.6.1/build11，签名与关于页版本已核对，网易云仍为所选来源，两项媒体权限仍“已允许”。本次不操作真实播放器或改变插件授权。展开音乐内容与文字移动的画面来自原生测试窗口；普通 App 核对的是实际版本、设置状态及收起无障碍树，不将测试截图标记为普通悬停窗口截图。
