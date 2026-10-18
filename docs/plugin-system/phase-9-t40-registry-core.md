# T40 子步骤：Registry 目录、下载和安装校验

日期：2026-10-18。按计划先维护仓库内清单，完成可自动验证的 Host 核心链路。T40 仍为 `in progress`：发现界面与 App 接线、真实发布地址和端到端实际安装尚未完成，T38 依赖保留。

## 已实现

[Registry/registry.json](../../Registry/registry.json)是严格 V1 目录，当前为空；[维护说明](../../Registry/README.md)记录字段与发布边界。未验收的官方示例不会被伪装成已审核且可下载的条目，没有上传包或推送远端。

[PluginRegistryCatalog](../../DynamicIsland/Plugins/PluginRegistry.swift)只接受 schemaVersion / plugins 以及每项 id / name / version / download / source / minHostVersion / hash。拒绝未知和重复字段、重复 ID、错误类型、非法名称与版本；上限 100 项、256 KiB。Manifest 的身份 / 显示名规则复用现有实现。SHA-256 为 64 位小写十六进制。

V1 源限制为 GitHub 仓库根地址，下载为同一仓库指定 Release tag 的 `.dip`；目录为 raw.githubusercontent.com 下仓库 / 单段 ref / Registry/registry.json。路径、凭据、端口、fragment、编码路径与备用域名均受显式规则约束，不接受任意网络地址。

[PluginRegistryClient](../../DynamicIsland/Plugins/PluginRegistryClient.swift)一次只处理一个请求，无后台轮询。ephemeral URLSession 不带 Cookie、缓存或凭据，20 秒请求 / 60 秒资源超时。目录禁止重定向；归档最多三次重定向到 release-assets.githubusercontent.com，并重建无凭据请求。增量接收同时检查声明长度与实际字节数；目录上限 256 KiB，归档沿用 40 MiB。取消会结束当前传输并释放 busy 状态。

下载字节直接进入 Installer，没有临时下载路径。Extractor 对**同一不可变 Data**计算 SHA-256 并解析 / 解压，避免“先 hash 路径、再重新打开”产生替换窗口。之后继续原 ZIP32 防护和 Validator；Manifest 的 ID、name、version、minimumHostVersion 必须与条目精确一致。摘要相符不能绕过归档有效性或最低 Host 版本。

成功只返回现有 `PluginInstallReview`，调用者仍需展示信息与权限、明确确认。commit 后保持停用；权限和启用仍由插件管理执行。原本地 `.dip` 导入接口保留，新增的内存归档入口共用同一安装事务、指纹、取消和回滚处理。

## 验证

[证据](evidence/t40-registry-core-20261018/result.json)保留完整结果与源码摘要。

- Registry 新增 13 个测试，覆盖字段 / URL 拒绝矩阵、100 项上限、完整真实 Hello 包下载到预览与停用安装、摘要不符、四个身份字段不符、最低 Host、非法 ZIP、取消及重试。
- URLProtocol 只替换测试传输；未发真实 Registry 或 Release 请求。无 Content-Length、谎报小长度、声明超限均受限；40 MiB 归档流式超限也实测拒绝。
- 重定向通过真实 delegate 方法注入测试，验证 CDN 白名单、三跳上限、禁止目录跳转和删除原请求的 Authorization / Cookie；没有把 URLProtocol 伪造重定向当成实际 CDN 网络验收。
- 首轮定向 47 passed；补充边界后完整 CI **1052 total / 1050 passed / 2 skipped / 0 failures**，包括 Registry 13 项和原 Installer / Archive 回归。SDK Python 37 项与严格类型检查通过；普通 Release 构建和 strict / deep 签名核验通过。
- 两项 skip 为显式截图矩阵和未开启的实时 GitHub API；五项真实输入测试全部通过，因此历史剩余三项锁屏输入缺口已清除。T35 / T36 物理设备验收与新作者走查仍未完成。

## 下次继续位置

1. 在插件管理接入发现入口，展示加载、空目录、失败、版本不兼容和可下载状态；展示 source 的来源信息但不标为身份已认证。
2. 下载选择复用当前 InstallerModel 的忙碌 / shutdown / 清理状态，把返回的 review 交给现有预览。避免文件导入与 Registry 同时拥有两个悬空 review；退出或关闭下载时必须取消并等待清理。
3. 明确用户触发刷新与下载；暂不自动更新、自动启用或自动授权。未发布目录应显示可理解的未就绪 / 空状态。
4. 完成 UI 和状态竞争测试后，再按官方插件实际验收与发布门槛提供真实固定下载包、摘要及目录条目。没有真实条目时不把 T40 标为 verified。
