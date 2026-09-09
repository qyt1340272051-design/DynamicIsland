# 发布 Dynamic Island

正式发布链路面向 GitHub Release 的 Developer ID 直接分发，不经过 Mac App Store。每个正式产物必须依次通过测试、Release Archive、Developer ID 签名、Apple 公证、ticket staple、Gatekeeper 验证和 SHA-256 生成。

## 发布要求

- 有效的 Apple Developer Program 团队。
- 钥匙串中存在该团队的 `Developer ID Application` 证书及私钥。
- Xcode 26.6，并已完成首次启动组件安装。
- 可用的 Apple 公证凭据：钥匙串 profile、App Store Connect API key，或 Apple ID 的 app-specific password。
- 准备发布的 Tag 指向当前 `HEAD`，且工作区干净。

不能使用 `Apple Development`、ad hoc 或自签名证书替代 Developer ID。`Scripts/release.sh --release` 会在打包前拒绝这些情况。

## 本地管线测试

下面的命令会生成通用架构的本地开发签名 Archive、DMG、校验和及 manifest，用于验证打包脚本：

```bash
./Scripts/release.sh --local
```

输出位于 `build/release/`，文件名包含 `-local`。这类产物没有公证，不能上传到 Release 或提供给用户。

## 配置本机公证

建议把凭据写入钥匙串，不把密码放进脚本或 shell 历史。省略 password 参数后，`notarytool` 会安全地交互询问：

```bash
xcrun notarytool store-credentials dynamic-island-notary \
  --apple-id '<APPLE_ID>' \
  --team-id '<TEAM_ID>'
```

验证 profile 后，可以在已经创建发布 Tag 的干净 checkout 中运行：

```bash
APPLE_TEAM_ID='<TEAM_ID>' \
NOTARYTOOL_PROFILE='dynamic-island-notary' \
./Scripts/release.sh --release v0.4.0-beta.1
```

脚本只会在公证状态为 `Accepted`、ticket 已成功 staple 且 `spctl` 接受 DMG 与其中 App 后生成最终校验和。

## GitHub Actions Secrets

Tag 发布 workflow 需要在仓库 `Settings > Secrets and variables > Actions` 中配置：

| Secret | 内容 |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_ID` | 用于公证的 Apple ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple ID 的 app-specific password |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | 含私钥的 Developer ID Application `.p12` 文件 Base64 内容 |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | 导出 `.p12` 时设置的密码 |

证书只会导入 GitHub runner 的临时钥匙串，workflow 结束时会删除钥匙串和 `.p12` 文件。不要把任何证书、密码、API key 或 profile 提交到仓库。

## 发布步骤

1. 更新 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、CHANGELOG 和文档。
2. 运行 `./Scripts/ci.sh` 与 `./Scripts/release.sh --local`。
3. 提交全部发布改动，确认工作区干净。
4. 创建并推送 annotated Tag：

```bash
git tag -a v0.4.0-beta.1 -m 'Dynamic Island v0.4.0-beta.1'
git push origin v0.4.0-beta.1
```

5. `.github/workflows/release.yml` 自动重新测试、导入证书、签名、公证、staple，并创建带 DMG、SHA-256 和 JSON manifest 的 GitHub prerelease。
6. 下载 Release 产物，在未安装 Xcode 的另一台 Mac 上完成最终验收。

## 干净 Mac 验收

必须通过浏览器下载 DMG，以保留 quarantine 属性，然后执行以下检查：

```bash
shasum -a 256 -c Dynamic-Island-0.4.0-beta.1.dmg.sha256
spctl --assess --type open --context context:primary-signature --verbose=2 \
  Dynamic-Island-0.4.0-beta.1.dmg
```

随后打开 DMG，把 `Dynamic Island.app` 拖入 `/Applications` 并正常启动。首次使用 Apple Music 时检查自动化权限提示；音量、文件拖入、AirDrop 和计时工具各执行一次。Gatekeeper 不应要求通过右键“打开”绕过。

## 版本规则

- App 的 `CFBundleShortVersionString` 使用纯数字三段式，例如 `0.4.0`。
- Git Tag 可以附带预发布标识，例如 `v0.4.0-beta.1`。
- 每次提交 App 二进制时递增 `CURRENT_PROJECT_VERSION`。
- Tag 中的三段版本必须与工程 `MARKETING_VERSION` 完全一致，否则发布脚本会失败。
