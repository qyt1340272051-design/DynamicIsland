# 本轮完整回归

2026-10-19。`Scripts/ci.sh` 最终完整运行 **1072 total / 1070 passed / 2 skipped / 0 failures**，普通 Release build passed。两项默认关闭的选测是截图矩阵和真实 GitHub API；所有本轮原生输入均在完整运行中通过，没有将其他定向结果加到本次计数。

结构化信息见 [result.json](result.json)、原始 Xcode 摘要见 [summary.json](summary.json)。测试在 `eaa2bc3` 之后本轮未提交工作区执行；生产源码与普通 Release 文件身份已保存，不能只写成裸 `eaa2bc3` 的结果。

前两次完整运行的失败、T11 测试准备修正、原生输入定向与同像素 OCR 修正分别保留在 [T10 / T11](../../t10-t11-acceptance-20261019.md)和[界面回归证据](../native-ui-regression-20261019/README.md)。未修改产品来迎合 OCR，没有放宽精确文字断言，也没有将失败重写成通过。

完整回归不自动关闭真实计时三态、兼容工具按钮、菜单开关、独立作者及公开 Registry 的人工 / 外部门槛。
