# Storage

`island.storage.get(key)` / `set(key, value)` 使用 Host 管理的插件私有命名空间，需要 capability `storage.local`，Manifest permission `storage.local`，以及当前包的明确授权。安装、启用、接口 supported 均不会自动批准访问。

缺失 key 的 get 返回 `null`；set 成功返回 `null`。值必须是普通 JSON：不能有 undefined、函数、getter、循环引用、稀疏数组或非有限数值。入站对象和数组均被冻结且无原型；数组仅保证数字索引和 length，不能调用 map / slice 或用数组展开语法。不要向返回值直接赋值，先验证业务字段，再构造自己的输出数据。

| 限额 | 当前值 |
| --- | --- |
| key 长度 | 最多 128 UTF-8 bytes |
| 单值编码大小 | 最多 8,192 bytes |
| 单值字符串 | 最多 4,096 UTF-8 bytes |
| 单值复杂度 | 深度 8、节点 256 |
| 每插件命名空间 | 最多 128 个 key、65,536 bytes |

拒绝、撤销或磁盘失败时，保留内存中的工作状态，用有限 UI 提示“未保存”；不要在 tight loop 重试。写操作要串行化或只保留一个在途写和最新草稿，避免旧值晚写覆盖新值。当前 SDK 只公开 get / set，不提供删除 / 清空方法。

[Settings](settings.md)提供完整的 schemaVersion 校验和默认值函数。授权失效时读操作使用默认值，写操作返回失败；不会凭存储内容自动启动计时。Host 卸载插件会保留已存数据，但撤销授权；重新安装也不能继承旧代码的授权。
