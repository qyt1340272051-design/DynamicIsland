# UI Components

UI 是 JSON 节点树，要求 `ui.islandNode` capability。字体、颜色实际值、间距、圆角和安全区域由 Host 决定。不要加入 CSS、宽高、事件函数或任意图片路径。

| 节点 | 必需字段 | 可选字段 / 约束 |
| --- | --- | --- |
| `text` | `content` | `color`；文本最多 256 UTF-8 bytes。 |
| `icon` | `symbolName` | SF Symbol 标识；不要传文件或 URL。 |
| `hStack` / `vStack` | `children` | 每组最多 16 个子节点。 |
| `spacer` | 无 | 由 Host 分配空白。 |
| `progress` | `value` | 有限 0…1 数值；style 为 `linear` / `battery`，可用 color。 |
| `countdown` | `id`、`generation` | 必须对应当前 Host record；style 为 `time` / `progress`，可用 color。 |
| `button` | `actionID`、`label` | label 也是节点；可用 `accessibilityLabel`。动作需要注册并在 Activity 声明。 |

color 只接受 `primary`、`secondary`、`accent`、`success`、`warning`、`danger`。深度最多 8、总节点最多 128；空值与字段缺省不是一回事，例如 `color: null` 无效。这个可离线校验的静态节点表达半程进度：

<!-- sdk-source: snippets/progress.json -->
```json
{
  "type": "vStack",
  "children": [
    {"type": "text", "content": "正在处理", "color": "primary"},
    {"type": "progress", "value": 0.5, "color": "accent"}
  ]
}
```

为最小、收起和展开分别提供 minimal / compact / expanded。compact 应采用短图标、spacer、短文字两翼结构，避免把长文字或横向进度条放到相机遮挡区域；长内容放 expanded。Hello 的 compact 树虽存在，但模板隐藏 compact 展示，便于初次使用。

倒计时 generation 必须从当前 record 获取，不能复制文档中的随机 UUID。支持的树结构不等于已有对应业务资源；即使 JSON 校验通过，Host 仍会验证 generation、动作声明和展示政策。所有八类的精确字段见[节点 Schema](../schema/island-node-v1.schema.json)与[类型](../types/island.d.ts)。
