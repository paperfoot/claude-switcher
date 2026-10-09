import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

async function harness({renewDuringSave=false}={}) {
  let now=1_000_000, nextTimer=0, nextRequest=0;
  let blockPing=false, blockSwitch=false, releaseSwitch;
  const timers=new Map(), ports=[], requests=[], alarms=[], cookieListeners=[];
  const actions=[];
  class Switcher {
    async save(){
      actions.push('save');
      await Promise.resolve();
      if(renewDuringSave)for(const f of cookieListeners)f({removed:false,cookie:{name:'sessionKeyV3'}});
      return {ok:true,email:'a@example.com'};
    }
    async status(){return {ok:true,email:'a@example.com',accounts:['a@example.com']};}
    async switchTo(email, activate){
      actions.push('switch');
      if(blockSwitch)await new Promise(resolve=>{releaseSwitch=resolve;});
      if(activate)await activate(email);
      return {ok:true,email};
    }
  }
  const chrome={
    runtime:{
      id:'test',getManifest:()=>({version:'0.7.3'}),
      onMessage:{addListener(){}},onStartup:{addListener(){}},onInstalled:{addListener(){}},
      connectNative(){
        const p={messages:[],disconnects:[],closed:false,
          onMessage:{addListener:f=>p.messages.push(f)},
          onDisconnect:{addListener:f=>p.disconnects.push(f)},
          disconnect(){p.closed=true;for(const f of p.disconnects)f();},
          postMessage(message){
            requests.push({port:p,...message});
            if(message.type==='request' && !(blockPing && message.action==='ping')){
              queueMicrotask(()=>{for(const f of p.messages)f({type:'response',id:message.id,result:{ok:true}});});
            }
          }};
        ports.push(p);return p;
      }
    },
    cookies:{onChanged:{addListener:f=>cookieListeners.push(f)}},
    alarms:{create(){},onAlarm:{addListener:f=>alarms.push(f)}}
  };
  const code=(await readFile(new URL('./background.js',import.meta.url),'utf8')).replace(/^import[^\n]+\n/,'');
  vm.runInNewContext(code,{
    chrome,SessionSwitcher:Switcher,identityFrom:()=>null,claudeCookie:()=>true,browserScopedCookie:()=>false,
    URL,AbortSignal,Date:{now:()=>now},crypto:{randomUUID:()=>String(++nextRequest)},
    setTimeout:(f,ms)=>{const id=++nextTimer;timers.set(id,{f,ms});return id;},
    clearTimeout:id=>timers.delete(id),queueMicrotask,
  });
  const flush=async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
  await flush();
  return {ports,requests,actions,flush,
    advance(ms){now+=ms;},blockPing(value){blockPing=value;},blockSwitch(){blockSwitch=true;},
    releaseSwitch:()=>releaseSwitch(),
    async alarm(){for(const f of alarms)f();await flush();},
    async fireTimeout(ms){for(const [id,timer] of [...timers])if(timer.ms===ms){timers.delete(id);timer.f();}await flush();},
    async command(command){for(const f of ports.at(-1).messages)f({type:'command',id:'cmd',...command});await flush();},
    async cookie(name){for(const f of cookieListeners)f({removed:false,cookie:{name}});await flush();}
  };
}

test('healthy alarm checks the local host without switching or resaving a fresh login',async()=>{
  const h=await harness();const before=h.actions.length;
  await h.alarm();
  assert.equal(h.requests.at(-1).action,'ping');
  assert.equal(h.actions.length,before);
  assert.equal(h.ports.length,1);
});

test('five-minute maintenance saves the current login without switching accounts',async()=>{
  const h=await harness();h.advance(300_000);await h.alarm();
  assert.deepEqual(h.actions,['save','save']);
  await h.command({command:'status'});
  const status=h.requests.at(-1).result;
  assert.equal(status.lastSessionSavedAt,1_300_000);
  assert.equal(status.lastHealthCheckAt,1_300_000);
});

test('a timed-out health check replaces the native connection',async()=>{
  const h=await harness();h.blockPing(true);await h.alarm();
  await h.fireTimeout(5000);
  assert.equal(h.ports.length,2);
  assert.equal(h.ports[0].closed,true);
  assert.equal(h.actions.includes('switch'),false);
  h.blockPing(false);await h.alarm();
  assert.equal(h.requests.at(-1).port,h.ports[1]);
});

test('maintenance does not interrupt an incoming account switch',async()=>{
  const h=await harness();h.blockSwitch();
  await h.command({command:'switch',email:'b@example.com'});
  const before=h.requests.length;await h.alarm();
  assert.equal(h.requests.length,before);
  h.releaseSwitch();await h.flush();
  assert.equal(h.requests.at(-1).result.email,'b@example.com');
});

test('late messages and disconnects from a replaced host leave its replacement intact',async()=>{
  const h=await harness();h.blockPing(true);await h.alarm();await h.fireTimeout(5000);
  const old=h.ports[0];
  h.blockPing(false);await h.alarm();
  for(const f of old.messages)f({type:'command',id:'old',command:'switch',email:'wrong@example.com'});
  old.disconnect();await h.flush();
  assert.equal(h.actions.includes('switch'),false);
  await h.alarm();
  assert.equal(h.ports.length,2);
  assert.equal(h.requests.at(-1).port,h.ports[1]);
});

test('renewed alternate session cookies are saved',async()=>{
  const h=await harness();await h.cookie('sessionKeyV3');await h.fireTimeout(1500);
  assert.deepEqual(h.actions,['save','save']);
});

test('cookie updates during capture do not schedule another capture',async()=>{
  const h=await harness({renewDuringSave:true});
  await h.fireTimeout(1500);
  assert.deepEqual(h.actions,['save']);
  await h.cookie('sessionKeyV3');await h.fireTimeout(1500);
  assert.deepEqual(h.actions,['save','save']);
  await h.fireTimeout(1500);
  assert.deepEqual(h.actions,['save','save']);
});
