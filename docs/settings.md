# Settings

当前 Native SDK 没有 `island.settings` API，也没有可加入 Manifest 的 settings 字段。业务设置通过插件工具里的按钮与普通 Storage 实现；Host 的插件管理负责启用、权限和卸载，不会自动生成业务表单。

下面的函数只读写四种分钟预设。schemaVersion 是**插件自己的数据版本**，和 Manifest schemaVersion 各自独立。loadMinutes 遇到缺失、非法值、未知字段或读取失败时返回默认 25；不会写回覆盖旧数据。saveMinutes 只有成功提交才返回 true；调用者据此显示“已保存”或“未保存”。需要 capability / permission `storage.local`：

<!-- sdk-source: snippets/settings.js -->
```js
/// <reference path="../../types/island.d.ts" />
'use strict';

/**
 * Storage is untrusted data. Accept only this version's exact shape.
 * @param {DynamicIsland.HostJSONValue} value
 * @returns {15 | 25 | 45 | 60}
 */
function parseMinutes(value) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return 25;
    const keys = Object.keys(value);
    if (keys.length !== 2 || !keys.includes('schemaVersion') || !keys.includes('minutes')) return 25;
    const record = /** @type {DynamicIsland.HostJSONObject} */ (value);
    if (record.schemaVersion !== 1) return 25;
    const minutes = record.minutes;
    return minutes === 15 || minutes === 25 || minutes === 45 || minutes === 60 ? minutes : 25;
}

/** @returns {Promise<15 | 25 | 45 | 60>} */
function loadMinutes() {
    return island.storage.get('preferences').then(parseMinutes, () => /** @type {25} */ (25));
}

/** @param {15 | 25 | 45 | 60} minutes @returns {Promise<boolean>} */
function saveMinutes(minutes) {
    // TypeScript types do not replace validation of runtime input.
    if (minutes !== 15 && minutes !== 25 && minutes !== 45 && minutes !== 60) return Promise.resolve(false);
    return island.storage.set('preferences', {schemaVersion: 1, minutes: minutes})
        .then(() => true, () => false);
}
```

将用户选择保持在内存中，写入失败也不回滚正常的本轮操作。启动异步读取可能晚于用户点击；合并到界面前检查本次执行是否仍有效、用户修改代次是否改变。不要让晚到的启动读取覆盖用户刚刚选择的值。多个保存操作需串行或合并，以上函数没有代替业务层实现写队列。

记录“上次运行中”只能用于提示，不能当作重新启动或继续计时的授权。倒计时是否存在由当前 Host countdown record 决定。官方 Pomodoro 的设置恢复和写队列、GitHub 的仓库切换都遵守这一规则。
