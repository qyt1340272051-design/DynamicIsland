# 实验性类型契约夹具

`official-calls.ts` 独立整理番茄钟与 GitHub 官方示例实际使用的调用形状。`rejected-calls.ts` 的每个 `@ts-expect-error` 都必须产生类型错误；接口意外放宽也会使检查失败。它们是编译期夹具，不应作为插件入口执行。

项目验收环境提供 TypeScript 编译器后，从仓库根运行 `tsc --project SDK/tsconfig.json`。配置也检查原生 JavaScript 的 hello-world 模板，不生成文件，不为插件增加运行依赖。

类型检查覆盖同步生命周期返回、各 Host 方法的 Promise 返回值、可选且不可构造的用户激活票据、Host 倒计时代次、有限 Node、JSON 存储及入站空原型数组。不承诺完整上游兼容、稳定 SDK 或经过人工 UI 验收。数值范围、字节限额、权限、回调注册顺序和展示时机仍须由 Host 与实际运行验证。
