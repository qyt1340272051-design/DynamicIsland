# U01 首次物理验收失败后的修正

[首次物理结果](physical-return-attempt-1.json)：用户报告选择后停顿约半秒仍自动收起，重新展开为秒表。同一轮有两条同义回复，计一轮失败；后续图片只拍到收起状态，没有拍到秒表，也没有旧现场回调日志。

[旧 ViewModel 回归日志](grace-before-fix.txt)实际运行两项新增的短暂 entry / exit 用例，2 tests / 8 assertion failures；此时原生完成顺序已修改，尚未应用 VM 保留原截止时间的修正，不将其描述为原候选全部源码的重跑。

[修正后定向日志](regression-after-fix.txt)：92 tests / 0 failures / 0 skipped，含菜单交互 14、既有 ViewModel 50、Runtime 24、Hover Region 4 项。两项完成回调测试使用生命周期 Spy 和真实 VM / Runtime，不能当作原生控件实际重建的界面验收。

[普通 Release 构建](release-build.txt)及 strict / deep 签名通过。[预检](preflight.json)绑定源文件摘要、可执行文件和此前失败副本的正常退出；复用原隔离验收容器，无新插件或额外权限。[当前结果](result.json)独立追踪修正版，不将历史七项菜单 AX / 按钮通过当作真实移回通过。

修正版已启动，低频 `ToolMenu` 日志正在记录原生关闭 / 选择、VM 宽限及 inside / hovering 布尔值。日志不含插件文字或指针坐标。已请求用户独立完成菜单底部选择、停顿及移回，当前等待结果，U01 仍为 `in progress`。完整说明见[U01 记录](../../u01-tool-menu-20261020.md)。
