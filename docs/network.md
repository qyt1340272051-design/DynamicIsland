# Network

使用 `island.network.fetch`，声明并单独批准 `network` permission；没有对应的 network capability。当前默认目标仅 `https://api.github.com`，方法仅 GET / HEAD，不开放浏览器全局 fetch、WebSocket 或原始 socket。Host 会检查目标、解析地址与跳转，不能用 URL 或重定向绕过政策。

返回对象有 status、ok、headers、异步 text() / json()。HTTP 非 2xx 仍应检查 ok；JSON 可解析不表示业务结构正确。下例只执行一次读取，调用者必须捕获拒绝并安排自己的有限重试。它不是完整插件，需放入自己的入口并配上网络权限：

<!-- sdk-source: snippets/network.js -->
```js
/// <reference path="../../types/island.d.ts" />
'use strict';

/** @returns {Promise<number>} */
function readGitHubStars() {
    return island.network.fetch('https://api.github.com/repos/cli/cli', {
        method: 'GET', headers: {Accept: 'application/vnd.github+json'}, timeoutMs: 10000
    }).then(response => {
        if (!response.ok) throw {code: 'httpStatus', message: 'GitHub returned an unsuccessful status.'};
        return response.json();
    }).then(value => {
        if (value === null || typeof value !== 'object' || Array.isArray(value)) {
            throw {code: 'invalidData', message: 'Expected a repository record.'};
        }
        const record = /** @type {DynamicIsland.HostJSONObject} */ (value);
        const stars = record.stargazers_count;
        if (typeof stars !== 'number' || !Number.isSafeInteger(stars) || stars < 0) {
            throw {code: 'invalidData', message: 'Expected a nonnegative star count.'};
        }
        return stars;
    });
}
```

超时默认 10,000ms，可选整数 100…30,000ms。响应最多 65,536 bytes；一个插件最多两个在途请求、全局最多八个。json() 还受桥接 JSON 的深度 / 节点限制，不能靠请求一个大列表再只取第一条来规避响应上限。

不要将密钥写进包、设置样例或诊断消息。本草案示例只访问公开数据。生产插件需要合并重复请求、让旧仓库响应失效、处理离线与 API 限流；收到 403 / 429 时结合服务端等待信息退避，手动刷新也应遵守等待期。

重复获取应使用 Host 的 `scheduler.requestRefresh(delayMs)`，它是到期后才 resolve 的一次性请求；每次执行最多一个 pending 请求，整数 delay 为 1,000…86,400,000ms。后台、低电量、睡眠可能延后实际时间，不能用它实现精确时钟或无间隔重试。官方 GitHub 示例包含完整的去重、退避与仓库切换处理；本页仅展示单次请求和业务字段校验。
