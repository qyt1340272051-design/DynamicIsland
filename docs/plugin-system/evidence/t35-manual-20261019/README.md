# T35 最终完成提示实机验收

2026-10-19，用户恢复人工验收并完成展开 / 移出。本轮使用原独立普通 Release 与相同 Pomodoro 0.2.1 包，真实 UI 选择 15 分钟并开始；未改时钟或使用私有倒计时入口。

- [preflight.json](preflight.json)记录 PID 80223、包三文件摘要、授权 / 启用状态及开始前 completed 设置；[run.json](run.json)是本轮独立 Start 时间，不能复用旧轮截止时间。
- [capture.json](capture.json)记录真实 CUA 采样边界：观察 3487 帧，在内存采集到期前后 2459 帧，完成 AX 连续 69 帧；磁盘归档 7 个选帧及全部完成 AX 时间，未导出全部原始帧；[result.json](result.json)提供自然时长、视觉与退出结论。
- [完成初段](completion-early.jpg)、[完成中段](completion-middle.jpg)、[完成末段](completion-last.jpg)均为未经修改的真实像素：左侧勾选、右侧「完成」在中央物理相机区域外。三帧可见时点约为 Start 后 901.5–904.0 秒。
- 最早完成 AX 比像素绘制更早：[ax-ahead-of-pixels.jpg](ax-ahead-of-pixels.jpg)仍是空壳，因此它只证明 AX 状态，**不作为提示可见性通过证据**。
- [完成后](after-completion.jpg)、[五秒后](after-5seconds.jpg)及[继续观察后](after-observation.jpg)确认提示正常消失、没有自动重开。
- [cleanup.json](cleanup.json)记录正常 Command-Q、PID 已消失、Staging 为空，包 / 已启用标记 / 存储批准及 completed 设置保留。

[screenshots.json](screenshots.json)保留原始 CUA call ID、时间和图像 SHA-256。图像从本次工具输出提取，没有重绘、裁切或合成。

[host-provenance.json](host-provenance.json)记录旧副本与当前源码的关系：相关渲染几何和倒计时源码相同，Host 仲裁 / Bridge 后续有扩展；本轮不是当前 HEAD 二进制的整体验收。连同此前真实启停、授权、重启和迁移证据，本轮补齐 T35 已登记的最后人工缺口。
