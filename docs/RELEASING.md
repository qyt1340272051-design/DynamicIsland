# 发布 Dynamic Island

当前采用 GitHub **公开测试预发布**。本轮候选为 App `0.6.0`（build 4）、标签 `v0.6.0-beta.2`。每个 `v*` Tag 在 macOS CI 上测试，再通过 `Scripts/release.sh --local` 生成双架构 DMG、SHA-256 和 JSON manifest，作为 GitHub 预发布附件提供。下载以对应 Release 实际资产为准。

产物只有 ad hoc 本地签名，**没有 Developer ID 签名或 Apple 公证**，不能承诺下载后双击即可运行。九项真机 Beta 场景与 T39 新作者独立上手仍待验收；开发预览用于收集证据，不表示整个 Plugin 1.0 或稳定版出口条件已通过。状态见 [Beta 手册](BETA_TESTING.md)与[插件计划](plugin-system/PROGRESS.md)。

## 发布前准备

- 使用 macOS 26.0 或更高版本、Xcode 26.6；不需要 Developer ID 证书或公证凭据。
- 更新工程 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、发布配置校验、设备矩阵目标版本、CHANGELOG、发布说明和相关文档。Tag 的纯数字三段版本必须与工程一致；预发布标识保留在 Tag 和文件名中。
- 安装锁定的 SDK 类型检查器，执行完整 CI 和相关稳定性回归；未完成的真人 / 设备项仍保留原状态，不以模拟测试替代。

```bash
npm ci --prefix SDK --ignore-scripts --no-audit --no-fund
./Scripts/ci.sh
./Scripts/run-stability-matrix.sh
```

- 保持发布工作区干净，提交改动，以 PR 合入受保护的 `main`，等待必需的 `Test and build` 成功；不绕过保护规则。
- 检查同名 Tag 和 Release 尚不存在，避免覆盖已分发的资产。

## 本地预构建

在本机可先生成同类型的 Archive、DMG、校验和与 manifest：

```bash
RELEASE_TAG=v0.6.0-beta.2 ./Scripts/release.sh --local
```

默认输出 `build/release/Dynamic-Island-0.6.0-beta.2-local.dmg`、`.dmg.sha256` 和 `.json`。`notarized` 必须为 `false`；保留 `-local` 标识，不要改名为正式签名安装包。本地构建不自动上传。

## Tag 与自动预发布

1. 确认发布提交已经进入 `main` 且 CI 通过，记录对应 commit；检查同名 Tag / Release 不存在。
2. 在已审阅的 `main` 目标提交创建并推送 annotated Tag，例如：

```bash
git fetch origin main
git tag -a v0.6.0-beta.2 origin/main -m 'Dynamic Island v0.6.0-beta.2'
git push origin v0.6.0-beta.2
```

3. `.github/workflows/release.yml` 安装锁定 SDK 类型检查器并重新执行 CI，随后在该 Tag 源码运行 `RELEASE_TAG="$GITHUB_REF_NAME" ./Scripts/release.sh --local`，只创建明确标识的 **GitHub prerelease**。附件为 DMG、校验和和 JSON manifest；流程不使用证书或公证 Secrets。
4. 从公开 Release 独立下载三资产，核对 SHA-256、DMG 完整性、App 版本 / build、`arm64 x86_64` 双架构、strict / deep 签名与 `notarized=false`。这证明构件一致性，不等同于干净 Mac 实机安装。
5. 如构建或发布失败，修复并记录原因；不得悄悄覆盖已有同名版本，应递增预发布编号和 App build，并重新测试。

本轮 `v0.6.0-beta.1` 只创建了源码标签，发布验证因 ActionMock 原生输入测试未收到暂停回调而失败，未生成 DMG 或公开 Release 资产。保留该标签，修正测试流程后使用 `v0.6.0-beta.2` / build 4；不移动、删除或覆盖已公开标签。

SDK 1.0.0 和官方插件 `plugins-0.6.0` 使用独立标签与构件。它们不自动附带在 App 内，也不由 App Tag 重新发布；官方插件仍通过「发现」或本地 `.dip` 导入安装。

## 干净 Mac 验收

通过浏览器从目标 Release 下载 DMG 和 `.sha256`，保留下载文件的 quarantine 属性。在下载目录执行：

```bash
shasum -a 256 -c Dynamic-Island-0.6.0-beta.2-local.dmg.sha256
```

打开 DMG，把 `Dynamic Island.app` 拖入“应用程序”并尝试打开。macOS 可能阻止首次启动；仅在核对来源、校验和且信任此 App 时，前往“系统设置 > 隐私与安全性”点击“仍要打开”，再确认“打开”。参阅 [Apple 官方步骤](https://support.apple.com/zh-cn/102445)。设备管理策略可能不允许放行；不要关闭系统安全机制，也不要删除隔离标记来掩盖安装问题。

在没有 Xcode 或开发证书的 Mac 上记录下载、安装、首次启动、权限请求、正常退出及卸载。各执行一次音量、Apple Music 自动化、文件拖入、AirDrop、内置计时；另外通过发现页下载、预览、安装官方插件，确认安装后停用、逐项授权和启用。记录版本 / build、设备、是否手动放行、对应矩阵编号和证据。未实测的项目保持 `pending`，不得声称“别人都能安装”。

## 版本规则

- App 的 `CFBundleShortVersionString` 使用纯数字三段式，例如 `0.6.0`。
- Git Tag 可使用 `v0.6.0-beta.2`，与文件名一致；当前流水线即使 Tag 没有后缀，也只能生成未公证测试预发布。
- 每次提交 App 二进制递增 `CURRENT_PROJECT_VERSION`；本轮候选为 build 4。
- Tag 的三段版本必须与 `MARKETING_VERSION` 完全一致，否则发布脚本失败。

如将来发布 Developer ID 版，须另行配置签名、Apple 公证与 staple，并在干净 Mac 上验证 Gatekeeper 自动放行。ad hoc 预览不能替代这些步骤。
