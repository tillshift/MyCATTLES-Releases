'use strict';
const HOST='com.mycattles.bridge';
chrome.runtime.onMessage.addListener((message,sender,sendResponse)=>{
  if(['ping','capture','pending','fill_pending','ack'].includes(message?.action)){
    chrome.runtime.sendNativeMessage(HOST,message,reply=>{
      const error=chrome.runtime.lastError;
      sendResponse(error?{ok:false,error:'native_host_unavailable',detail:error.message}:(reply||{ok:false,error:'empty_response'}));
    });return true;
  }
  if(message?.action==='execute_fill'){
    (async()=>{
      const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
      const req=message.request;
      if(!tab?.id || !req || req.schemaVersion!==3 || !req.captureId || !Array.isArray(req.assignments) || new URL(tab.url).origin!==req.origin || (Number.isInteger(req.tabId) && req.tabId!==tab.id) || (req.pathname && new URL(tab.url).pathname!==req.pathname))return {ok:false,error:'tab_mismatch'};
      const results=await chrome.scripting.executeScript({target:{tabId:tab.id},func:fillFields,args:[req.assignments,req.policy||{},req.pathname]});
      return results?.[0]?.result||{ok:false,error:'fill_failed'};
    })().then(sendResponse).catch(e=>sendResponse({ok:false,error:'fill_failed',detail:String(e.message||e)}));return true;
  }
  if(message?.action==='capture_active_tab'){
    (async()=>{
      const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
      if(!tab?.id || !/^https:\/\//i.test(tab.url||''))return {ok:false,error:'unsupported_page'};
      const file=message.includeSecrets?'capture_analyzer_with_secrets.js':'capture_analyzer.js';
      const result=await chrome.scripting.executeScript({target:{tabId:tab.id},files:[file]});
      const capture=result?.[0]?.result||{ok:false,error:'no_result'};
      if(capture.ok)capture.tabId=tab.id;
      return capture;
    })().then(sendResponse).catch(e=>sendResponse({ok:false,error:'capture_failed',detail:String(e.message||e)}));
    return true;
  }
  if(message?.action==='analyze_active_tab'){
    (async()=>{
      const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
      if(!tab?.id || !/^https?:\/\//i.test(tab.url || ''))return {ok:false,error:'unsupported_page'};
      const result=await chrome.scripting.executeScript({target:{tabId:tab.id},files:['form_analyzer.js']});
      return result?.[0]?.result || {ok:false,error:'no_result'};
    })().then(sendResponse).catch(e=>sendResponse({ok:false,error:'analysis_failed',detail:String(e.message||e).slice(0,200)}));
    return true;
  }
  return false;
});

// Runs after the extension's user action. Candidate display scores never relax DOM safety checks.
function fillFields(assignments,policy,expectedPathname){
  if(expectedPathname && location.pathname!==expectedPathname)return {ok:false,error:'page_changed'};
  const initialUrl=location.href;
  const report=[];
  const decorate=(el,status,reason)=>{
    if(!el)return;
    const nodes=el.type==='radio'&&el.name?[...document.querySelectorAll('input[type="radio"]')].filter(x=>x.name===el.name&&x.form===el.form):[el];
    for(const node of nodes){
      node.dataset.mycattlesResult=status;
      node.dataset.mycattlesReason=reason;
      node.style.outline=status==='filled'||status==='overwritten'?'2px solid #238636':status.startsWith('rejected')?'2px solid #d1242f':'';
      node.title=`MyCATTLES: ${reason}`;
    }
  };
  const reasons={filled:'入力しました',overwritten:'既存値を更新しました',skipped_existing:'既存値を保護しました',skipped_unchanged:'すでに同じ値です',rejected_missing:'入力欄が見つかりません',rejected_ambiguous:'入力欄を一意に識別できません',rejected_value:'選択肢が一致しません',rejected_invalid:'入力要求が不正です',rejected_verify:'入力後の値を確認できません',rejected_page_changed:'入力中にページが変わりました',rejected_form:'フォームを識別できません'};
  const verify=(el,expected)=>el.type==='radio'?el.checked===true:el.type==='checkbox'?el.checked===expected:el.value===expected;

  const allowOverwrite=policy?.allowOverwrite===true;
  if(!Array.isArray(assignments))return {ok:false,error:'invalid_assignments'};
  const clean=v=>String(v??'').normalize('NFKC').replace(/\s+/g,' ').trim().slice(0,120);
  const norm=v=>clean(v).toLowerCase();
  const ignored=new Set(['hidden','submit','button','reset','image','file','range','color','search']);
  const visible=el=>{const s=getComputedStyle(el);return !el.disabled&&!el.closest('[hidden],[inert]')&&s.display!=='none'&&s.visibility!=='hidden'&&el.getClientRects().length>0;};
  const formOf=el=>el.form||el.closest('form')||document.body;
  const label=el=>{
    if(el.type==='radio'){
      const legend=el.closest('fieldset')?.querySelector('legend');if(legend)return clean(legend.textContent);
      const group=el.closest('[role="radiogroup"],[role="group"]');if(group){const a=group.getAttribute('aria-label');if(a)return clean(a);}
      const parent=el.closest('[class*="radio-group"],[class*="radioGroup"],[class*="gender"],[class*="sex"]');
      return clean(parent?.querySelector('legend,h2,h3,h4,[class*="title"],[class*="label"]')?.textContent||el.name);
    }
    return clean([...(el.labels||[])].map(x=>x.textContent).join(' ')||el.getAttribute('aria-label')||
      (el.getAttribute('aria-labelledby')||'').split(/\s+/).slice(0,3).map(id=>document.getElementById(id)?.textContent||'').join(' ')||el.name||el.id);
  };
  const identity=el=>({name:clean(el.name),id:clean(el.id),autocomplete:clean(el.getAttribute('autocomplete')),placeholder:clean(el.getAttribute('placeholder'))});
  const groups=new Map();const radioKeys=new WeakMap();
  for(const el of document.querySelectorAll('input,textarea,select')){
    if(ignored.has((el.type||'').toLowerCase())||!visible(el)||el.closest('[role=search],form[action*=search]'))continue;
    const form=formOf(el);if(!groups.has(form)){groups.set(form,[]);radioKeys.set(form,new Set());}
    if(el.type==='radio'){if(!el.name||radioKeys.get(form).has(el.name))continue;radioKeys.get(form).add(el.name);}
    groups.get(form).push(el);
  }
  const formList=[...groups.keys()];
  const nodes=[...groups.values()].flat();
  const details=[];let count=0,skipped=0;
  const record=(a,status,el)=>{const reason=reasons[status]||status;details.push({fieldRef:a.fieldRef,status,reason});if(status!=='filled'&&status!=='overwritten')skipped++;decorate(el,status,reason);};
  const seen=new Set();
  for(const a of assignments){
    if(location.href!==initialUrl){record(a||{fieldRef:''},'rejected_page_changed');break;}
    if(!a||typeof a.fieldRef!=='string'||!a.identity||typeof a.value!=='string'){record(a||{fieldRef:''},'rejected_invalid');continue;}
    const expected=a.identity;
    const candidateScores=[];
    for(const el of nodes){
      if(typeof a.formRef==='string' && /^form_\d+$/.test(a.formRef) && formList.indexOf(formOf(el))!==Number(a.formRef.slice(5)))continue;
      const actual=identity(el);const expectedType=norm(a.inputType),actualType=norm(el.type||el.tagName);
      if(expectedType&&expectedType!==actualType)continue;
      if(norm(label(el))!==norm(a.label))continue;
      // Any supplied stable attribute that conflicts is a hard mismatch.
      if(['name','id','autocomplete','placeholder'].some(k=>expected[k]&&norm(expected[k])!==norm(actual[k])))continue;
      let score=0;
      if(expected.name&&norm(expected.name)===norm(actual.name))score+=30;
      if(expected.id&&norm(expected.id)===norm(actual.id))score+=25;
      if(expected.autocomplete&&norm(expected.autocomplete)===norm(actual.autocomplete))score+=25;
      if(expected.placeholder&&norm(expected.placeholder)===norm(actual.placeholder))score+=10;
      if(a.label)score+=20;
      if(expectedType)score+=15;
      candidateScores.push({el,score});
    }
    candidateScores.sort((x,y)=>y.score-x.score);
    // One high-confidence candidate is permitted even if DOM order has changed.
    if(!candidateScores.length){record(a,'rejected_missing');continue;}
    const top=candidateScores[0];
    if(top.score<35||candidateScores.length>1&&candidateScores[1].score>=top.score-15){record(a,'rejected_ambiguous');continue;}
    const el=top.el;if(seen.has(el)){record(a,'rejected_ambiguous');continue;}seen.add(el);
    const value=a.value;
    if(el.type==='radio'){
      const options=[...document.querySelectorAll('input[type="radio"]')].filter(x=>x.name===el.name&&formOf(x)===formOf(el)&&visible(x));
      const candidates=options.filter(x=>norm(x.value)===norm(value)||norm([...(x.labels||[])].map(l=>l.textContent).join(' '))===norm(value));
      if(candidates.length!==1){record(a,'rejected_value');continue;}
      const current=options.find(x=>x.checked);
      if(current===candidates[0]){record(a,'skipped_unchanged');continue;}
      if(current&&!allowOverwrite){record(a,'skipped_existing');continue;}
      candidates[0].checked=true;candidates[0].dispatchEvent(new Event('input',{bubbles:true}));candidates[0].dispatchEvent(new Event('change',{bubbles:true}));if(!verify(candidates[0],true)){record(a,'rejected_verify',candidates[0]);continue;}count++;record(a,current?'overwritten':'filled',candidates[0]);continue;
    }
    if(el.type==='checkbox'){
      const yes=['true','1','yes','on','checked'].includes(norm(value));
      const no=['false','0','no','off','unchecked'].includes(norm(value));
      if(!yes&&!no){record(a,'rejected_value');continue;}
      if(el.checked===yes){record(a,'skipped_unchanged');continue;}
      // Checkbox false may represent an explicit user choice, not an empty field.
      if(!allowOverwrite){record(a,'skipped_existing');continue;}
      el.checked=yes;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));if(!verify(el,yes)){record(a,'rejected_verify',el);continue;}count++;record(a,'overwritten',el);continue;
    }
    const hadValue=el instanceof HTMLSelectElement?el.selectedIndex>=0&&!!el.value:!!el.value;
    if(hadValue&&!allowOverwrite){record(a,'skipped_existing');continue;}
    if(el instanceof HTMLSelectElement){
      const options=[...el.options].filter(o=>norm(o.value)===norm(value)||norm(o.textContent)===norm(value));
      if(options.length!==1){record(a,'rejected_value');continue;}
      if(el.value===options[0].value){record(a,'skipped_unchanged');continue;}
      el.value=options[0].value;
    }else{
      if(el.value===value){record(a,'skipped_unchanged');continue;}
      const proto=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      const setter=Object.getOwnPropertyDescriptor(proto,'value')?.set;if(setter)setter.call(el,value);else el.value=value;
    }
    el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));if(!verify(el,el instanceof HTMLSelectElement?el.value:value)){record(a,'rejected_verify',el);continue;}count++;record(a,hadValue?'overwritten':'filled',el);
  }
  return {ok:true,count,skipped,details};
}
