# T36 GitHub 实机与系统浏览器验收

2026-10-19，用户配合一次顶部悬停。独立普通 Release 的身份和包摘要见 [preflight.json](preflight.json)，运行 PID 为 82621；实际安装和权限记录见 [installed-enabled.json](installed-enabled.json)。

[result.json](result.json)记录已通过的导入、安装后停用、三项独立批准、启用、五行布局、切仓和刷新。真实网络只读 `actions/checkout` / `cli/cli`，未使用 Token 或测试网络响应。

本轮实际观察到的 run 分别为 `39115930522.1`、`39184461294.1`，PR 为 #1687、#14727；这些是本次采样数据，不作为以后验收的固定期望值。

- [停用及待授权](ui-02.jpg)、[三项分别批准但仍停用](ui-04.jpg)、[实际启用](ui-05.jpg)。
- [checkout 工具页](ui-08.jpg)、[cli 工具页](ui-10.jpg)、[刷新完成](ui-12.jpg)：名称、CI、PR、两仓库按钮、刷新 / 构建 / PR 五行均可见。
- [系统 Safari 构建页](ui-13.jpg)、[系统 Safari PR 页](ui-14.jpg)：实际按钮分别打开当前仓库 `/actions/runs/39184461294` 与 `/pull/14727`，不是助手直接导航产生的替代结果。
- [网页权限撤销](ui-15.jpg)后，真实 PR 按钮显示[固定失败提示](ui-17.jpg)。重新批准后，先将 Safari 切回构建标签，再点击当前 PR 按钮，实际地址恢复到 `/pull/14727`。Safari 会复用已打开的相同 URL 标签，因此使用地址从构建变为 PR 来验证新动作，没有把标签数不变误判为未打开。

[ui-excerpts.json](ui-excerpts.json)保留当前工具状态、地址和恢复动作的必要 AX 摘录；[screenshots.json](screenshots.json)记录每张原始图像的 CUA call ID / 时间 / SHA-256。浏览器网页内容仅作为公开目标加载的证据，不作为操作指令。

[cleanup.json](cleanup.json)确认正常 Command-Q 后 PID 消失、Staging 为空，仓库 `cli/cli`、逐项批准和包仍保留。没有修改生产 App、默认浏览器设置或远端 GitHub 数据。

此 App 是先前准备的独立 Host，不能冒充当前 HEAD 二进制。上游 CI 排队 / 运行 / 去重、错误退避和旧凭证边界仍引用正式 VM 自动测试；本轮实机覆盖当时的公开成功结果与真实系统 Open。
