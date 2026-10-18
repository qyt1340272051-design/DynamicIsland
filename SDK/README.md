# DynamicIsland SDK 实验草案

本目录是 0.6.0 开发分支中的 **实验性作者工具**，尚未发布稳定 SDK。T35 的完成提示补拍、T36 的真实界面 / Open 验收仍待完成；T38 保持 `in progress`。wire API `1.0.0` 与 Manifest schema `1` 是协议标识，不等于 SDK 已达到稳定发布门槛。

工具需要 Python 3.9+，只使用标准库，可离线运行，不执行 JavaScript。插件运行无需 Node.js、Python、npm 或 TypeScript；安装和执行仍由主程序负责。

新作者从[开发手册 / Quick Start](docs/quick-start.md)开始。完整的 [13 个主题](docs/README.md)解释 Manifest、Activity、组件、动作、资源与权限、设置、生命周期、排错和分发；文档代码块纳入 CI，首次安装体验仍保留验收门槛。

## 开始一个插件

在本目录的副本中修改 [Hello World](examples/hello-world/README.md) 的 Manifest 和 JavaScript。只需理解本目录的类型、示例和下述合约，无需阅读主程序 Swift 源码。以下从 SDK 目录执行：

```sh
python3 tools/di_plugin.py validate examples/hello-world
python3 tools/di_plugin.py package examples/hello-world /tmp/hello-world-0.1.0.dip
```

输出文件必须尚不存在、位于源目录之外。随后在主程序「插件管理 → 导入插件」中选择 `.dip`，检查预览，安装后单独启用。示例不请求额外权限；展开刘海后从工具菜单选择「你好，计数器」，点击「加一」。工具提供 minimal、compact、expanded 三种布局，但不自动展开窗口；停用或重启从零计数。

源目录之外的类型引用仅供编辑器使用，JavaScript 运行时不会导入它。打包器保留所有普通源文件；请把构建产物放在源目录之外，勿将无关文件或凭据放入插件目录。

## 当前草案范围

[types/island.d.ts](types/island.d.ts) 描述两款官方插件自动验证过的 Native API 子集，未声明完整 Host 能力。两款官方示例的真实设备验收仍分别保留。

| 接口 | 本草案提供的调用 |
| --- | --- |
| `island.log` | 固定级别日志；保留的诊断不含消息正文。 |
| `island.activity` | `publish`、`update`、`end`。 |
| `island.actions` | `on`，注册完成后再发布相应动作声明。 |
| `island.storage` | `get`、`set`；需要 capability 和单独批准的 `storage.local` 权限。 |
| `island.scheduler` | `requestRefresh`，Host 管理的一次性刷新。 |
| `island.countdown` | `get`、`start`、`pause`、`resume`、`stop`、`onComplete`。 |
| `island.network` | `fetch`，受 Host 目标政策和网络权限约束的 HTTPS GET / HEAD。 |
| `island.links` | `open`，需要明确权限及本次真实动作的 activation；当前允许的目标为 `github.com`。 |

节点只提供 `text`、`icon`、`hStack`、`vStack`、`spacer`、`progress`、`countdown`、`button`。外观由 Host 控制；进度为有限的 0…1 数值，倒计时必须引用当前 Host record 的 generation，不能自定截止时间或窗口尺寸。

Manifest Schema 保留 Host 的完整闭集，方便诊断所有已知声明；这不表示每项声明都有对应 SDK 方法。SuperIsland 是另一个显式兼容模式，其私有展示桥接不在本 Native SDK 中。声明 `supported` 只说明接口存在，不代表已经授权或当前可以执行。

## 调用和生命周期

- Host 方法返回 Promise。`publish` / `update` 返回本地 Activity ID；变更类调用通常返回 `null`，具体以类型为准。
- 全局 `onStart()` 和 `onStop()` 必须同步返回 `undefined`。用同步 hook 启动 Promise 链并捕获拒绝；动作和完成回调可以返回真实 Promise。模板已演示这一方式。
- 注册动作后，将相同 ID 同时用于 Activity 的 `actions` 与按钮节点。Host 根据当前呈现的实例重新检查动作，旧按钮不能操作重启后的实例。
- `update` 是 Activity 字段补丁，但整个 `presentation` 是替换对象；生命周期 policy 不能在同一实例中改变。工具使用 persistent 或 progress。
- 拒绝值是 `{code,message}` 数据，不保证是 `Error`。检查 `code` 并处理拒绝；不要依赖堆栈或把输入正文写入诊断。
- `activation` 来自符合条件的真实用户动作，可能缺省、会到期且只能使用一次。类型的品牌不提供运行时构造器；不要缓存、伪造或重用票据。
- Storage 和网络 JSON 的返回树被冻结、对象为无原型数据；入站数组只有 `length` 与数字索引，不承诺 `map`、`slice` 或迭代器。使用 `for (let i = 0; i < value.length; i++)`，并验证业务字段。`Array.isArray` 不会恢复原型方法。
- 停止后 Host 撤销执行并移除 UI、动作和资源；旧 Promise / 回调不能继续访问新执行。一次性刷新不是 JS 定时器，实际时间由 Host 能耗策略决定。

## 离线检查

```sh
python3 tools/di_plugin.py validate-manifest examples/hello-world/manifest.json
python3 tools/di_plugin.py validate-node tests/fixtures/valid-node.json
python3 -m unittest discover -s tests -p 'test_*.py'
```

CLI 输出单个 JSON 对象，成功退出码为 0，错误为非零；不打印脚本正文。JSON Schema 在 [schema/](schema/) 中，适合编辑器提示。CLI 额外检查重复键、UTF-8 字节、非有限数值及聚合树限额：深度 8、128 个节点、每组 16 个子节点、文本 256 bytes。校验目录检查 Manifest、入口存在、文件 / 路径与包资源上限；不会解释脚本、检查 JS 业务逻辑或模拟 Host。

这些检查只是开发预检。真实安装仍独立检查归档、Manifest、最低版本及整包状态；运行时再检查能力、授权、实例、generation、显示政策和限额。通过本工具不保证插件能启动或一定展示，不能替代实际验收。

可选类型检查：在 SDK 目录运行 `npm ci --ignore-scripts`，再运行 `npm run check:types`。开发依赖锁定 TypeScript 4.5.5；47 项预期类型错误若被错误接受也会导致检查失败。模板本身直接执行 JavaScript，无需编译。仓库 CI 还运行 `Scripts/check-plugin-sdk.sh` 与正式 Host 契约测试；独立 SDK 的少数仓库对照测试会明确跳过缺少的外部仓库材料。

## 版本和参考

兼容策略见 [VERSIONING.md](VERSIONING.md)。官方 [Pomodoro](../docs/plugin-system/examples/pomodoro/README.md) 与 [GitHub](../docs/plugin-system/examples/github/README.md) 保留在仓库原位置，避免复制后漂移；它们不是独立 SDK 运行所需文件。开发进度和未验收门槛见 [PROGRESS](../docs/plugin-system/PROGRESS.md)。
