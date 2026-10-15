'use strict';

let count = 0;

function presentation() {
    return {
        role: 'tool', title: '工具选择示例', symbolName: 'hand.tap.fill', showsCompact: false,
        expanded: {type: 'vStack', children: [
            {type: 'text', content: '已点击 ' + String(count) + ' 次'},
            {type: 'button', actionID: 'increment', label: {type: 'text', content: '增加一次'},
                accessibilityLabel: '增加一次'}
        ]}
    };
}

function onStart() {
    island.actions.on('increment', event => {
        if (event.activityID !== 'counter' || event.value.type !== 'none') return;
        count += 1;
        return island.activity.update({id: 'counter', presentation: presentation()});
    }).then(() => island.activity.publish({
        id: 'counter', lifecycle: {policy: 'persistent'}, presentation: presentation(),
        actions: [{id: 'increment', title: '增加一次'}]
    })).catch(() => { island.log('Tool demo initialization failed', 'error').catch(() => {}); });
}

function onStop() {}
