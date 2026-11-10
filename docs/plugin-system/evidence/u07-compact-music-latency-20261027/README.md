# U07 收起态音乐延迟证据

目标：App 0.6.1 / build13，2026-10-27。用户报告展开较快，收起偶有十多秒更新延迟，需悬停展开才能看到新信息。

## 原始探测

- [helper-baseline.json](helper-baseline.json)：同字节 helper 的六次只读查询，76–103 ms，中位数 85 ms；只记录耗时、是否有数据、大小和身份摘要。
- [live-baseline-cadence.json](live-baseline-cadence.json)：build12 后台 12 秒内 7 个 helper 启动点，相邻约 1.62–1.74 秒；这次没有捕获原始长延迟。
- 0.75 秒节奏的 8 次只读小样本子进程 CPU 约 12.86% 单核，因此保留 1.5 秒生产目标节奏。
- 活动监视器当前显示 App Nap“否”；不把当前正常样本当作已复现唯一原因。

## 回归结果

- `/tmp/dynamic-island-u07-red2.xcresult`：旧成功覆盖新数据、旧失败覆盖新成功、完整查询后额外等待三项均失败。
- `/tmp/dynamic-island-u07-compact-red.xcresult`：原生整体 compact 两项回归通过；不能据此认定普通资源 ID 必然使整个界面卡住。
- `/tmp/dynamic-island-u07-compact-auto.xcresult`：三项通过，包括非激活 App、非激活面板、1.5 秒自动轮询、不手动刷新也不悬停；一次来源变更到模型应用为 1199 ms。
- `/tmp/dynamic-island-u07-art-resource-red.xcresult`：纯 ActivityManager 订阅者未收到封面更新通知，蓝色像素为 0、旧红色 12460 像素。资源版本修正后对应回归通过。
- `/tmp/dynamic-island-u07-focused-final2.xcresult`：最终 97 项定向 / 0 失败，含紧凑自动刷新、资源版本、迟到封面、过期回复、取消跳转恢复、生命周期、子进程超时及悬停回归。中间失败记录保留；没有用修改旧跳转断言消除失败。

最终全量检查、普通 Release 启动和收起态实测写入 `result.json`。完整边界见 [U07 记录](../../u07-compact-music-latency-20261027.md)。

本轮不发送播放控制命令，不改媒体授权或来源，不修改网易云 helper / 清单，旧辅助脚本摘要保持 `37c306a675aa34419a34bc03a412a934953f2b5243c96ee3f9855d5b537a9d32`。
