# 原生输入与 OCR 回归诊断

2026-10-19。首次完整运行共有七个失败 case，其中新增 T11 fixture 由对应任务单独修复；本目录处理其余六个旧 case，保留原完整运行的失败结论，不将定向结果改写为完整 CI 通过。

四个原生输入 case 都在 `window.isKeyWindow` 前置等待失败，尚未发送业务按钮事件。最早的 Quit 失败发生在新增 T11 窗口测试之前，不能归因为该窗口泄漏。测试 helper 现仅在 key 等待失败时输出 `NATIVE_KEY_WINDOW_TIMEOUT` JSON，包含实际可见性、key 能力、当前 Space、比例、modal 与系统报告的会话状态；原断言与错误保留，没有更改产品激活逻辑或猜测全屏 / 锁屏原因。

另外两个 case 的实际像素中 `JavaScriptCore` 与「查看诊断」完整可见，但 Vision 改变了大小写或误识别一个汉字。旧兼容图是 1640×106，本次初始图为 820×53，说明依赖当前屏幕比例的缓存图发生了变化。现在从真实 NSView 直接以固定 2× 位图缓存显示，截图与 OCR 都使用同一渲染方式；完整、精确的文字断言继续保留。没有拼接、重画或修改已有截图。最初 PNG 在工具图像中已观察，测试仍使用原临时文件名，故不声称本目录保存了最初失败时的 PNG 字节。

新 runner 的六项定向运行全部通过：**6 passed / 0 skipped / 0 failures**，`xcodebuild` 返回 0。该次没有触发 key 超时诊断，因此只能说明原生 key 失败没有在这次重现，不能据此认定之前发生锁屏、全屏干扰或产品缺陷。

- [原完整运行摘要](initial-full-ci-summary.json)
- [六项定向摘要](native-six-summary.json)
- [结果、日志摘要及测试源码身份](result.json)
- [六张原始 2× PNG 清单与哈希](screenshots.json)

定向命令使用 `xcodebuild test`、scheme `Dynamic Island`、`platform=macOS`、关闭并行测试，选择 Quit 动画中取消、兼容详情、管理按钮、管理页像素、安装按钮及 Registry 下载安装六个原失败方法。原始日志和 `.xcresult` 路径保留在结果 JSON；后续完整 CI 是独立门槛。

## 第二次完整运行发现的独立 OCR 卡点

第二次完整运行的旧六项没有再失败，但安装器最小预览中的 `SuperIsland` 被识别为 `Superisland` / `Superlsland`，精确断言失败；更大预览中的同一名字识别成功。实际最小预览的品牌文字完整可见，原失败材料由主代理保存在 [second-full-failure](second-full-failure)。本次没有修改产品标签、字体或窗口尺寸。

在现有固定 2× 与多候选识别基础上，只对已经检测到含 Latin 字母的原像素行增加英文单语、关闭语言纠正的复识别，附加它实际返回的候选，精确文字断言保持不变。没有模糊匹配、按预期词替换字符串或启用 3× 重采。

[三项精确 OCR 定向](ocr-followup/result.json)为 **3 passed / 0 skipped / 0 failures**，覆盖安装预览新卡点以及先前的管理页、兼容详情，最小预览已得到精确 `SuperIsland`。四张本轮原始 PNG 及摘要见 [ocr-followup/screenshots.json](ocr-followup/screenshots.json)。它仍是独立定向结果，不覆盖或改写两次完整失败运行；主代理后续完整 CI 单独记录。
