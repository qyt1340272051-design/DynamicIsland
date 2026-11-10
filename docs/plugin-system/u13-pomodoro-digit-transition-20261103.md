# U13 — 番茄钟数字滚动（2026-11-03）

用户要求番茄钟数字切换采用内置秒表/倒计时的上下滚动效果。

- Countdown 文字叶（time/timer）采用 SwiftUI numericText(countsDown: true)，与内置计时器复用 IslandCountdownDurationAnimation（0.2秒 easeInOut）。动画绑定真实显示文字变化，由已有 Host 脉冲触发，不新增业务定时器或 VM 轮询。
- 通用 timer 字体 Text 也使用 numericText 与同一时长，使准备状态切换预设时与内置分钟调整一致。
- 显式遵守系统减少动态效果和隐藏状态；U12 的自然宽度、相机间隙和布局格式变化通知保持原机制。
- Host build18，插件包继续为0.3.0，不改业务计时、权限或 Registry。

验证和安装结果完成后追加。

## 验证与交付

- 新增2项真实挂载动画检查，覆盖紧凑倒计时、展开倒计时、准备状态预设变更，分别取正常动画和禁止动画 transaction 共6组。正常组中间帧与起止帧均不同，截图可见变化数字的上下位移；禁止动画组直接到达最终数字。终点与独立无动画静态参照一致并稳定，等长文字宽度稳定、不新增显示计时器消费者。
- 系统 Reduce Motion 环境值在当前SDK只读，测试不更改系统偏好；上述关闭动画对照采用 transaction.disablesAnimations，不冒充对系统开关的实机切换验收。
- 相关 Renderer、显示观察、番茄钟布局/实际鼠标输入、紧凑外壳与刘海遮挡复测32项零失败；连同动画2项共34项通过。此次未重跑全量套件。
- Release 配置检查、Release build 及构建/安装副本 strict/deep 签名核验通过。
- 正常退出build17并备份，安装并启动 `/Applications/Dynamic Island.app` build18。设置关于页AX确认`0.6.1 18`；番茄钟`v0.3.0 · 运行中`，计时区与既有已允许存储权限保持原状，未重新授予权限或修改插件包。
- 交付目录`~/.codex/artifacts/dynamic-island-pomodoro-build18-20261103/`包含App、原始动画帧、真实录帧GIF、日志与源文件摘要。GIF为受控原生窗口渲染录帧，不代表用户屏幕实拍。
