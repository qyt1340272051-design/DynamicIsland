# T40 公开发布证据

2026-10-20/21。结论见[验收记录](../../t40-registry-publication-20261020.md)，机器可读结果见 [result.json](result.json)。

- `independent-result.json` / `independent-audit.txt` / `independent-prepare.txt`：第三次独立重打和包源码复核；`old-candidate-result.json` 仅作历史基线。
- `release-manifest.json`、`SHA256SUMS`、`registry.candidate.json`：当前冻结摘要和目录；候选文件本身不是 Host 默认源。
- `source-mapping.json`：插件专用十文件源码树及原 Host 提交映射。
- `published-release.json`、`anonymous-result.json`：公开且 prerelease，四资产匿名下载并逐字匹配。
- `merged-pr.json`、`registry-main-result.json`：PR / CI / 合并及默认目录匿名响应。
- `premerge-live.*` / `default-main-live.*`：真实 Host 原始日志和 xcresult 摘要，分别来自固定公开提交、默认 main，均零失败零跳过。原 xcresult 在 `/tmp/dynamic-island-t40-publish-20261020/`。
- `registry-regression.*`：28 passed / 1 skipped / 0 failures；跳过项是锁屏条件下原生 AppKit 鼠标输入，不算通过。
- `release-build.txt`：普通 Release 构建日志。
- `gui-preflight.json`、`gui-discovery-*`、`gui-cleanup-attempt.json`：全新隔离副本发现页实际刷新、两款条目及正常退出。初态文本为工具原样无变化摘要，初态以原始截图为准；后续 GUI 安装因失效菜单引用未完成。

权限测试只操作临时根目录，未操作生产插件数据或通过 GUI 批准权限。恢复测试重建 Host 对象图，不是 App 进程重启，不替代 T39 人工作者走查。
