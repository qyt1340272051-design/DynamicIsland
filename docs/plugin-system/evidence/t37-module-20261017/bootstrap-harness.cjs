const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const native = fs.readFileSync('/tmp/dynamic-island-t37-module-20261017/native-bootstrap.js','utf8');
const adapter = fs.readFileSync('/tmp/dynamic-island-t37-module-20261017/module-bootstrap.js','utf8');
function setup(source, rejectRender = false) {
  const requests = [], registered = new Map();
  let receivers;
  const sandbox = {__native(id,json) {
    const request = JSON.parse(json); requests.push(request);
    if(request.method==='actions.on') registered.set(request.params.actionID,request.params.registrationID);
    if(request.method==='actions.off') registered.delete(request.params.actionID);
    let response = {ok:true,value:null};
    if(request.method==='superisland.render') response = (typeof rejectRender === 'function' ? rejectRender(request) : rejectRender) ? {ok:false,error:{code:'invalidArguments',message:'Invalid'}} : {ok:true,value:{limitations:['hostTextTypography']}};
    setImmediate(()=>receivers.receiveResponse(id,JSON.stringify(response)));
  }};
  const context = vm.createContext(sandbox);
  receivers = vm.runInContext(native,context);
  const install = vm.runInContext(adapter,context);
  const lifecycle = install(receivers.superIslandBridge);
  vm.runInContext(source,context);
  return {context,receivers,lifecycle,requests,registered};
}
async function settle(){for(let i=0;i<20;i++) await new Promise(setImmediate);}
(async()=>{
  const a=setup(`
    globalThis.calls=0; globalThis.deactivations=0; globalThis.count=0;
    SuperIsland.registerModule({
      onActivate(){calls++}, onDeactivate(){deactivations++},
      compact(){return View.text('Count '+count)},
      expanded(){return View.vstack([View.text('Count '+count),View.button(View.text('Add'),'add')])},
      onAction(id){if(arguments.length!==1||id!=='add')throw 1;count++}
    });
  `);
  a.lifecycle.start(); await settle();
  assert.equal(a.requests.filter(x=>x.method==='superisland.render').length,1);
  assert.equal(a.requests[0].method,'actions.on');
  a.receivers.receiveAction(a.registered.get('add'),JSON.stringify({activityID:'superisland-module',actionID:'add',value:{type:'none'},activation:'private'}));
  await settle();
  assert.equal(vm.runInContext('count',a.context),1);
  assert.equal(a.requests.filter(x=>x.method==='superisland.render').at(-1).params.compact.value,'Count 1');
  assert.equal(vm.runInContext('calls',a.context),1);
  a.lifecycle.stop();a.lifecycle.stop();
  assert.equal(vm.runInContext('deactivations',a.context),1);
  const b=setup(`
    globalThis.thenReads=0;
    SuperIsland.registerModule({compact(){return View.text('Safe')},expanded(){return View.button(View.text('Go'),'go')},onAction(){}});
    Object.defineProperty(Promise.prototype,'then',{get(){thenReads++;throw 1}});
    Object.defineProperty(Object.prototype,'then',{get(){thenReads++;throw 1}});
    Promise.prototype.constructor={get [Symbol.species](){throw 2}};
    Reflect.apply=()=>{throw 3}; Object.getOwnPropertyDescriptor=()=>{throw 4};
  `);
  b.lifecycle.start();await settle();
  assert.equal(b.requests.filter(x=>x.method==='superisland.render').length,1);
  assert.equal(vm.runInContext('thenReads',b.context),0);
  const c=setup(`SuperIsland.registerModule({compact(){return View.text('Bad')}})`,true);
  c.lifecycle.start();await settle();
  assert.equal(c.requests.filter(x=>x.method==='superisland.failure').length,1);
  const d=setup(`SuperIsland.registerModule({compact(){return View.text('Fallback')}})`);
  d.lifecycle.start();await settle();
  const render=d.requests.find(x=>x.method==='superisland.render');
  assert.deepEqual(render.params.compact,render.params.expanded);
  assert.throws(()=>vm.runInContext(`SuperIsland.island.activate()`,d.context),e=>e.code==='unsupportedMethod');
  const e=setup(`SuperIsland.registerModule({compact(){return Object.defineProperty({type:'text'},'value',{get(){globalThis.getterRead=true;return 'bad'}})}})`);
  assert.throws(()=>e.lifecycle.start());
  assert.equal(vm.runInContext('typeof getterRead',e.context),'undefined');
  const transaction=setup(`
    globalThis.attempts=0;
    SuperIsland.registerModule({
      compact(){return View.text(attempts===1?'Bad':'Good')},
      expanded(){return View.button(View.text('Tap'),attempts===1?'B':'A')},
      onAction(){attempts++}
    });
  `, request=>request.params.compact.value==='Bad');
  transaction.lifecycle.start();await settle();
  transaction.receivers.receiveAction(transaction.registered.get('A'),JSON.stringify({actionID:'A',value:{type:'none'}}));
  await settle();
  assert(transaction.registered.has('A'));
  assert(!transaction.registered.has('B'));
  transaction.receivers.receiveAction(transaction.registered.get('A'),JSON.stringify({actionID:'A',value:{type:'none'}}));
  await settle();
  assert.equal(vm.runInContext('attempts',transaction.context),2);
  assert.equal(transaction.requests.filter(x=>x.method==='superisland.render').at(-1).params.compact.value,'Good');
  assert.equal(transaction.requests.filter(x=>x.method==='superisland.failure').length,1);
  assert.equal(transaction.requests.filter(x=>x.method==='actions.on'&&x.params.actionID==='A').length,1);
  console.log(JSON.stringify({passed:['start/register/render/action/stop','captured primordials and poisoned then getters','single fixed render-failure report','expanded fallback','unsupported controls','accessor refusal','failed replacement rolls back new IDs and preserves old callback'],count:7}));
})().catch(error=>{console.error(error);process.exitCode=1});
