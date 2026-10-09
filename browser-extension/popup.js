const message=document.querySelector('#message');
const errors={web_login_needed:'Sign in to this account once. It will be saved automatically.',web_login_expired:'This login expired. Sign in once to reconnect.',web_switch_failed:'Could not switch Chrome. Your previous login was restored.',code_switch_failed:'Code could not switch. Your Chrome login is unchanged.',code_only_after_web_failure:'Code switched. Another Chrome profile could not switch.',web_restore_failed:'Chrome needs a fresh sign-in.',browser_missing:'Chrome companion is not connected.',switch_in_progress:'Another switch is finishing. Try again.'};
async function run(action,extra={}) {
 document.querySelectorAll('button').forEach(b=>b.disabled=true);
 try {const r=await chrome.runtime.sendMessage({action,...extra}); if(!r?.ok)throw new Error(errors[r?.error]||r?.error||'Could not connect'); return r;}
 finally{document.querySelectorAll('button').forEach(b=>b.disabled=false);}
}
async function refresh(){
 try {const r=await run('status');const list=document.querySelector('#accounts');list.replaceChildren();
 for(const email of r.accounts){const b=document.createElement('button');b.textContent=(r.email===email?'✓  ':'')+email;b.onclick=async()=>{try{message.textContent='Switching…';const result=await run('switch',{email});message.textContent=result.message||'Switched';await refresh();}catch(e){message.textContent=e.message;}};list.append(b);}
 message.textContent=r.email?`Chrome: ${r.email}`:'Sign in to Claude.ai, then save this login.';
 }catch(e){message.textContent=e.message;}
}
document.querySelector('#add').onclick=async()=>{try{await run('newLogin');message.textContent='Choose the next account on Claude.ai. It will be saved automatically.';}catch(e){message.textContent=e.message;}};
document.querySelector('#save').onclick=async()=>{try{await run('save');await refresh();}catch(e){message.textContent=e.message;}};
refresh();
