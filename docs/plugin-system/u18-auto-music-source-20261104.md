# U18 — 自动识别音乐来源

日期：2026-11-04。Host 0.6.1/build23。

## 使用变化

设置 → 通用 → 音乐播放器不再提供手动 App 选择器，显示自动识别状态和已启用来源。支持 Apple Music，以及已安装、启用并分别批准媒体权限的网易云、QQ 音乐、Spotify 插件。旧的 `music.selectedProviderID` 偏好不再决定来源。

识别跟随系统当前活动媒体会话，不按前台窗口或 App 名称猜测。目标暂停但系统仍保留该会话时，可继续显示该播放器并恢复播放；没有活动会话时显示空闲。不支持的音源、插件未启用或读取未授权时不读取歌曲、不切换去控制另一个播放器。

现有 `.dip` 包及其公开摘要不变，升级 Host 后即可自动识别，无需重新安装或授予额外插件权限。旧 Host 的手动来源行为保留在对应旧构建中，本轮没有发布主程序。

## Host 实现

- `MusicSourceDetector.swift` 的固定只读 JXA 只读取当前系统媒体会话的客户端 Bundle ID 与父应用标识；只返回四个白名单播放器之一，其他应用仅返回 unsupported，不导出其标识。不读取歌曲或封面，不发控制命令，不启动 App。返回前再次核对进程存在及活动身份未改变。
- 复用 Host 的有界、可取消解释器执行器：1 秒截止、1 KiB 输出上限，不给插件新增 JS 方法或进程权限。读取来源身份不会隐式批准 `media.read` / `media.control`。
- 自动路由只接入启用、生命周期有效且已获 `media.read` 的目标插件。控制仍独立校验 `media.control`；权限变化、停用、卸载和来源变化继续关闭旧请求。
- 并发 metadata 请求共享一个正在执行的读取任务，最后一个等待者取消时终止对应工作。来源变化递增 generation，清空旧歌曲、进度拖动与封面缓存，并让迟到响应失效。
- 音源探测使用 Registry 共享的请求/完成序号；较早探测的成功或失败都不能覆盖已经完成的新探测，即使多个 Router 共享同一个 Registry。
- 控制绑定最近成功返回的歌曲来源与 generation，发命令前再次识别系统活动来源。旧页面按钮不会因为自动切源而发送给新 App。撤权后重新授权，也必须先读取新的 metadata 才能重新建立控制绑定。
- 对外进度标识使用来源与原始曲目标识的稳定摘要，发送 seek 前校验当前绑定并还原原始标识，防止不同播放器使用相同曲目 ID 时跨源拖动。

生产初始化总是启用系统检测器。内部注入构造器允许 nil detector，仅用于已有隔离 transport 测试，不向设置或插件暴露手动模式。

## 验证

160 个不同定向测试方法全部通过：

| 测试类 | 通过数 |
| --- | ---: |
| AutomaticMusicSourceTests | 21 |
| MusicSourceDetectorTests | 6 |
| PluginMusicControlServiceTests | 25 |
| AppSettingsTests | 10 |
| SettingsPagingTests | 3 |
| MusicRefreshLatencyTests | 6 |
| IslandCompactMusicRefreshTests | 3 |
| IslandViewModelTests | 51 |
| OptionalMusicPluginIntegrationTests | 7 |
| MusicActivityProviderTests | 7 |
| MusicControlServiceTests | 21 |

覆盖无音源、未知音源、权限未批准、只读授权、播放器切换、旧按钮与 seek 拒绝、撤权重授、单飞/取消、迟到响应、旧探测成功/失败乱序、设置六种状态及手动选择器消失。真实 convenience ViewModel + 自动 Router + generation 观察的集成测试保持 compact、不悬停、不手动刷新，依靠实际轮询完成模拟 QQ → Spotify 切换，并验证先清除旧曲目、最后显示新源、没有播放控制命令。

固定 JXA 编译和本机只读识别通过；实际 App 沙盒内的只读探测测试通过。本机探测确认能取得白名单身份，没有记录歌曲、账号或非白名单应用标识。路由与播放控制测试使用 fake detector / helper runner，不改变真实播放器状态；设置截图使用隔离模型，是渲染证据。

SDK 45 项 Python 测试、三个媒体包/脚本预检、节点及 TypeScript 合约通过。build23 Release 构建、版本/构建号、发布配置与 `codesign --verify --deep --strict` 通过。本轮未运行全量 CI，也未重新发布插件包。

结果目录：

- `/tmp/dynamic-island-auto-source-initial.xcresult`
- `/tmp/dynamic-island-auto-source-routing.xcresult`
- `/tmp/dynamic-island-auto-source-final.xcresult`
- `/tmp/dynamic-island-auto-source-sequencing.xcresult`

应用：`/Users/rong5/.codex/artifacts/dynamic-island-auto-source-build23/Dynamic Island.app`。

[验证摘要与六种设置状态截图](evidence/u18-auto-source-20261104/validation.json)已保存。真实多播放器之间的自动切换、暂停/续播、上下曲和拖动进度仍需人工验收；系统私有 MediaRemote 接口的兼容性需随 macOS / 客户端版本复验。
