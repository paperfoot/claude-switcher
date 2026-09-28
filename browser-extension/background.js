import {SessionSwitcher, identityFrom, claudeCookie} from './session-core.js';
const HOST = 'org.paperfoot.claude_switcher';
let port;
let connectionError = 'Open Claude Switcher to connect';
const requests = new Map();
function native(action, payload={}) {
  if (!port) connect();
  if (!port) return Promise.reject(new Error(connectionError));
  const id = crypto.randomUUID();
  return new Promise((resolve,reject) => {
    const timeout=setTimeout(()=>{requests.delete(id);reject(new Error('Companion did not respond'));},action==='select'?120000:30000);
    requests.set(id,{resolve,reject,timeout});
    port.postMessage({type:'request',id,action,...payload});
  });
}
async function probe() {
  for (const endpoint of ['/api/auth/current_account','/api/bootstrap']) {
    try {
      const response=await fetch('https://claude.ai'+endpoint,{credentials:'include',cache:'no-store',signal:AbortSignal.timeout(8000)});
      if (!response.ok) continue;
      const email=identityFrom(await response.json()); if(email) return email;
    } catch {}
  }
  return null;
}
const browser = {
  cookies:()=>chrome.cookies.getAll({domain:'claude.ai',storeId:'0'}),
  async clear() {
    for(const c of await this.cookies()) {
      if(!claudeCookie(c)) continue;
      const removed=await chrome.cookies.remove({url:`https://${c.domain.replace(/^\./,'')}${c.path||'/'}`,name:c.name,storeId:c.storeId,...(c.partitionKey?{partitionKey:c.partitionKey}:{})});
      if(!removed) throw new Error('Could not clear Claude session');
    }
  },
  set:details=>chrome.cookies.set(details),
  async currentURL() {
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    return tabs.sort((a,b)=>(b.lastAccessed||0)-(a.lastAccessed||0))[0]?.url || 'https://claude.ai/new';
  },
  async openLogin() {
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    if(tabs.length)await chrome.tabs.update(tabs[0].id,{url:'https://claude.ai/login',active:true});
    else await chrome.tabs.create({url:'https://claude.ai/login'});
  },
  async refresh(savedURL) {
    let url='https://claude.ai/new';
    try { const u=new URL(savedURL); if(u.origin==='https://claude.ai' && !/^\/(oauth|logout|login)/.test(u.pathname)) url=u.href; } catch {}
    const tabs=await chrome.tabs.query({url:'https://claude.ai/*'});
    // No new window or focus change; the next visit also inherits the selected session.
    await Promise.all(tabs.map(t=>chrome.tabs.update(t.id,{url}).catch(()=>{})));
  }
};
const vault={
  async get(email){return (await native('vault_get',{email})).entry;},
  async put(entry){await native('vault_put',{entry});},
  async list(){return (await native('vault_list')).accounts||[];}
};
const switcher=new SessionSwitcher(browser,vault,probe);
function connect() {
  if(port) return;
  try {
    const p=chrome.runtime.connectNative(HOST); port=p;
    p.onDisconnect.addListener(()=>{
      connectionError=chrome.runtime.lastError?.message || 'Companion disconnected';
      if(port===p) port=null;
      for(const {reject,timeout} of requests.values()){clearTimeout(timeout);reject(new Error('Companion disconnected'));}
      requests.clear();
    });
    p.onMessage.addListener(async message=>{
      if(message.type==='response'){
        const pending=requests.get(message.id); if(!pending)return;
        requests.delete(message.id);clearTimeout(pending.timeout);
        if(message.result?.ok===false) pending.reject(new Error(message.result.error||'Companion error'));
        else pending.resolve(message.result);
      } else if(message.type==='command'){
        let result;
        try { result=message.command==='switch'?await switcher.switchTo(message.email):await switcher.status(); }
        catch { result={ok:false,error:'web_unavailable'}; }
        if(port===p)p.postMessage({type:'result',id:message.id,result});
      }
    });
    // Initial setup and manual re-logins are captured without another popup click.
    // The native vault only accepts the accounts configured in the menu app.
    void switcher.save().catch(()=>{});
  } catch { port=null; }
}
chrome.runtime.onMessage.addListener((msg,sender,send)=>{
  if(sender.id!==chrome.runtime.id) return false;
  const action=msg?.action;
  const selectBoth=async()=>{
    const previous=await probe();
    const web=await switcher.switchTo(msg.email); if(!web.ok)return web;
    try { return await native('select',{email:msg.email}); }
    catch {
      if(previous) await switcher.switchTo(previous);
      return {ok:false,error:'Code could not switch; the browser switch was undone.'};
    }
  };
  const work=action==='save'?switcher.save():action==='newLogin'?switcher.newLogin():action==='status'?switcher.status():action==='switch'?selectBoth():Promise.reject(new Error('Unknown action'));
  work.then(result=>send(result)).catch(error=>send({ok:false,error:error.message})); return true;
});
let saveTimer;
chrome.cookies.onChanged.addListener(change=>{
  if(change.removed || change.cookie.name!=='sessionKey' || !claudeCookie(change.cookie))return;
  clearTimeout(saveTimer);
  saveTimer=setTimeout(()=>{void switcher.save().catch(()=>{});},1500);
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create('connect',{periodInMinutes:1});
chrome.alarms.onAlarm.addListener(connect);
connect();
