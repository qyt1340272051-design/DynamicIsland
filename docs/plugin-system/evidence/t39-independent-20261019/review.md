# 独立 SDK 作者资料走查

执行者：AI 开发代理，按首次读取此 SDK 的路径执行；不是人类首次使用验收。

开始：2026-10-19T06:35:40+00:00（北京时间 2026-10-19 14:35:40）。
离线流程结束：2026-10-19T06:37:57.701879+00:00。
从初读 README 到完成原创插件校验、打包和归档核对的实际耗时：137.7 秒。
此用时不包括 Host 安装、启用、UI 选择或按钮点击，不能推出“十分钟安装验收通过”。

## 流程与结果

1. 只读指定独立 SDK，先读 README.md，再读 docs/quick-start.md。
2. 在 SDK 根运行 `bash docs/quick-start.sh`；原样 Hello 在新的系统临时工作目录生成，validate/package 均退出 0。
3. 按文档目录阅读 Manifest、Activity、Actions、UI Components、Lifecycle、Packaging、Debugging；参考 Hello 的 manifest/index.js/README 和 types/island.d.ts。
4. 在本目录的 status-switch/ 原创编写“双按钮状态”，初始“待选择”，按钮“专注”切换“专注中”，“休息”切换“休息中”；仅内存状态，运行停止后重置。
5. permissions 为 []；只有 activity.publish、activity.update、ui.islandNode、actions.handle 四项 capability。代码仅调用 actions.on 和 activity.publish/update，无存储、网络、链接、倒计时、刷新或系统资源访问。
6. `node --check`、SDK validate-manifest、validate、package 均退出 0。Node v26.0.0 仅用于语法检查，插件运行不需要 Node。未安装 npm 依赖，未做 TypeScript 编译。
7. 打包产物均已用标准库读取 ZIP 成员并计算 SHA-256；未执行 JS、未模拟 Host、未操作 UI、未推送上传、未修改 SDK 或仓库文件。

## 实际错误与歧义

- 读取文档时我自行猜测了 docs/components.md，cat 报 `No such file or directory` 并退出 1。docs/README.md 的真实链接是 ui-components.md，随后正确读取成功。这是我的路径猜测错误，不是 SDK 坏链接。
- README 将 publish/update 返回值简写为“本地 Activity ID”，可能让初读者理解成字符串。Activity 文档与类型明确给出 {id} receipt，足以消除歧义；本插件不依赖该返回值。建议 README 直接写 `{id}`。
- 复制 Hello 后相对类型引用会失效。Quick Start 已明确告知该引用只供编辑器，并要求调整；本插件指向本次独立 SDK 的类型绝对位置对应的相对路径。未构成阻塞。
- 离线 validate 明确不解释 JS。双按钮的注册/声明/节点匹配由作者对照文档完成；语法通过不能证明真实 Host 行为。
- 未遇到生成、SDK 校验或打包失败。无需查阅主 App Swift 源码即可完成此离线开发任务。

## 产物

- 路径：`/var/folders/74/pt17w8td2v593cq_59b3_fr00000gn/T/dynamic-island-hello.8c2e1K/hello-world.dip`
  SHA-256：`d0e94985f688832de8227f524cecb2bef83aef09c50af6ddebf33129d077c976`
  ZIP 成员：README.md, index.js, manifest.json
- 路径：`/tmp/dynamic-island-independent-author-20261019/status-switch-0.1.0.dip`
  SHA-256：`c4a68d98adff6205e9f712feeebab86d610ac5230a128ebd28281d4741e90f0b`
  ZIP 成员：README.md, index.js, manifest.json
