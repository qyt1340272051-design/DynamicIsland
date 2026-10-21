# DynamicIsland SDK 1.0.0

首个稳定的有限 Native SDK，提供类型、Manifest / Node Schema、Hello World 模板、13 个主题的开发手册，以及 Python 离线校验和 `.dip` 打包工具。采用 MIT 许可。

## 兼容与范围

| 标识 | 版本 |
| --- | --- |
| SDK | 1.0.0 |
| 最低 Host | 0.6.0，须包含插件系统 |
| wire API | 1.0.0 |
| Manifest schema | 1 |

SDK 版本独立于主程序。现有公开 App v0.5.0 不包含插件 Runtime；本 SDK 面向 0.6.0 开发版与后续兼容 Host，主程序安装包另行发布。

接口覆盖两款官方插件使用的 log、Activity、actions、Storage、一次性刷新、countdown、受限网络和链接。UI 提供八类节点，布局与权限由 Host 裁决。类型或离线检查通过仍须经过 Host 安装、运行准入和逐项授权。

## 下载与开始

下载同页三个构件：

- `dynamic-island-sdk-1.0.0.zip`
- `dynamic-island-sdk-1.0.0.zip.sha256`
- `dynamic-island-sdk-1.0.0.manifest.json`

将三个构件放在同一下载目录，从该目录执行：

```sh
shasum -a 256 -c dynamic-island-sdk-1.0.0.zip.sha256
unzip dynamic-island-sdk-1.0.0.zip
cd DynamicIslandSDK
bash docs/quick-start.sh
```

命令先校验、解压，再进入 SDK 根目录启动 Quick Start。离线工具只需 Python 3.9+；运行插件由兼容 Host 负责。脚本会打印实际 `Plugin package:` 路径；将生成的 `.dip` 导入兼容 Host，检查预览、安装后单独启用，再选择 Hello 工具并点击“加一”。

SDK ZIP 为 **85,192 bytes**，SHA-256：

`b64d87e400a90f730bd098cce23dc7b743cf78dcbfcb4f878f7cfeb16a494ac9`

清单逐项记录 53 个源文件的大小与摘要。SDK 标签的源码根目录即独立 SDK；GitHub 自动生成的 Source code 归档具有自己的目录和字节，使用上述校验文件时请选择命名的 SDK ZIP。

## 验证与剩余门槛

- 仓库 SDK：40 项 Python 检查通过，类型正例与 47 项预期错误检查通过；15 页手册、9 个源码对照块、34 条本地链接通过。
- 正式 Host：8 项 SDK / 文档契约测试通过，包含 Hello 和独立原创双按钮插件闭环。
- 独立 SDK：脱仓库 38 项通过、2 项需要完整仓库官方示例 / 兼容 wrapper 的检查明确跳过、0 失败；两次重打与分发 ZIP 逐字节一致。
- 两款官方插件已有单机实战验证。新作者仅凭文档、无额外指导完成安装及“约十分钟”目标仍属于 T39；Registry 的公开插件目录与真实网络安装仍属于 T40。

公开分发的是此有限 SDK。完整 SuperIsland 兼容、任意原生对象、浏览器或 Node.js 运行环境不在该接口承诺内。`package.json` 保留 `private: true`，开发依赖不属于插件运行时。
