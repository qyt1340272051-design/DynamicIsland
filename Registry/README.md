# Plugin Registry V1（开发中）

本目录作为 GitHub 仓库内的插件发现清单。当前 registry.json 故意为空：官方插件的实机验收和发布包尚未完成，没有可公开登记的固定下载地址。测试条目只在测试中生成，不加入正式目录。没有上传包、推送目录或创建 Registry 服务。

顶层只有 schemaVersion（数字 1）和 plugins 数组。每项必须精确包含 id、name、version、download、source、minHostVersion、hash，未知字段和重复字段拒绝；ID 唯一，最多 100 项，整个 JSON 最多 256 KiB。

- id / name / version 沿用 Host Manifest 的身份和版本规则。
- download 是 source 同一 GitHub 仓库的 HTTPS Release `.dip` 地址；不接受 `releases/latest/download` 简写、任意网站、查询参数或凭据。V1 标签 / 文件名仅支持 ASCII 字母、数字、点、下划线和连字符。
- source 是 GitHub 仓库根地址，用于展示来源；不是开发者身份或许可证明。
- minHostVersion 必须与下载包 Manifest 的 minimumHostVersion 一致。
- hash 是**实际 `.dip` 文件字节**的 64 位小写 SHA-256，不是解压目录或入口脚本的摘要。

目录只提供发现元数据。下载后先核对同一份归档字节的 SHA-256，再走现有 ZIP 防护、Validator、安装预览、安装后停用以及逐项权限流程。清单元数据不得替代实际 Manifest，不能借同 ID 偷换名称、版本或最低版本。

目录网络源限制为 raw.githubusercontent.com 的仓库 / 单段 ref / Registry/registry.json。目录重定向拒绝；Release 下载只允许 GitHub 的 release-assets.githubusercontent.com 资源重定向，字节上限和摘要校验仍执行。没有自动后台轮询、升级、授予权限或运行插件。
