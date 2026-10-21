# .dip V1 插件包

`.dip` 使用受控的 ZIP32 格式。包根目录必须有精确命名的 `manifest.json`；入口脚本的位置由 Manifest 的 `entry` 指定，可放在子目录。包中不包含可由 Host 直接加载的原生库。

## 制作插件包

在仓库根目录执行：

```sh
python3 Scripts/package-plugin.py docs/plugin-system/examples/github-mock /tmp/github-mock.dip
```

需要 Python 3.9 或以上。输出必须位于源目录之外且尚不存在。脚本检查基本文件类型和大小并生成受支持的 ZIP；完整 Manifest、版本和安全验证由 Host 导入时执行。打包不会执行 JavaScript。

在「插件管理」点击「导入插件…」，或在正常应用目录安装 App 后双击 `.dip`。临时构建目录可能不被本机 LaunchServices 选为文件处理程序；开发验收应使用正常目录的副本。Host 解包并验证后展示名称、版本、开发者自述、升级 / 降级信息和每项权限用途。点击安装只安装包；新安装及升级都保持停用，权限需要在管理页分别确认。新增权限不会沿用旧版本的批准。

## 支持范围与限额

| 项目 | V1 限制 |
| --- | --- |
| 压缩包大小 | 40 MiB |
| 单个普通文件 | 8 MiB |
| 所有普通文件展开后总量 | 32 MiB |
| 普通文件数量 | 256 |
| 路径节点总量 | 512，包含隐式父目录 |
| 每条路径组件数 | 16 |
| 相对路径 UTF-8 长度 | 1024 bytes |
| 压缩方法 | stored（0）或 raw deflate（8） |
| 字符编码 | ASCII 或标记为 UTF-8 的名称 |
| Extra 字段 | `0x5455` 时间戳、`0x7875` UID/GID；仅验证结构，不恢复元数据 |

实际解压输出逐块检查限额，结束时必须与声明大小及 CRC 一致。拒绝 Zip64、多卷、加密、data descriptor、未知 extra、符号 / 硬链接、特殊文件、绝对路径、`..`、空组件、反斜杠、盘符以及大小写 / Unicode 规范化冲突。local 和 central 记录必须一致且完整覆盖压缩数据区，重叠、未声明记录和尾随压缩数据都会被拒绝。Finder 或其他打包器若生成不在此子集内的元数据，请使用上面的脚本重新打包。

安装目录通过 Host 的 Application Support URL 决定：`DynamicIsland/Plugins/Installed/<pluginID>`。沙盒 App 的 Application Support 位于 App 自己的容器。`Staging` 存放本次预览，`State` 存放 Host 状态，`Recovery` 保留异常事务中的旧包。它们均不参与已安装包发现。

取消只清理本次 Host 创建的临时目录。确认前改变暂存包的任何文件、或者替换已安装版本，会使旧确认失效。升级事务停止旧 Runtime，使用同卷排他 rename 和持久化状态；失败尝试恢复旧包，恢复失败保留 Recovery 并关闭执行。安装前写入恢复标记，重启发现未完成事务时先持久化停用状态；损坏标记不被自动覆盖。

## 规范参考

- [PKWARE ZIP APPNOTE](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
- [zlib 手册](https://zlib.net/manual.html)
- [Apple 自定义文件类型声明](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app)
- [AppKit 文件 URL 接收入口](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:))
