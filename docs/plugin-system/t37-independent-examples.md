# T37：独立编写的兼容子集示例

日期：2026-10-19。用户已明确选择「交付兼容子集，用独立编写的简单插件完成实机验收」。本轮按这一范围完成验收，不再将原样上游插件作为本版 T37 的必达条件；[上游审计](t37-upstream-acceptance-audit.md)中的许可和 API 缺口作为兼容限制保留，不声称它们已解决。

三个包均使用 SuperIsland.registerModule 与 View 协议，不使用原生 island API。由本项目独立编写，附带本项目 MIT 许可；未复制上游入口或实现。

| 示例 | 覆盖 | 实际行为 |
| --- | --- | --- |
| [状态](examples/superisland-status/README.md) | text、icon、hstack、vstack、button | 就绪 / 暂停切换 |
| [计数](examples/superisland-counter/README.md) | 同一模块更新、两个按钮、重启清零 | 加一 / 归零，上限 9999 |
| [进度](examples/superisland-progress/README.md) | progress、四个按钮、activate / dismiss 意图 | 手动 0…4 步，Host 决定是否展示 |

共同声明严格 DynamicIsland V1 Manifest 外壳与 engine=superisland。没有系统权限、外部请求、后台定时器或持久写入。progress 包额外声明 presentation.request，其他包没有这项能力。

验收要求：实际打包导入后保持停用、显示有限兼容；逐个启用并选择工具，核对文字、按钮和进度；三个包共用 increment 动作名，操作互不串线；停用使旧动作失效，重启回到初值；Host 拒绝越权展示，重要事件仍能抢占。自动契约和真实 UI 记录分开归档。

本轮已完成真实源码的 Validator / VM / Bridge / ActivityManager / Router 集成，覆盖共享动作名隔离、同实例更新、停用旧动作、重新启用重置、展示请求及 critical 抢占；[完整回归](evidence/final-regression-20261019/result.json)为 1070 passed / 2 skipped / 0 failures，普通 Release 构建通过。

三个兼容包已在普通 Release 隔离副本实际导入，逐个确认安装后停用、有限兼容说明及明确启用，见[安装证据](evidence/final-app-install-20261019/result.json)。同一副本另装入计时三态验收与独立 AI 原创工具，共五个无额外权限包。用户最新要求先跳过人工操作，因此真实刘海工具选择、按钮与进度像素保留在[人工清单 M03](MANUAL_ACCEPTANCE.md)；没有把自动 Router 调用写成真实鼠标点击。

副本已正常退出，Staging 为空、五包与启用状态保留；下次重新启动后核对身份再继续，不沿用历史 PID。
