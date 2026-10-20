# 你好，计数器（SDK 1.0.0 模板）

这是 SDK 1.0.0 面向 App 0.6.0 插件系统 Native 接口的最小工具示例。`index.js` 是可以直接运行的 JavaScript，无需 TypeScript 编译、npm 安装或构建步骤。类型引用只帮助编辑器检查源码。

- 无需额外权限；只声明发布、更新、节点 UI 和动作四项 capability。
- 提供 minimal、compact、expanded 三种布局。工具等待你在展开后的工具菜单中选择，不请求自动展开。
- 先等待 `actions.on` 成功，再发布包含该动作的 Activity。点击“加一”后更新同一 Activity。
- 次数只保存在当前执行内；停用、休眠恢复或重启后重新从零开始。
- `onStart`、`onStop` 同步返回 `undefined`。初始化 Promise 自行捕获拒绝；动作回调可以返回 Promise。停止时只置标志，清理属于 Host。

## 校验和打包

在 SDK 根目录（能看到 `tools`、`examples`、`types`）执行以下 SDK CLI 命令：

```sh
python3 tools/di_plugin.py validate examples/hello-world
python3 tools/di_plugin.py package examples/hello-world /tmp/hello-world-0.1.0.dip
```

输出文件必须尚不存在。将生成的 `.dip` 通过主程序的“导入插件”安装，再单独启用。安装不会自动运行或授予权限。类型检查是可选开发步骤；SDK 根目录的 `tsconfig.json` 与正反类型夹具由项目验收环境检查，不属于插件运行依赖。

## 修改模板

先更改 `manifest.json` 的反向域名 ID、名称、开发者及版本，再修改文字或计数行为。节点、文字长度和动作声明仍受 Host 校验；类型检查不能授予权限、保证展示时机或替代运行验收。
