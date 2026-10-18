# Packaging

`.dip` 是 Host 支持的 ZIP32 插件包。包根目录包含 manifest.json，entry 指向包内 `.js`。SDK 的 package 命令先做预检，再生成确定性归档。逐步可执行命令见 [Quick Start](quick-start.md)；每次输出使用尚不存在、位于源码树外的路径。

从 SDK 目录使用 `python3 tools/di_plugin.py`，参数按下表顺序给出：

| 子命令 | 参数 | 作用 |
| --- | --- | --- |
| `validate-manifest` | Manifest 文件路径 | 严格 JSON 和 Manifest 声明检查。 |
| `validate-node` | 节点 JSON 文件路径 | 本 SDK 八类节点和聚合限额。 |
| `validate` | 插件目录路径 | Manifest、入口存在、文件与资源限额；不会执行 JS。 |
| `package` | 源目录路径、输出 `.dip` 路径 | 先校验再归档，不覆盖原文件。 |

CLI 输出单个 JSON 对象，成功退出 0，失败退出非零。打包器包含目录内所有普通文件，README 也在内；不要把 node_modules、旧 `.dip`、缓存、密钥或无关文件放在源码目录。不会根据 `.gitignore` 自动筛选。

源文件最多 256 个、目录加文件最多 512 项、单文件最多 8 MiB、总文件最多 32 MiB；入口脚本另受 Host 更小的执行限额。禁止软链接、硬链接、特殊文件、路径穿越、大小写 / Unicode 路径冲突；路径深度最多 16、UTF-8 最多 1,024 bytes。打包时变动的文件会导致失败，保存后重新生成到新路径。

安装器独立检查归档、Manifest、Host 版本与整包内容。预检成功不授予执行资格。导入后检查预览并安装；新安装或替换均保持停用，按需要逐项授权并启用。同 ID 替换会提示升级 / 降级，代码或 Manifest 变化后的旧授权失效。

更改入口、Manifest 或任意随包文件后重新打包和验收。不要直接修改已安装目录来绕过包身份校验。需要删除旧分发包时由作者自行管理明确路径；打包命令不会自动删除旧输出。
