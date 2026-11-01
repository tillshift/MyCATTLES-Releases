'use strict';
const $=id=>document.getElementById(id);
const names={password:'パスワード',email:'メールアドレス',username:'ユーザー名・ログインID',phone:'電話番号',postal_code:'郵便番号',country:'国',region:'都道府県',city:'市区町村',address:'住所',full_name:'氏名',family_name:'姓',given_name:'名',organization:'会社名',birthday:'生年月日',website:'Webサイト',one_time_code:'認証コード',unknown:'未分類'};
const kinds={authentication_or_registration:'認証・登録フォーム候補',personal_information:'個人情報フォーム候補',other:'その他のフォーム'};
const statusNames={filled:'入力成功',overwritten:'上書き成功',skipped_existing:'既存値を保護',skipped_unchanged:'変更不要',rejected_missing:'入力欄が見つかりません',rejected_ambiguous:'入力欄が曖昧です',rejected_value:'選択肢が一致しません',rejected_invalid:'入力要求が不正です',rejected_verify:'入力後の検証に失敗',rejected_page_changed:'ページが変わりました'};
const confidence={high:'高',medium:'中',low:'低',unknown:'未判定'};
const add=(parent,tag,value,cls)=>{const el=document.createElement(tag);el.textContent=value;if(cls)el.className=cls;parent.appendChild(el);return el;};
const setStatus=(message,kind='idle')=>{ $('step3status').textContent=message;const b=$('statusBadge');b.className='status-badge'+(kind==='idle'?'':' '+kind);b.textContent={idle:'待機中',good:'完了',bad:'要確認',busy:'処理中'}[kind]||'待機中';};
const setConnection=(message,kind)=>{ const dot=$('connectionDot');const label={good:'アプリに接続しています',warn:'アプリはロック中です',bad:'アプリに接続できません',idle:'接続を確認しています'}[kind]||'接続を確認しています';dot.className='dot '+kind;dot.title=label+'：'+message;dot.setAttribute('aria-label',label+'：'+message);};
const busy=(id,active)=>{const b=$(id);b.disabled=active;b.setAttribute('aria-busy',String(active));};
const send=(message,done)=>chrome.runtime.sendMessage(message,reply=>{
  const error=chrome.runtime.lastError;done(error?{ok:false,error:'extension_error',detail:error.message}:(reply||{ok:false,error:'empty_response'}));
});
const checkConnection=()=>{busy('ping',true);setConnection('接続を確認中…','idle');send({action:'ping'},r=>{busy('ping',false);setConnection(r.ok?(r.status==='ready'?'利用可能':'ロック解除が必要です'):'接続できません：'+(r.error||'unknown')+(r.detail?' / '+r.detail:''),r.ok?(r.status==='ready'?'good':'warn'):'bad');});};
$('ping').addEventListener('click',checkConnection);
checkConnection();
$('analyze').addEventListener('click',()=>{
  $('summary').textContent='解析中…';$('results').replaceChildren();busy('analyze',true);setStatus('ページの入力欄を解析しています…','busy');
  send({action:'analyze_active_tab'},r=>{busy('analyze',false);setStatus(r.ok?'解析が完了しました。':'解析できませんでした。',r.ok?'good':'bad');
    if(!r.ok){$('summary').textContent=r.error==='unsupported_page'?'このページは解析対象外です（ブラウザ内部ページ、ファイルURL、権限不足等）。通常のHTTPSサイトで試すか、フォームへ手動入力してください。':
      `解析失敗：${r.error||'unknown'}${r.detail?'\n'+r.detail:''}`;return;}
    $('summary').textContent=`${r.origin}\nフォーム：${r.formCount}件 ／ 入力項目：${r.fieldCount}件`;
    if(r.truncated)add($('results'),'p','検出上限に達したため一部のみ表示します。','small');
    if(!r.formCount)add($('results'),'p','対応できるフォームが見つかりません。iframe内・独自UI・非表示項目などは解析できない場合があります。必要な項目は手動入力してください。');
    for(const f of r.forms||[]){
      const card=add($('results'),'section','', 'form');add(card,'strong',`フォーム ${f.index}：${kinds[f.kind]||'その他'}`);
      add(card,'div',`分類済み ${f.recognized} / ${f.fields.length}`,'small');
      for(const field of f.fields){const line=add(card,'div','', 'field');
        add(line,'div',`${field.index}. ${names[field.field]||field.field}${field.required?'（必須）':''}`);
        add(line,'div',`信頼度：${confidence[field.confidence]||'未判定'} ／ ${field.tag} (${field.inputType})${field.label?' ／ '+field.label:''}`,'small');
        if(field.field==='unknown')add(line,'div','項目を特定できません。手動入力してください。','small');}
    }
  });
});

// Read actual input values only when the user explicitly requests transfer.
$('capture').addEventListener('click',()=>{
  const includeSecrets=confirm('フォームの入力済み情報をMyCATTLESに送信します。\nパスワード・認証コードも含めますか？\n\n「キャンセル」なら通常の入力値だけを送信します。');
  if(!confirm('現在のページの入力値をローカルのMyCATTLESへ送信します。よろしいですか？'))return;
  setStatus('フォーム情報を送信中…','busy');
  send({action:'capture_active_tab',includeSecrets},analysis=>{
    if(!analysis?.ok){$('step3status').textContent='解析失敗：'+(analysis?.error||'unknown');return;}
    if(!analysis.origin?.startsWith('https://')){$('step3status').textContent='HTTPSページのみ送信できます。';return;}
    const forms=(analysis.forms||[]).slice(0,30).map(f=>({kind:f.kind,formRef:f.formRef,fields:(f.fields||[]).slice(0,100).map(v=>({fieldRef:v.fieldRef,identity:v.identity,field:v.field,label:v.label,value:v.value||'',inputType:v.inputType||'',options:v.options||[],checked:v.checked,selectedValue:v.selectedValue}))}));
    send({action:'capture',capture:{schemaVersion:3,captureId:crypto.randomUUID(),origin:analysis.origin,pathname:analysis.pathname,tabId:analysis.tabId,forms}},reply=>{
      setStatus(reply.ok?'MyCATTLESに送信しました。':'送信失敗：'+(reply.error||'unknown'),reply.ok?'good':'bad');
      if(reply.ok)window.close();
    });
  });
});
$('fill').addEventListener('click',()=>{
  setStatus('入力要求を確認中…','busy');
  send({action:'fill_pending'},r=>{
    if(!r?.ok){$('step3status').textContent='確認失敗：'+(r?.error||'unknown');return;}
    if(!r.pending){$('step3status').textContent='入力要求がありません。';return;}
    const req=r.request;
    chrome.tabs.query({active:true,currentWindow:true},tabs=>{
      const tab=tabs[0];
      if(!tab?.url || new URL(tab.url).origin!==req.origin || (req.pathname && new URL(tab.url).pathname!==req.pathname) || (Number.isInteger(req.tabId) && req.tabId!==tab.id)){$('step3status').textContent='対象サイトのタブをアクティブにしてください。';return;}
      // P2-01: the user's click on 'フォームに入力する' is the execution consent.
      // The fill engine still enforces overwrite policy, tab identity, and no auto-submit.
      send({action:'execute_fill',request:req},result=>{
        setStatus(result.ok?`入力：${result.count}項目、スキップ：${result.skipped}項目\n${(result.details||[]).map(x=>x.fieldRef+': '+(statusNames[x.status]||x.status)+(x.reason?'（'+x.reason+'）':'')).join('\n')}`:'入力失敗：'+(result.error||'unknown'),result.ok?'good':'bad');
        if(result.ok)send({action:'ack',id:req.id},()=>{});
      });
    });
  });
});
