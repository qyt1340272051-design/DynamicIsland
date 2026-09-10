# 参与开发

感谢你帮助改进 Dynamic Island。提交前请先搜索现有 Issue，确认问题或提案没有重复。

## 开发环境

- macOS 26.0 或更高版本
- Xcode 26.6
- 当前工作从 `main` 派生到独立分支

```bash
git clone https://github.com/qyt1340272051-design/DynamicIsland.git
cd DynamicIsland
open DynamicIsland.xcodeproj
```

## 提交要求

1. 保持改动聚焦，不混入无关格式化或重构。
2. 新行为需要添加与风险相称的测试。
3. UI 改动需要检查紧凑、展开和拖拽状态，并在 PR 中附截图。
4. 涉及屏幕定位时，需要覆盖有刘海、无刘海、外接显示器和缩放差异。
5. 新增系统能力时，需要说明权限、沙盒 entitlement 和拒绝权限后的行为。

## 本地验证

完整验证命令与 CI 保持一致：

```bash
./Scripts/ci.sh
```

屏幕或窗口策略相关改动还应运行：

```bash
./Scripts/run-stability-matrix.sh
./Scripts/generate-screen-matrix.sh
```

Beta 真机验收请按 [Beta 验收手册](docs/BETA_TESTING.md) 选择 `DI-B01`–`DI-B09` 场景，从菜单栏复制脱敏调试信息，并通过 Beta Issue 模板提交结果。

## Pull Request

PR 描述应说明变更目的、用户可见行为、验证结果和已知风险。GitHub Actions 中的 `Test and build` 检查必须通过后才能合并。

请不要提交 `DerivedData`、测试结果包、签名证书、密钥、临时文件托盘内容或自动生成的完整屏幕矩阵。
