# Dynamic Island Beta 验收手册

目标是用真实 Mac 硬件找出模拟屏幕无法替代的定位、权限和稳定性问题。机器可读的任务状态保存在 [`beta-device-matrix.json`](beta-device-matrix.json)，提交前由 `Scripts/validate-beta-matrix.rb` 校验覆盖范围。当前九项真机场景均为 `pending`，不得把单元测试、模拟快照或本地 DMG 构建当作验收通过。

## 安装原则

- 外部测试者只安装通过 Developer ID 签名、Apple 公证并 staple 的 Beta DMG。
- `Scripts/release.sh --local` 生成的 ad hoc 包只用于本机开发验证，不得对外分发，也不能代替 Gatekeeper 验收。
- 正式公测前，至少在一台没有 Xcode 和开发证书的干净 Mac 上验证首次安装、启动、权限请求和卸载。

## 测试流程

1. 记录本次 Beta 版本和对应的矩阵编号 `DI-B01` 至 `DI-B09`。
2. 启动 App，确认无普通主窗口，菜单栏图标可显示、隐藏和退出 Dynamic Island，展开岛内的电源图标也可退出。
3. 验证紧凑岛贴住正确屏幕顶边，悬停可展开，移出后可回到紧凑态，且命中区域不遮挡顶部应用。
4. 验证音量增减、滑杆、静音与系统输出实时同步。
5. 启动 Apple Music，验证首次自动化权限、封面、曲名、歌手、进度和上一曲/播放/下一曲；播放一段时间后再按上一曲，确认确实切到前一首。悬停进度条并拖动，检查白色圆点和实际播放位置。
6. 拖入测试文件，验证托盘锁定、单项移除、清空和 AirDrop 系统分享面板。不要在 Issue 中上传私人文件。
7. 验证秒表、各番茄时段、倒计时长按调整、紧凑态数据与结束确认流程；三种计时模式来回切换，确认岛体高度变化时数字不被裁切。
8. 按当前矩阵场景切换缩放、主屏、Space、全屏、菜单栏自动隐藏、外接屏或合盖状态。
9. 从菜单栏选择“复制调试信息”，再选择“提交 Beta 反馈...”，将报告粘贴到 Issue，并附上能看清完整屏幕顶边的截图或录屏。

调试报告包含 App 版本、macOS、Mac 型号代码、CPU 架构、屏幕几何、缩放、面板 frame 和当前功能状态。它不包含用户名、序列号、文件名、曲名、歌手或封面。提交前仍应快速检查剪贴板和附件。

## 设备矩阵

| 编号 | 核心场景 | 初始状态 |
| --- | --- | --- |
| `DI-B01` | 刘海 MacBook，单内建屏，默认缩放 | Pending |
| `DI-B02` | 刘海 MacBook，非默认缩放，菜单栏自动隐藏 | Pending |
| `DI-B03` | 刘海 MacBook 加外接屏，内建屏为主屏 | Pending |
| `DI-B04` | 刘海 MacBook 加外接屏，外接屏为主屏 | Pending |
| `DI-B05` | 刘海 MacBook 合盖，仅外接 4K/5K 屏 | Pending |
| `DI-B06` | 无刘海 Apple silicon Mac，单内建屏 | Pending |
| `DI-B07` | Apple silicon 桌面 Mac，单外接屏 | Pending |
| `DI-B08` | 无刘海 Mac，双屏混合缩放与负坐标排列 | Pending |
| `DI-B09` | Intel Mac，无刘海，受支持 macOS | Pending |

`pending` 表示尚未验证，`local-pass` 只表示开发机 ad hoc 构建通过，`passed` 表示正式签名 Beta 在真机通过。任何非 `pending` 状态都必须有证据；每条证据至少包含版本、日期和 Issue 链接或可重复的本地验证说明。

## 问题分级

| 级别 | 定义 | Beta 处理 |
| --- | --- | --- |
| `S0` | 数据丢失、系统破坏、无法安全启动或退出 | 立即停止分发 |
| `S1` | 崩溃、面板不可见或主要功能完全不可用 | 修复后才能发布下一版 |
| `S2` | 明显异常或间歇失效，但有可接受的临时规避方法 | 分配模块并排入近期修复 |
| `S3` | 轻微视觉、文案或文档问题 | 可随后续迭代处理 |

新 Issue 首先标记 `needs-triage`，填写实际测试版本；如有对应的 `v0.5.0` 里程碑，再加入该里程碑。完成去重与复现后，添加一个 `severity:S0` 至 `severity:S3` 和相应 `area:*` 标签。修复后必须在原矩阵场景复测，将 Issue 和证据写回 JSON 再关闭。

## Beta 出口条件

- `DI-B01` 至 `DI-B09` 全部有真机 `passed` 证据。
- 没有未解决的 `S0` 或 `S1` Issue，已接受的 `S2` 有记录清晰的规避方法。
- 签名、公证、staple、DMG 校验和干净 Mac Gatekeeper 安装全部通过。
- `Scripts/ci.sh` 和 `Scripts/run-stability-matrix.sh` 通过，与本次修复相关的矩阵场景已回归。
