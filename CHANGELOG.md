# SDK 变更说明

## 1.0.0 发布候选 — 2026-10-19

已采用候选版本，尚未公开发布。SDK `1.0.0`、App `0.6.0`、wire API `1.0.0` 与 Manifest schema `1` 是独立标识；此次没有改变 Host 协议、资源权限或现有插件业务逻辑。

### 冻结的有限接口承诺

- Native namespace 为 log、activity publish / update / end、actions.on、storage get / set、scheduler.requestRefresh、countdown get / start / pause / resume / stop / onComplete、network.fetch 和 links.open。
- 节点为 text、icon、hStack、vStack、spacer、progress、countdown、button；不承诺任意视图、字体、尺寸、CSS、窗口控制或完整 Host 能力。
- 生命周期 hook 同步返回 undefined；动作和完成回调可以返回真正的 Promise。Host 方法返回 Promise，拒绝值按 `{code,message}` 数据处理。
- `presentation` 整体替换；Activity、动作和资源绑定执行与实例。停止、权限撤销及包变更后的重新审核仍由 Host 强制执行。
- 入站 JSON 冻结且无原型；数组只承诺 length 与索引。activation 和 countdown generation 是不可由 SDK 构造、不能延长有效期的不透明标识。
- 权限必须分别声明和批准；启用不授予权限。网络只允许 Host 政策内 HTTPS GET / HEAD，链接当前限 GitHub；一次性刷新不承诺精确时钟或 JS Timer。
- Manifest Schema 为 Host V1 的离线副本；Node Schema 与 CLI 为有限作者预检。类型或离线校验通过不替代 Host 安装、运行准入、资源上限、设备和 UI 验收。

### 相比实验草案的分发修正

- 修复独立 SDK README 与模板命令中的完整仓库依赖。
- Quick Start 保留修正后的单行 Bash 入口，覆盖 macOS 交互式 zsh 的复制体验。
- 加入完整 MIT License、独立 SDK ZIP 构建、逐文件摘要清单和实际解压后的脱仓库测试。
- Hello JS / Manifest 不变；README 路径说明改变后重新生成 `.dip` 测试夹具。历史人工验收记录不改写。

后续兼容策略见 [VERSIONING](VERSIONING.md)。正式公开发布时需复核同一源码状态生成的归档、摘要和独立作者结果。
