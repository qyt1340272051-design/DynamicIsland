# T40：官方包与公开目录发布准备

2026-10-19。T35 / T36 实机依赖已满足；当前 Registry 主目录仍为空，SDK 稳定发布与公开网络安装继续单独验收。本轮先准备可审阅、可重复的本地发布材料。

仓库根目录运行：

```sh
python3 Scripts/prepare-plugin-release.py --tag plugins-0.6.0 --output /tmp/dynamic-island-plugin-release
```

输出目录必须不存在。脚本只读取两款官方插件的 manifest.json、index.js、README.md，附加仓库 MIT LICENSE，生成固定时间和排序的 `.dip`、SHA256SUMS、release-manifest.json 与 registry.candidate.json。新增许可文件不改变插件入口或 Manifest，但整包摘要和审阅身份会改变，安装仍必须明确确认并重新审阅权限。

候选目录不是正式发现源。只有固定 Release 下的实际 `.dip` 可公网下载、逐包摘要与 Manifest 匹配，并经过 Host 下载 / 解包 / 安装验证后，才将条目登记为正式目录；不得用尚不存在的下载地址填充 Registry/registry.json。

计划发布目标为现有公开仓库的 `plugins-0.6.0` Release，包含 Pomodoro 0.2.1 与 GitHub 0.1.0 两个独立包及摘要。它是插件包发布，不是主 App 0.6.0 的 DMG 发布。当前步骤不创建 Git tag、不上传、不推送、不改变默认分支。

## 本地结果

两次独立输出的五个文件已逐字比较，两款包均包含且仅包含 Manifest、入口、README 和完整 MIT LICENSE；包内四份文件与当前源码一致。材料与结构化校验结果已[归档](evidence/t40-release-preparation-20261019/README.md)。

| 包 | SHA-256 |
| --- | --- |
| Pomodoro 0.2.1 | `7b33c55615d2043d432eaef2cca84b856f0eaa6817c5fef086c1cc9bcc4b7ef3` |
| GitHub 0.1.0 | `277c8eda20d2a34648e5255ccf39504c54d0f88b3173c8b361725e74531281a6` |

没有以这些候选地址替换正式 Registry，也没有将本地打包通过写成真实公开网络安装通过。
