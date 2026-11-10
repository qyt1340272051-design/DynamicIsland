# Permissions

权限流程为：在 Manifest 声明 → 安装预览 → 用户在插件管理逐项授权 → 启用与调用。用户也可先启用再授权；此时受保护的方法必须按未授权处理。启用开关和接口 supported 不代替批准。

| 本版本用到的权限 | 能力声明 | 用途与拒绝后的建议 |
| --- | --- | --- |
| `storage.local` | `storage.local` | 保存插件数据；拒绝后使用内存状态并显示未保存。 |
| `network` | 无 network capability | 请求 Host 允许的 HTTPS 目标；拒绝后显示网络未授权，保留可离线部分。 |
| `links.open` | `links.open` | 真实按钮动作打开允许的页面；拒绝后不打开。还需要新鲜 activation。 |

Manifest Schema 还识别 notifications.publish、clipboard.read、clipboard.write、calendar.read、files.userSelected。这些不在当前作者 SDK 已验证的公开方法中，不要为了未来功能预申请。未知权限直接使整个 Manifest 校验失败；不会被忽略或默认为允许。

用户可拒绝或撤销单项权限。撤销立即约束新调用和已在途工作；插件应捕获 Promise 拒绝、停止相应重试。包代码或 Manifest 改变需要重新审核和批准，旧预览也不能用于批准新的包内容。相同 ID / version 不意味着授权可以沿用。

常见状态错误：未声明 `permissionRequired`、尚未批准 `permissionNotGranted`、用户拒绝 `permissionDenied`、被撤销或包发生变化 `permissionRevoked`。缺少 capability 是 `capabilityRequired`。处理方式见 [Debugging](debugging.md)。

需要系统级许可的资源还受 macOS 控制；本 SDK 不提供绕过系统授权的接口。Hello 的 permissions 为空，按钮计数完全不依赖资源授权。

## Host 0.6.1 媒体权限

`media.read` 允许读取所声明播放器当前歌曲的曲名、歌手、专辑、封面、时长、进度和播放状态；这些信息可能反映个人收听内容。`media.control` 允许对同一个播放器发送播放暂停、上下曲和进度跳转。两者单独批准、拒绝和撤销，不能因启用插件或安装官方插件而自动批准。

媒体插件需要额外的 `mediaProvider` 对象及 `music.provider` 声明；Host 管理媒体会话，当前 SDK 不提供 JS 媒体请求或进程执行方法。禁用、暂停、卸载或撤销授权会关闭对应会话并阻止在途结果继续交付。包更新需要重新审核，见 [Manifest](manifest.md)。
