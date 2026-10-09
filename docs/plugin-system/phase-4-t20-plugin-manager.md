# Phase 4 — T20 PluginManager 实现与验收

日期：2026-10-09。范围：在 Host 控制的插件目录中发现并静态加载插件，独立保存启用状态，并提供重载和卸载入口。T20 的“加载”只表示通过 T19 校验并在 Manager 中保留不可变包快照，不创建 `JSContext`，也不执行插件代码。

## 责任范围

`PluginManager` 是一个 `actor`，串行维护“插件 ID → 已验证包快照”的登记关系。它负责：

- 扫描已安装目录并隔离单个坏包，使其他合法插件仍可出现在列表中。
- 对一个已位于安装目录的包执行 `load`，并在同一 actor 隔离域内复查 ID 占用后登记。
- 独立 `enable`、`disable` 多个插件，并保存各插件的精确版本和启用状态。
- `reload` 时重新执行 T19 校验，成功后替换不可变入口快照。
- 按已经登记的插件 ID `uninstall`，先移出发现目录，再提交状态变更。

T20 不负责 `.dip` 解压或安装提交、生命周期状态机、JavaScriptCore 执行、权限授权、网络和文件能力、Renderer 或设置界面。这些分别留给 T21、T22、T28、T33 和 T34。Manager 只保存 Manifest 中声明的权限与 capability，不在本阶段解释或授予它们。

## 受控目录

生产配置由 `PluginManagerConfiguration.applicationSupport(hostVersion:)` 建立，Host 版本必须显式注入。默认布局如下：

```text
~/Library/Application Support/DynamicIsland/Plugins/
├── Installed/                    # 每个直接子目录是一个候选插件包
├── State/
│   └── plugin-manager-v1.json    # 版本化启用状态
├── Recovery/                     # 卸载尚未提交或回移失败的原包，保留供恢复
└── Trash/                        # 卸载已提交后待清理的隔离包
```

测试可以注入独立的根目录、Host `SemanticVersion` 和 `PluginPackageLimits`。`load(at:)` 只接受 `Installed` 的直接子目录；调用方不能借 Manager 加载任意位置的路径。发现阶段只枚举直接子项，包内递归检查继续由 T19 `PluginValidator` 负责。

Manager 创建的目录使用 `0700`，包括 `Recovery` 和 `Trash`。已有目录与插件包根必须由当前用户所有，且 group/other 不得拥有写权限；symlink、普通文件或不安全目录不能成为受控目录。状态文件必须是当前用户所有、单链接的普通文件，拒绝 group/other 可写文件；新的状态临时文件从创建时起使用 `0600`。

## 对外 API

| API | 行为 |
| --- | --- |
| `discover()` | 重建当前登记表，返回合法插件和逐项失败的 `PluginDiscoveryReport`。 |
| `load(at:)` | 校验并登记一个已经放入 `Installed` 的包；新插件默认禁用。 |
| `enable(id:)` / `disable(id:)` | 先持久化下一状态，再更新内存记录；重复设置保持幂等。 |
| `reload(id:)` | 从原规范包根重新校验并原子替换快照；ID 或包根变化时拒绝。 |
| `uninstall(id:)` | 只按已登记 ID 操作，先把目标移到 `Recovery`，提交状态后删除隔离包与登记。 |
| `plugins()` / `plugin(id:)` / `isEnabled(id:)` | 返回稳定按 UTF-8 排序的轻量记录或查询结果。 |
| `validatedPackage(id:)` | 向后续 Runtime 提供 T19 已验证的包快照，包括不可变 `entrySource`。 |

`PluginRecord` 只包含 Manifest、规范包根、启用状态和文件统计，不把入口源码放入常规列表。后续 Runtime 必须消费 `validatedPackage(id:)` 返回的 `entrySource`，不能在执行前按路径重新打开入口文件。

## 发现与 ID 一致性

发现按以下顺序执行：

1. 建立并检查受控目录，清理 `Trash` 中已提交卸载的遗留项；`Recovery` 中的原包保留供恢复。
2. 读取 V1 状态文件；读取失败时记录 Manager 级失败并从全部禁用的空状态继续。
3. 分别调用 T19 Validator 检查各候选包，再检查包根所有权和写权限。
4. 按 Manifest ID 分组。同一批中出现重复 ID 时拒绝该 ID 的全部候选，不能让文件系统枚举顺序决定胜者。
5. 一次替换内存登记表并保存规范化状态，然后返回合法插件和排序后的失败列表。

单个候选的 Manifest、兼容性、入口、路径、资源配额或所有权错误只进入该候选的 `PluginDiscoveryFailure`，不会隐藏合法兄弟包。`PluginManagerError` 提供稳定 `code`；T19 错误原样包装为 `.validation`，供设置界面和诊断层显示。

`PluginManager` 的 actor 隔离覆盖已占用 ID 快照、复查和登记提交，中间没有 suspension point。两个并发 `load` 即使都携带相同 Manifest ID，也只能有一个成功；批量发现中的重复项则全部失败。

## 状态保存与恢复

状态文件使用显式 `schemaVersion: 1`，每个插件只保存 `version` 和 `isEnabled`：

```json
{
  "plugins": {
    "com.example.focus-timer": {
      "isEnabled": true,
      "version": "1.0.0"
    }
  },
  "schemaVersion": 1
}
```

恢复启用状态必须同时满足：插件再次通过完整静态校验、Manifest ID 相同，并且保存的 `SemanticVersion` 与当前包版本精确相等。新发现插件、没有状态的插件、版本变化插件和状态损坏后的插件一律保持禁用。未知 schema、非法 ID、超量记录、symlink、hardlink、不安全权限、超限或非法 JSON 状态均失败关闭。

普通启停和加载操作先提交状态文件，再改变内存登记。状态写入在 `State` 同目录中创建唯一临时文件，创建权限为 `0600`；完整写入、`fchmod`、`fsync` 和 `fstat` 检查全部在替换正式状态文件之前完成。`rename` 是最后一个可能失败的提交步骤；在这些操作中，提交前任一步骤失败，旧磁盘状态和内存记录均保留。提交后不再执行会使该次操作报失败的文件操作，避免出现正式状态已经改变、调用方却按失败保留旧内存的分歧。

`discover()` 会重建磁盘上当前可验证的登记表，再尝试保存规范化状态；规范化写入失败时仍返回合法插件列表，并附带 `stateWriteFailed`，使状态故障不会隐藏兄弟插件。

`reload` 的验证或状态提交失败时保留旧快照；任何 Manifest 变化都会使原本启用的插件变为禁用，要求用户重新确认后启用。

卸载先把原包移入 Host 控制的 `Recovery`，使其离开发现目录，然后提交移除目标插件后的状态。状态提交成功后清除目标登记并删除隔离包；删除失败时可移入 `Trash`，留待后续清理。状态提交失败时先尝试把原包移回原目录：回移成功后返回 `stateWriteFailed`，并保留旧登记；回移失败时返回 `uninstallRollbackFailed`，清除目标内存登记，同时保留 `Recovery` 中的原包供恢复。此时旧状态文件仍在，原包不再位于 `Installed`，调用方应显示该恢复错误；Manager 不会自动删除未提交卸载的原包。

## 安全边界与后续约束

- Manager 只接受 T19 `ValidatedPluginPackage`，不会解析或执行 `index.js`。
- `entrySource` 是验证时取得的不可变字节；路径仅用于受控重载和卸载定位。
- `Recovery` 中的包不能自动清理，也不参与发现；只有已提交卸载的隔离包才进入 `Trash` 清理流程。回移失败是显式错误，不能宣称所有卸载失败都会恢复原目录。
- 状态持久化的失败检查在正式文件替换前完成；启停、加载和重载在 `rename` 成功后提交对应内存记录。发现流程的规范化保存失败通过报告返回。
- Manager 不接收压缩包，也不处理 path traversal 或 zip bomb；T34 必须先安全展开并完成安装提交。
- 启用状态只表示用户允许后续生命周期启动，不代表当前已经 running；运行状态与回调属于 T21。
- Manifest 权限声明不会在 Manager 内直接转化为网络、文件、通知或系统能力；授权与 Bridge 门禁属于 T28。
- Renderer 和设置 UI 只能消费 Manager 输出，不应反向进入 Manager 的文件系统或执行边界。

## 验收步骤

定向测试至少覆盖以下场景：

1. 两个合法插件可同时发现并分别启用、禁用，创建新的 Manager 实例后恢复各自状态。
2. 新插件默认禁用；包版本或其他 Manifest 内容变化后重载为禁用，并替换 `entrySource`。
3. 一个非法包、一个不可读候选或损坏状态文件不会阻止合法兄弟包进入列表。
4. 批量重复 ID 全部拒绝；并发单包加载相同 ID 只有一个成功。
5. 重载验证失败或状态写入失败时，旧记录、启用状态和入口快照保持不变。
6. 卸载只删除目标插件的登记、状态和包目录，其他插件不受影响；重启后目标不会恢复。
7. 管理目录和状态文件权限符合 `0700`/`0600`，不安全的现有目录或状态文件失败关闭。
8. 入口包含可执行或抛错 JavaScript 也只能作为字节被加载，T20 全程没有代码执行副作用。
9. 启停、加载或重载的状态临时文件写入、权限设置、同步、检查或最终替换发生故障时，正式状态与内存记录保留原值；提交后无权限调整等后续失败点。
10. 卸载状态提交失败且原包回移成功时，返回 `stateWriteFailed`，原目录与旧登记恢复；回移也失败时，返回 `uninstallRollbackFailed`，目标登记清除，`Recovery` 中的原包在再次发现时仍被保留。
11. 已提交卸载的隔离包清理失败时，合法兄弟包仍保持可用；后续清理只处理 `Trash`，不删除 `Recovery` 中的待恢复原包。

实现完成后依次运行：

```bash
xcodebuild test \
  -project DynamicIsland.xcodeproj \
  -scheme 'Dynamic Island' \
  -destination 'platform=macOS' \
  -only-testing:DynamicIslandTests/PluginManagerTests

./Scripts/ci.sh

xcodebuild build \
  -project DynamicIsland.xcodeproj \
  -scheme 'Dynamic Island' \
  -configuration Release \
  -destination 'platform=macOS'
```

只有定向测试、完整 CI 和 Release build 均通过后，才在 `PROGRESS.md` 将 T20 标记为 `verified`，并记录实际测试数量和结果包路径。

## 2026-10-09 验收结果

- 最后审查修复了状态替换后的权限失败导致磁盘/内存不一致，以及卸载回移失败后原包被清理的问题；新增 3 项故障回归测试。
- PluginManager 定向测试：14 passed、0 failures；结果包为 `/tmp/dynamic-island-t20-transaction-tests.xcresult`。
- 最终 `./Scripts/ci.sh`：335 项测试，334 passed、1 项截图矩阵测试按设计 skipped、0 failures；结果包为 `/tmp/dynamic-island-t20-final-ci/TestResults.xcresult`，日志为 `/tmp/dynamic-island-t20-final-ci.log`。
- 同一次 CI 的 Release 构建通过，产物位于 `/tmp/dynamic-island-t20-ci-derived/Build/Products/Release/Dynamic Island.app`。
- 验证环境：MacBook Air、arm64、macOS 26.6.2；Release 配置校验及 Beta matrix 定义校验通过。
- Beta matrix 的 9 个真实设备场景仍按现有计划保持 pending，不属于 T20 的静态 Manager 验收范围。
