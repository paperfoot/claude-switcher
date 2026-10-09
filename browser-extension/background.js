import {SessionSwitcher, identityFrom, claudeCookie, browserScopedCookie} from './session-core.js';
const HOST = 'org.paperfoot.claude_switcher';
let port;
let connectionError = 'Open Claude Switcher to connect';
let popupSwitchInProgress = false;
let incomingCommands = 0;
let healthCheckRunning = false;
let lastHealthCheckAt = 0;
let lastSessionSavedAt = 0;
let sessionSaveInFlight = null;
let probesInFlight = 0;
const requests = new Map();
function native(action, payload={}, timeoutMs=action==='select'?120000:30000) {
  if (!port) connect();
  if (!port) return Promise.reject(new Error(connectionError));
  const id = crypto.randomUUID();
  return new Promise((resolve,reject) => {
    const timeout=setTimeout(()=>{requests.delete(id);reject(new Error('Companion did not respond'));},timeoutMs);
    requests.set(id,{resolve,reject,timeout});
    try {port.postMessage({type:'request',id,action,...payload});}
    catch {clearTimeout(timeout);requests.delete(id);reject(new Error('Companion disconnected'));}
  });
}
async function probe() {
  probesInFlight++;
  try {
  let diagnostic = {probeStatus:'invalid_response'};
  for (const endpoint of ['/api/bootstrap','/api/auth/current_account']) {
    try {
      const response=await fetch('https://claude.ai'+endpoint,{credentials:'include',cache:'no-store',signal:AbortSignal.timeout(8000)});
      if (!response.ok) {
        // Keep the bootstrap failure; a missing legacy endpoint is not a login failure.
        if(response.status!==404) diagnostic={httpStatus:response.status,probeStatus:response.status===401?'unauthorized':response.status===403?'forbidden':response.status===429?'rate_limited':'server_error'};
        continue;
      }
      const email=identityFrom(await response.json());
      if(email) {probe.diagnostic={probeStatus:'verified',httpStatus:response.status}; return email;}
    } catch { if(!diagnostic.httpStatus) diagnostic={probeStatus:'network_error'}; }
  }
  probe.diagnostic=diagnostic;
  report({error:'web_unavailable',failureStep:'verify_identity',...diagnostic});
  return null;
  } finally {probesInFlight--;}
}
function report(details) {
  if(port) void native('diagnostic',{details},5000).catch(()=>{});
}
const browser = {
  cookies:()=>chrome.cookies.getAll({domain:'claude.ai',storeId:'0'}),
  async clear() {
    for(const c of await this.cookies()) {
      if(!claudeCookie(c) || browserScopedCookie(c)) continue;
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
async function saveCurrentSession() {
  if(sessionSaveInFlight)return sessionSaveInFlight;
  sessionSaveInFlight=switcher.save();
  try {
    const result=await sessionSaveInFlight;
    lastSessionSavedAt=Date.now();
    return result;
  } catch(error) {
    report({error:'session_save_failed',failureStep:'save_session',...probe.diagnostic});
    throw error;
  } finally {sessionSaveInFlight=null;}
}
async function maintainConnection() {
  if(healthCheckRunning || popupSwitchInProgress || incomingCommands || requests.size)return;
  healthCheckRunning=true;
  const previous=port;
  try {
    await native('ping',{},5000);
    lastHealthCheckAt=Date.now();
    if(Date.now()-lastSessionSavedAt>=5*60*1000)await saveCurrentSession().catch(()=>{});
  } catch {
    if(port===previous && previous && !popupSwitchInProgress && !incomingCommands && !requests.size) {
      port=null;
      previous.disconnect();
      connect();
    }
  } finally {healthCheckRunning=false;}
}
function connect() {
  if(port) return;
  try {
    const p=chrome.runtime.connectNative(HOST); port=p;
    p.onDisconnect.addListener(()=>{
      if(port!==p)return;
      connectionError=chrome.runtime.lastError?.message || 'Companion disconnected';
      port=null;
      for(const {reject,timeout} of requests.values()){clearTimeout(timeout);reject(new Error('Companion disconnected'));}
      requests.clear();
    });
    p.onMessage.addListener(async message=>{
      if(port!==p)return;
      if(message.type==='response'){
        const pending=requests.get(message.id); if(!pending)return;
        requests.delete(message.id);clearTimeout(pending.timeout);
        if(message.result?.ok===false && !message.result.partial) pending.reject(new Error(message.result.error||'Companion error'));
        else pending.resolve(message.result);
      } else if(message.type==='command'){
        incomingCommands++;
        let result;
        try {
          result=message.command==='switch'
            ? popupSwitchInProgress ? {ok:false,error:'switch_in_progress'} : await switcher.switchTo(message.email,null,message.expiresAt)
            : {...await switcher.status(),version:chrome.runtime.getManifest().version,lastHealthCheckAt,lastSessionSavedAt};
        }
        catch { result={ok:false,error:'web_unavailable'}; }
        finally {incomingCommands--;}
        if(result.ok===false)report(result);
        if(message.command==='switch' && result.ok)void saveCurrentSession().catch(()=>{});
        if(port===p)p.postMessage({type:'result',id:message.id,result});
      }
    });
    // Initial setup and manual re-logins are captured without another popup click.
    // The native vault only accepts the accounts configured in the menu app.
    void (async()=>{
      await saveCurrentSession().catch(()=>{});
      // A selection made while Chrome was closed takes effect when Chrome reconnects.
      const pending=await native('pending_selection');
      if(pending.email) {
        const result=await switcher.switchTo(pending.email);
        if(result.ok)await native('browser_ready',{email:pending.email});
      }
    })().catch(()=>{});
  } catch { port=null; }
}
chrome.runtime.onMessage.addListener((msg,sender,send)=>{
  if(sender.id!==chrome.runtime.id) return false;
  const action=msg?.action;
  const selectBoth=async()=>{
    if(popupSwitchInProgress)return {ok:false,error:'switch_in_progress'};
    popupSwitchInProgress=true;
    try{
      const result=await switcher.switchTo(msg.email,email=>native('select',{email}));
      if(result.ok===false)report(result);
      if(result.ok || result.partial)void saveCurrentSession().catch(()=>{});
      return result;
    }
    finally{popupSwitchInProgress=false;}
  };
  const work=action==='save'?saveCurrentSession():action==='newLogin'?switcher.newLogin():action==='status'?switcher.status():action==='switch'?selectBoth():Promise.reject(new Error('Unknown action'));
  work.then(result=>send(result)).catch(error=>send({ok:false,error:error.message})); return true;
});
let saveTimer;
chrome.cookies.onChanged.addListener(change=>{
  if(change.removed || !['sessionKey','sessionKeyLC','sessionKeyV3','sessionKeyV3LC'].includes(change.cookie.name) || !claudeCookie(change.cookie))return;
  // Bootstrap can renew cookies itself. Do not turn verification into another save loop.
  if(sessionSaveInFlight || probesInFlight || incomingCommands || popupSwitchInProgress)return;
  clearTimeout(saveTimer);
  saveTimer=setTimeout(()=>{void saveCurrentSession().catch(()=>{});},1500);
});
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create('connect',{periodInMinutes:1});
chrome.alarms.onAlarm.addListener(()=>{void maintainConnection();});
connect();
