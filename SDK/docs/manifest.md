# Manifest

包根目录必须有 UTF-8、无 BOM 的 `manifest.json`。未知字段、重复字段、未知权限或能力、重复声明都会被拒绝。以下是可直接打包的 Hello Manifest：

<!-- sdk-source: ../examples/hello-world/manifest.json -->
```json
{
  "schemaVersion": 1,
  "id": "com.example.hello-world",
  "name": "你好，计数器",
  "developer": "示例开发者",
  "version": "0.1.0",
  "engine": "javascriptcore",
  "entry": "index.js",
  "minimumHostVersion": "0.6.0",
  "permissions": [],
  "capabilities": ["activity.publish", "activity.update", "ui.islandNode", "actions.handle"]
}
```

| 字段 | 规则与用途 |
| --- | --- |
| `schemaVersion` | 当前为数字 `1`。不能用字符串。 |
| `id` | 小写反向域名，至少三段；每段由字母起始、字母或数字结束，中间可用连字符。最大 255 UTF-8 bytes。它决定插件身份及私有存储命名空间。 |
| `name` / `developer` | name 必填，developer 可选；各 1–80 Unicode scalar，不含控制字符和首尾空白。developer 是自述信息，不是身份认证。 |
| `version` | 插件自己的 SemVer，例如 `0.1.0`。每个分发版本应对应固定内容。 |
| `engine` | 本手册使用 `javascriptcore`。不会根据代码自动检测模式。 |
| `entry` | 规范化相对 `.js` 路径；禁止绝对路径、`..`、空路径段。入口不是 ES module 加载器。 |
| `minimumHostVersion` | 必填 SemVer；这些例子需要 `0.6.0`。安装检查不会因工具预检通过而跳过。 |
| `permissions` | 访问资源的声明；仍需用户单独批准，见 [Permissions](permissions.md)。 |
| `capabilities` | 所需 Host 功能；不代替权限，也不保证当前执行获准。 |

常用能力：`activity.publish`、`activity.update`、`activity.end`、`ui.islandNode`、`actions.handle`、`storage.local`、`scheduler`、`countdown`、`links.open`。网络只声明 `network` 权限，没有名为 `network` 的 capability。`presentation.request` 属于兼容展示协议，Native SDK 草案没有公开该方法。

Host Schema 另识别 `superisland` 引擎；这不表示原始上游插件可直接安装或所有上游 API 均受支持。本手册和 Hello 面向 Native 草案。原始上游许可与实际兼容验收尚未完成。

离线 [Manifest Schema](../schema/plugin-manifest-v1.schema.json)用于编辑器提示；CLI 还检查重复键和字节限额。完整 Manifest 最多 65,536 bytes。校验和打包见 [Packaging](packaging.md)。
