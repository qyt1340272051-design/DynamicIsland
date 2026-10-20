# U01 首次物理验收失败后的修正

[首次物理结果](physical-return-attempt-1.json)：用户报告选择后停顿约半秒仍自动收起，重新展开为秒表。同一轮有两条同义回复，计一轮失败；后续图片只拍到收起状态，没有拍到秒表，也没有旧现场回调日志。

[旧 ViewModel 回归日志](grace-before-fix.txt)实际运行两项新增的短暂 entry / exit 用例，2 tests / 8 assertion failures；此时原生完成顺序已修改，尚未应用 VM 保留原截止时间的修正，不将其描述为原候选全部源码的重跑。

[修正后定向日志](regression-after-fix.txt)：92 tests / 0 failures / 0 skipped，含菜单交互 14、既有 ViewModel 50、Runtime 24、Hover Region 4 项。两项完成回调测试使用生命周期 Spy 和真实 VM / Runtime，不能当作原生控件实际重建的界面验收。

[普通 Release 构建](release-build.txt)及 strict / deep 签名通过。[预检](preflight.json)绑定源文件摘要、可执行文件和此前失败副本的正常退出；复用原隔离验收容器，无新插件或额外权限。[当前结果](result.json)独立追踪修正版，不将历史七项菜单 AX / 按钮通过当作真实移回通过。

该第二版启动后以低频 `ToolMenu` 日志记录原生关闭 / 选择、VM 宽限及 inside / hovering 布尔值。日志不含插件文字或指针坐标。用户已反馈第二轮“仍然意外收起”，结果为失败，不再作为等待反馈的状态。完整说明见[U01 记录](../../u01-tool-menu-20261020.md)。

## 第二轮真实返回结果

[原始事件日志](physical-return-attempt-2-trace.ndjson)与[解析归档](physical-return-attempt-2.json)保存同一轮用户报告中的两个菜单 session，不能计为两轮独立真人验收。两条链均有实际 `choose` / `popUpReturn.selected` / `end` / `grace.begin` / `selection` / `pointerExit.hold` / `grace.expired`；宽限实际分别持续 **1.097395 / 1.047012 秒**，均为 **0 次进入、0 次取消事件**。

这证明该轮原生选择和完整宽限移交已发生，不支持将失败归为原生取消或未提供宽限。日志未记录指针坐标和全部采样，不能确定缺少进入通知的进一步原因；用户本轮失败仍保留，92 项自动结果及该版 Release 构建不能替代它。

## 第三版进行中

第三版产品改为 2 秒固定、不续期宽限，原有单个 30Hz 指针 Timer 使用 `.common`；deadline 由 Controller 强制同步物理 containment 缓存与 ViewModel，再核验 token 后收尾。新增 4 项菜单回归使该组共 18 项，合并既有 78 项后的[第三版定向](../u01-menu-pointer-20261020/pointer-regression.txt)为 **96 tests / 0 failures / 0 skipped**；普通 Release 与 strict / deep 签名通过，身份见[第三版预检](../u01-menu-pointer-20261020/preflight.json)。

第二版 PID 22058 已正常退出，第三版后续已完成当前设备七项菜单的返回、清理、键盘 / 取消 / 页面切换和正常退出验收，见[第三版最终结果](../u01-menu-pointer-20261020/result.json)。本目录保留第二版 92 项、构建身份和两轮用户失败的历史范围；U01 最终为 `verified`，原 T01–T40 仍为 37 verified / 3 in progress。
