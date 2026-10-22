# main 精确提交 CI 补验

归档日期：2026-10-22（Asia/Shanghai）。实际运行于 2026-10-21 本地时间 23:38–23:44，具体时间与结果见 [result.json](result.json)。

- [GitHub CI run 39627546396](https://github.com/qyt1340272051-design/DynamicIsland/actions/runs/39627546396) 已成功完成。
- 精确源码为 main 提交 `3ce61ecb73d7b07ae6525180af4901ab656dc69f`。
- 事件为 **`workflow_dispatch`**；仅启动一次，attempt 1，未重跑该工作流。
- XCTest：**1092 total / 1087 passed / 5 skipped / 0 failures**；普通 Release 构建通过。
- 五项跳过为需显式开启的真实 GitHub、真实 Registry、截图矩阵选测，以及 runner 开启 Reduce Motion 时不适用的两项动画退出测试。

启动前已确认 main 指向上述提交，且该提交没有现存 CI 运行。此次使用仓库既有 CI 工作流主动补验；工作流配置和源码未在补验过程中修改。本记录不表示缺失的自动 push 事件原因已查明或解决，也不将本次运行记为 push 触发。

结果文件仅提取公开运行身份、时间、检查统计和来源摘要，未归档账户凭据、原始环境输出或本机路径。核验范围为该精确提交的远端自动 CI，不关闭 T39 新作者、硬件 Beta 场景或干净 Mac 安装门槛。
