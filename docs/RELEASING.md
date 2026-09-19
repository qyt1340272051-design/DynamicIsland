# 发布 Dynamic Island

当前采用 GitHub **公开测试预发布**：每个 `v*` Tag 在 macOS CI 上测试并通过 `Scripts/release.sh --local` 生成双架构 DMG、SHA-256 和 JSON manifest，再作为 GitHub Release 的预发布附件提供。`0.5.0` 也是这一路径。产物仅有 ad hoc 本地签名，**没有 Developer ID 签名或 Apple 公证**；不能称为正式签名公证版，也不能承诺下载后双击即可运行。

九项真机 Beta 场景仍为 `pending`。公开测试包用于收集实机证据，不代表兼容性验收通过；状态与出口条件见 [Beta 验收手册](BETA_TESTING.md)。

## 发布前准备

- 发布构建需要 macOS 26.0 或更高版本及 Xcode 26.6；不需要 Developer ID 证书或公证凭据。
- 更新工程 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、CHANGELOG、发布说明和相关文档；Tag 的三段版本必须与工程一致。
- 运行 `./Scripts/ci.sh`，确认工作区干净，并确保准备标记的提交已进入 `main`。

可在本机预先运行以下命令，生成与自动预发布同类型的 Archive、DMG、校验和及 manifest（当前工程版本为 `0.5.0`）：

```bash
./Scripts/release.sh --local
```

输出位于 `build/release/`，文件名含 `-local`。SHA-256 和 manifest 与 DMG 同目录；manifest 中 `notarized` 为 `false`。上传前应保留这些标识，不要把文件改名为无 `-local` 后缀的正式安装包。

## 发布步骤

1. 提交版本、文档和发布配置改动，并确认 `main` 上的完整 CI 通过。
2. 检查同名 Tag 和 GitHub Release 尚不存在，避免重复发布或覆盖已有附件。
3. 在 `main` 的目标提交创建并推送 annotated Tag，例如：

```bash
git tag -a v0.5.0 -m 'Dynamic Island v0.5.0'
git push origin v0.5.0
```

4. `.github/workflows/release.yml` 自动重新测试，在 Tag 对应源码上运行 `./Scripts/release.sh --local`，并创建公开 **预发布**；附件为 `Dynamic-Island-<版本>-local.dmg`、`.sha256` 和 `.json`。流程不使用证书或公证 Secrets。
5. 从预发布下载产物，在没有 Xcode 或开发证书的 Mac 上记录 SHA-256、安装、首次启动和权限请求结果，再逐项更新真机矩阵；未测试的场景继续保持 `pending`。若构建或发布失败，检查 Actions 日志，修复后不要悄悄覆盖已下载的同名版本，应递增版本号或明确记录重发原因。

## 干净 Mac 验收

通过浏览器从 GitHub Release 下载 DMG 和 `.sha256`，保留下载文件的 quarantine 属性，先在下载目录执行：

```bash
shasum -a 256 -c Dynamic-Island-0.5.0-local.dmg.sha256
```

打开 DMG，把 `Dynamic Island.app` 拖入“应用程序”并尝试打开。由于没有 Developer ID 签名与公证，macOS 可能阻止首次启动；仅在确认下载来源、校验和且信任此 App 时，前往“系统设置 > 隐私与安全性”点击“仍要打开”，再在提示中确认“打开”。参阅 [Apple 官方步骤](https://support.apple.com/zh-cn/102445)。受设备管理策略限制的 Mac 可能无法放行；不要关闭系统安全机制，也不要使用 `xattr` 删除隔离标记来掩盖安装问题。

首次使用 Apple Music 时检查自动化权限提示；音量、文件拖入、AirDrop 和计时工具各执行一次。把设备型号、系统版本、是否需要手动放行和测试结果记录到 Beta 验收矩阵。没有这些实测证据时，不得宣称“别人都能安装”。

## 版本规则

- App 的 `CFBundleShortVersionString` 使用纯数字三段式，例如 `0.5.0`。
- Git Tag 使用 `v0.5.0` 这类名称，也可附带 `-beta.1` 等预发布标识；无论 Tag 是否有后缀，当前发布流水线生成的都是未公证测试预发布。
- 每次提交 App 二进制时递增 `CURRENT_PROJECT_VERSION`。
- Tag 中的三段版本必须与工程 `MARKETING_VERSION` 完全一致，否则发布脚本会失败。

如将来需要无需手动放行的正式版，需另行配置 Developer ID 签名、Apple 公证、ticket staple，并在干净 Mac 上验证 Gatekeeper；ad hoc 测试包不能替代这些步骤。
