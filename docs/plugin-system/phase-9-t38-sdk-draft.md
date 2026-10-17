# T38 子步骤：实验性 SDK 作者工具

日期：2026-10-17。按[用户人工验收延期安排](PROGRESS.md)先完成可自动推进的开发。T38 的 T36 前置及 T35 的实际完成提示仍待验收；本轮只提交实验草案，**没有发布稳定 SDK**，T38 保持 `in progress`。

## 产物和使用

[SDK README](../../SDK/README.md) 提供无需阅读 Swift 源码的起步路径、API 子集、调用和生命周期说明、离线校验命令及安装流程；[版本草案](../../SDK/VERSIONING.md) 分别定义 SDK 工作版本、Manifest generation、wire API 和 minimumHostVersion。没有把当前 API 标识 `1.0.0` 解释成 SDK 已稳定。

- 类型只覆盖两官方包实际使用的 log / activity / actions.on / storage.get,set / scheduler / countdown / network / links，节点限于八类。未公开其他资源接口、SI 私有桥接或四个未使用方法。
- hook 类型要求同步返回 undefined；activation 和 generation 使用无构造器的不透明品牌。入站 JSON 数组仅承诺 length 和数字索引，不错误承诺原型方法。47 项预期类型错误覆盖 async hook、伪造票据、不存在的 namespace、错误数据和未公开方法。
- [Hello 模板](../../SDK/examples/hello-world/README.md) 是无额外权限的计数工具：先注册，再发布三种布局；由用户选择工具，不请求展开。停止后 Host 清理旧执行，重启计数归零。
- Python 3.9+ 标准库 CLI 提供 validate-manifest / validate-node / validate / package。Schema 是编辑器辅助；CLI 额外检查重复键、字节、非有限数值和聚合树上限。它不解释 JavaScript，也不授予运行资格。
- Manifest Schema 是现有 Host Schema 的精确离线副本，自动测试阻止漂移。Node Schema 明确比 Host 窄，只包含官方使用的八类；完整闭集声明不等于全部 SDK API 已验收。
- `.dip` 打包器移到 SDK 内作为唯一实现；原 Scripts/package-plugin.py 保留命令兼容 wrapper。打包输出不覆盖已有文件，拒绝链接和路径冲突，并核对扫描后读取的文件身份；正式 Installer 仍独立校验。

SDK 目录可独立复制使用，打包和校验不依赖仓库其他文件。官方 Pomodoro / GitHub 保留原位置，避免复制漂移。类型编译器是锁定的开发依赖，插件运行不需要 npm；没有上传任何包或条目。

## 验证

[证据](evidence/t38-sdk-draft-20261017/result.json)记录：

- Python **33 项通过、0 跳过、0 失败**，包含无执行的 CLI、包限额、链接替换、旧入口兼容、SDK 脱仓库工具运行和确定性归档。
- 共享 **12 个 Manifest / 18 个 Node** 案例分别通过 Python 工具和正式 Swift Decoder / Converter，覆盖 UTF-8、严格类型、重复字段、未知字段、UUID、8 / 9 层与 128 / 129 节点。
- TypeScript 4.5.5 的正例及 **47 项预期错误**通过；npm ci 使用 lockfile 安装后再次检查通过。
- 正式 Host 解包实际 SDK 生成的 `.dip`，完整 Validator 加载入口快照；真实 VM / ActionRouter 完成 0→1、停用、旧按钮拒绝、重启归零和新实例再更新。模板不强制前台展示。
- 综合定向 **91 passed / 0 skipped / 0 failures**；完整 CI **1035 total / 1028 passed / 7 skipped / 0 failures**。普通 Release 构建与 strict / deep 签名核验结果随证据归档。CI 已接入离线工具、类型和文档模板检查。

7 项跳过分别为锁屏的 5 项真实 AppKit 输入、显式截图矩阵及默认关闭的 live GitHub 网络；定向运行时管理 / 安装两项真实输入另已通过。该差异保留环境边界，不把全套跳过算成通过。T35 / T36 实机验收、稳定发布和完整 T39 文档验收均不由本轮自动结果代替。

## 继续位置

T38 的稳定发布与整体完成仍等待两个官方插件的实际验收及依赖复核。本草案的工具、类型、模板和版本策略可供审查；T39 全套开发文档与十分钟首次安装验收、T40 Registry 均未开始。本轮不扩展服务端、签名生态或自动更新。
