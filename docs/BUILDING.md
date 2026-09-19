# 编译说明

## 环境

- macOS 26.0 或更高版本
- Xcode 26.6，使用其中的 macOS SDK 和命令行工具
- 可访问公开 GitHub 仓库的网络连接

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

## 本地打包与测试预发布

```bash
./Scripts/release.sh --local
```

本地模式生成双架构 ad hoc 签名的 Archive、DMG、SHA-256 与 manifest。该 DMG 可以明确标为“未公证测试包”上传 GitHub 预发布；没有 Developer ID 签名和 Apple 公证，macOS 首次运行可能要求在“系统设置 > 隐私与安全性 > 仍要打开”手动放行。不能承诺双击即启动，也不能将它称为正式签名公证安装包。Tag 自动发布和测试者安装步骤见 [发布指南](RELEASING.md)。
