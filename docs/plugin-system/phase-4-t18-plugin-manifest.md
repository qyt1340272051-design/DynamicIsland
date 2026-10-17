# Phase 4 — T18 PluginManifest 验证记录

日期：2026-09-29。范围：稳定、版本化的 V1 插件描述格式。包文件、真实路径、symlink、重复安装 ID 和 Host 兼容性门禁属于 T19。

2026-10-12 T33 兼容扩展：增加可选 developer 自述信息，见 [管理界面与授权记录](phase-7-t33-extensions-settings.md)。原九个必需字段、旧包编码及下述历史验证仍保留。

2026-10-17 T37 显式模式扩展：`engine` 新增 `superisland` 闭集值，用于固定的 SuperIsland V1 协议配置；底层仍为隔离 JavaScriptCore。原生模式不会探测入口代码并自动切换；未知字段、权限与 capability 的拒绝规则保持严格，见[模式与授权合约](phase-8-t37-manifest-profile.md)。

## V1 契约

Manifest 是只含数据的 `Codable`、`Sendable` 模型，九个字段必填，developer 可选：

| 字段 | V1 规则 |
| --- | --- |
| `schemaVersion` | 整数且必须为 `1`；未知版本先拒绝，不能按 V1 猜测解析。 |
| `id` | 小写 ASCII 反向域名，至少三段，总长不超过 255 bytes；每段 1–63 bytes，以小写字母开头、字母或数字结尾，中间只允许小写字母、数字和连字符。 |
| `name` | 1–80 个 Unicode scalar，不允许首尾空白、控制字符、方向控制符和不可见格式字符。 |
| `version` | SemVer 2.0.0 字符串。 |
| `engine` | 显式选择 `javascriptcore` 原生 V1 或 `superisland` 固定兼容配置；其他字符串拒绝。 |
| `entry` | 最长 240 bytes 的相对 POSIX `.js` 路径；拒绝绝对路径、空段、`.`、`..`、反斜线、NUL 和未声明字符。 |
| `minimumHostVersion` | SemVer 2.0.0 字符串。 |
| `permissions` | T28 规划的 7 项闭集；未知项和重复项均拒绝。 |
| `capabilities` | Activity publish/update/end、IslandNode UI、action、local storage 和 scheduler 共 7 项闭集；未知项和重复项均拒绝。 |
| `developer` | 可选自述开发者，采用 name 的文本规则；不能表示已验证的发布者身份。 |

`SemanticVersion` 保留 prerelease 与 build metadata。优先级按 SemVer 比较，build metadata 不参与优先级；核心数字用规范化十进制字符串比较，不受固定宽度整数溢出限制。

合法的最小 V1 示例：

```json
{
  "schemaVersion": 1,
  "id": "com.example.focus-timer",
  "name": "Focus Timer",
  "version": "1.0.0",
  "engine": "javascriptcore",
  "entry": "index.js",
  "minimumHostVersion": "0.6.0",
  "permissions": [],
  "capabilities": []
}
```

## 严格解析与错误

- `PluginManifest.init(from:)` 使用动态 CodingKey 比对实际顶层 key，避免 `JSONDecoder` 默认忽略未知字段。
- 解析先读取 `schemaVersion`，再检查九个必需字段及 developer 可选字段；其他新增字段不能被猜测为兼容 V1。
- `decodeJSON` 只接受无 BOM 的 UTF-8，并在 Foundation 丢失信息前扫描顶层字段名；普通形式或 Unicode escape 形式的重复 key 都会被拒绝，UTF-16/UTF-32 不能绕过扫描。
- 权限和 capability 先按原始字符串数组解析，再逐项映射闭集并检测重复；不会过滤未知值后继续运行。
- `decodeJSON` 限制输入为 64 KiB，并且是 T19 读取不可信 Manifest 字节的唯一入口。通用 `JSONDecoder` conformance 用于已经受边界约束的数据和 Codable round trip；Decoder 在调用模型前已经消费原始字节，模型无法从该接口恢复输入大小或重复 key 信息。
- 公开错误提供稳定的 `code`、JSON `path` 和非空说明，覆盖格式、字段、重复字段、类型、版本、ID、入口、权限及 capability 问题。
- [JSON Schema](schema/plugin-manifest-v1.schema.json) 使用 Draft 2020-12、`additionalProperties: false`、九个 required 字段、闭集 enum 和 `uniqueItems: true`，并与 Swift 运行时规则同步。

例如，额外的 `publisherVerified` 字段返回 `unknownField` 和 `$.publisherVerified`；重复的 `id` 返回 `duplicateField` 和 `$.id`；`version: "1.2"` 返回 `invalidSemanticVersion` 和 `$.version`；`permissions: ["shell.execute"]` 返回 `unknownPermission` 和 `$.permissions[0]`。调用方可以显示稳定错误而无需解析 Foundation 的调试文字。

## 验证

- [PluginManifestTests](../../DynamicIslandTests/PluginManifestTests.swift) 共 15 项，覆盖完整/最小合法样本、九字段 round trip、未知键的两条解码入口、普通/escaped 重复顶层字段、逐字段缺失、类型错误、schema 版本、输入上限、ID/name/entry 边界、SemVer 合法性与官方优先级链、未知/重复权限和能力，以及 Schema pattern、长度和 Swift enum 同步。
- 定向执行 `PluginManifestTests`：15 tests、0 failures。
- Schema 通过 `jq` 解析和 Python 契约 smoke checks；`git diff --check` 通过。
- `./Scripts/ci.sh`：292 passed、1 skipped、0 failures；Release build passed。

## T19 边界

T18 只验证 `entry` 的词法安全。入口文件存在性、包根目录 realpath、symlink、文件数量与大小、压缩包展开上限、重复安装 ID，以及当前 Host 是否达到 `minimumHostVersion`，均由下一步 PluginValidator 在执行第三方代码前检查。T19 读取磁盘 Manifest 时必须调用 `PluginManifest.decodeJSON(_:)`，不能直接用无字节边界信息的通用 Decoder。
