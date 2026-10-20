# 独立 SDK 归档与分发

本目录为 SDK `1.0.0` 稳定发布源。公开构件通过 [sdk-v1.0.0 Release](https://github.com/qyt1340272051-design/DynamicIsland/releases/tag/sdk-v1.0.0) 分发；下载后先按同页 SHA-256 清单核对 ZIP，再从解压后的 README 开始。Release 标签提供 SDK 专用源码快照，根目录即独立 SDK。

## 构建本地归档

在 SDK 根目录运行 `python3 tools/package_sdk.py /tmp/dynamic-island-sdk-1.0.0.zip`。输出必须是尚不存在的 `.zip`，且位于 SDK 源目录之外。脚本只读取固定的文档、类型、Schema、模板、工具、测试和版本配置；排除缓存、隐藏文件和 `node_modules`，不打包主 App、插件安装数据或工作区证据。

归档根目录为 `DynamicIslandSDK/`。其中 `distribution-manifest.json` 保存 SDK 版本、协议与最低 Host 版本、各源文件的 SHA-256 和大小。清单由归档时的实际字节生成；它用于检查完整性，不提供来源身份认证。ZIP 使用固定时间和排序，在相同 Python / zlib 工具链下可重复生成相同字节。

解压后从 `DynamicIslandSDK/` 开始阅读 [README](README.md) 与 [Quick Start](docs/quick-start.md)。无需完整仓库。离线打包只需 Python；文档源码校验还需要 Node.js，可选 TypeScript 检查使用锁定的开发依赖。归档包含源码级 [MIT License](LICENSE)，不包含或重新分发 TypeScript 编译器。

## 稳定版本复核

SDK 版本独立于 App、wire API 和 Manifest Schema。首次稳定接口采用 **SDK `1.0.0`**；版本配置、类型头、CLI、Schema 来源和归档一致标识此版本。`private` 保持 true，不发布到 npm。冻结的有限接口承诺见 [CHANGELOG](CHANGELOG.md)。

生成或核对本版本分发包时执行以下检查：

- 两个官方插件实战验证已于 2026-10-19 完成；保持有限 Native API 的范围，不把完整 Host 实现或 SuperIsland 私有桥接写入 SDK 承诺。
- 复核类型、Schema、CLI、Host 契约与示例的一致性；确认同步生命周期、无原型入站 JSON、动作凭证及撤销语义。
- 保留首次作者走查中的 zsh 卡点和修正结果；修正版手册的独立上手与实际用时继续单独验收。
- 版本配置及兼容承诺同步到 `1.0.0`；复核实际归档中的类型、Schema、CLI 和发布说明。版本变更不改变 wire 协议，也不授予插件权限。
- 运行 SDK 检查和正式 Host 契约，生成最终归档与摘要，复核完整性后再执行公开上传。最终稳定构件须来自复核后的同一源码状态。

归档工具只生成本地文件；公开分发身份以对应 Release 的标签、构件和摘要为准。SDK Release 单独发布，插件包及 Registry 目录仍按各自验收流程管理。
