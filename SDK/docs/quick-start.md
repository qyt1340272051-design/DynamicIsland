# Quick Start：第一个计数工具

目标：约十分钟内完成校验、打包、安装和一次点击。这个时间目标尚待新作者实际走查；自动化已覆盖打包和 Host 执行，不能替代首次使用体验。

## 1. 准备

准备支持插件管理的 Dynamic Island 0.6.0 开发版本，以及本 SDK 目录。macOS 上的 Python 3.9+ 用于离线打包。Hello 使用普通 JavaScript，不需要 npm 安装或编译步骤。

在终端进入 SDK 目录（能看到 `tools`、`examples`、`types`）。以下命令复制一份模板到新的临时工作目录，不修改 SDK 内的示例。第一次先保持原样，成功后再改 ID、名称与逻辑。

<!-- sdk-source: quick-start.sh -->
```sh
#!/usr/bin/env bash
set -euo pipefail
# Run from the SDK directory. Each run uses a new workspace.
workspace=$(mktemp -d "${TMPDIR:-/tmp}/dynamic-island-hello.XXXXXX")
cp -R examples/hello-world "$workspace/hello-world"
python3 tools/di_plugin.py validate "$workspace/hello-world"
python3 tools/di_plugin.py package "$workspace/hello-world" "$workspace/hello-world.dip"
printf 'Plugin package: %s\n' "$workspace/hello-world.dip"
```

最后一行给出 `hello-world.dip` 的绝对路径。`workspace` 是本次终端会话的变量；关闭终端后用已打印的绝对路径找回。临时目录可能被系统清理，继续开发前把源目录搬到自己的项目目录。

## 2. 安装并运行

1. 在 Dynamic Island 的「插件管理」点击「导入插件」，选择刚生成的 `.dip`。文件选择器可用 Command–Shift–G 粘贴绝对路径。
2. 预览应显示「你好，计数器」、版本 `0.1.0`、ID `com.example.hello-world`、Native 引擎及无额外权限。点击「安装插件」。
3. 安装后仍为停用状态。回到插件管理选中它，点击「启用插件」。无需授权。
4. 将鼠标移到顶部刘海并保持展开，从工具菜单选择「你好，计数器」。初始文字为「已点击 0 次」，点击「加一」后为「已点击 1 次」。
5. 停用再启用后重新选择工具，计数回到零。这个模板不保存计数；收起会清除工具选择，重新展开后需要再次选择。

启用不会自动展开窗口。模板特意隐藏 compact 状态；没看到常驻图标时，先展开并选择工具。若安装或启动失败，按 [Debugging](debugging.md) 的症状表排查。

## 3. 做第一个修改

源目录有 `manifest.json`、`index.js`、`README.md` 三个文件。把 Manifest 的 `id` 改为自己控制的反向域名标识，至少三段，例如 `com.example.my-counter`；修改显示名称及 developer。复制后脱离 SDK 的相对类型引用只服务编辑器，不参与运行；按新项目路径调整它，或参考 [类型文件](../types/island.d.ts)。

在 `index.js` 的 `presentation` 函数里修改文字。再次校验并打包到一个**尚不存在**的新 `.dip` 路径。不要把输出放进源码目录；已有包不会被覆盖。用导入流程替换自己安装的版本，再启用检查。涉及权限的插件在代码 / Manifest 改动后需要重新确认授权。

完整模板及安装后的预期行为见 [Hello README](../examples/hello-world/README.md)；[Lifecycle](lifecycle.md) 展示相同入口源代码并说明异步初始化。
