# 编译说明

## 环境

- macOS 26.0 或更高版本
- Xcode 26.6，使用其中的 macOS SDK 和命令行工具
- 可访问此仓库的 GitHub 账号（仓库目前为私有）

本工程没有第三方包依赖。Xcode 工程为 `DynamicIsland.xcodeproj`，App 的共享 scheme 为 `Dynamic Island`。默认 Debug 构建使用本地运行签名；不需要 Developer ID 证书即可在开发机编译和测试，但产物不能视为正式安装包。

## Xcode

```bash
git clone https://github.com/qyt1340272051-design/DynamicIsland.git
cd DynamicIsland
open DynamicIsland.xcodeproj
```

在 Xcode 中选择 `Dynamic Island` scheme、`My Mac`，按 `Command-B` 编译，按 `Command-R` 运行，按 `Command-U` 测试。应用是菜单栏配件，启动后请在菜单栏或屏幕顶部寻找它，而不是在 Dock 寻找主窗口。

## 命令行

在仓库根目录运行：

```bash
xcodebuild build \
  -project DynamicIsland.xcodeproj \
  -scheme 'Dynamic Island' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/dynamic-island-build

open '/tmp/dynamic-island-build/Build/Products/Debug/Dynamic Island.app'
```

`/tmp/dynamic-island-build` 是示例构建目录，可以换成你自己的路径。需要完整测试、Beta 矩阵校验与 Release 构建时运行：

```bash
./Scripts/ci.sh
```

屏幕/窗口行为专项测试使用 `./Scripts/run-stability-matrix.sh`。生成供预览的模拟屏幕截图使用 `./Scripts/generate-screen-matrix.sh`，结果写入被 Git 忽略的 `artifacts/screen-matrix/`；模拟截图不能替代真机测试。

## 本地打包与正式发布

```bash
./Scripts/release.sh --local
```

本地模式可验证 Archive、DMG、SHA-256 与 manifest 流程，但生成的包没有 Developer ID 签名和 Apple 公证，**不要作为公开下载包分发**。正式发布需要证书私钥、公证凭据、GitHub Actions Secrets 与干净 Mac 的 Gatekeeper 验收；具体步骤见 [发布指南](RELEASING.md)。在这些条件完成前，仓库不会承诺可直接安装的 Release。
