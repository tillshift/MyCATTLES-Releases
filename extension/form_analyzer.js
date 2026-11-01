(() => {
  'use strict';
  const rules = [
    ['password',/password|passwd|パスワード|暗証番号/i],['email',/e.?mail|メールアドレス|電子メール/i],
    ['username',/user.?name|login.?id|account.?id|ユーザー名|ユーザーid|ログインid/i],
    ['phone',/phone|mobile|tel|電話番号|携帯/i],['postal_code',/postal|zip.?code|郵便番号/i],
    ['country',/country|国名/i],['region',/prefecture|province|state|都道府県/i],
    ['city',/city|市区町村/i],['address',/address|street|住所|番地|建物名/i],
    ['full_name',/full.?name|氏名|お名前|姓名/i],['family_name',/family.?name|last.?name|surname|苗字|名字|^姓$/i],
    ['given_name',/given.?name|first.?name|^名$/i],['organization',/company|organization|会社名|法人名/i],
    ['gender',/gender|sex|性別/i],['birthday',/birth|生年月日|誕生日/i],['website',/website|homepage|ホームページ/i],
    ['one_time_code',/one.time.code|otp|verification.code|認証コード|確認コード/i]
  ];
  const acMap = {'name':'full_name','given-name':'given_name','family-name':'family_name',
    'username':'username','nickname':'username','email':'email','new-password':'password',
    'current-password':'password','one-time-code':'one_time_code','organization':'organization',
    'street-address':'address','address-line1':'address','address-line2':'address',
    'address-level1':'region','address-level2':'city','country':'country',
    'country-name':'country','postal-code':'postal_code','tel':'phone','bday':'birthday','url':'website'};
  const clean = v => String(v ?? '').normalize('NFKC').replace(/\s+/g,' ').trim().slice(0,120);
  const ignored = new Set(['hidden','submit','button','reset','image','file','range','color']);
  const isSearch = el => {
    const type=(el.getAttribute('type')||'').toLowerCase();
    if(type==='search' || el.getAttribute('role')==='searchbox')return true;
    const ac=(el.getAttribute('autocomplete')||'').toLowerCase();
    if(ac.split(/\s+/).includes('search'))return true;
    const attrs=[el.name,el.id,el.getAttribute('aria-label'),el.getAttribute('placeholder'),el.getAttribute('title')].filter(Boolean).join(' ').normalize('NFKC');
    if(/(?:^|[\s_\-])(?:search|query|q_search|site_search|検索|サイト内検索)(?:$|[\s_\-])/i.test(attrs))return true;
    if(el.closest('[role=search],form[role=search],form[method=get][action*=search],form[action*=search]'))return true;
    return false;
  };
  const label = el => clean([...(el.labels || [])].map(x=>x.textContent).join(' ') || el.getAttribute('aria-label') ||
    (el.getAttribute('aria-labelledby') || '').split(/\s+/).slice(0,3).map(id=>document.getElementById(id)?.textContent || '').join(' '));
  const visible = el => {const s=getComputedStyle(el);return !el.disabled && !el.closest('[hidden],[inert]') &&
    s.display!=='none' && s.visibility!=='hidden' && el.getClientRects().length>0;};
  const classify = el => {
    const tokens=clean(el.getAttribute('autocomplete')).toLowerCase().split(' ');
    for(const t of tokens) if(acMap[t]) return {field:acMap[t],confidence:'high'};
    const type=(el.getAttribute('type') || '').toLowerCase();
    if(['password','email','tel','url'].includes(type)) return {field:({tel:'phone',url:'website'})[type] || type,confidence:'high'};
    const text=label(el);for(const [field,re] of rules)if(re.test(text))return {field,confidence:'medium'};
    const attrs=clean([el.name,el.id,el.getAttribute('placeholder')].join(' '));
    for(const [field,re] of rules)if(re.test(attrs))return {field,confidence:'low'};
    return {field:'unknown',confidence:'unknown'};
  };
  const CAPTURE=false,SECRETS=false;
  const groups=new Map();let scanned=0;let truncated=false;
  const radioKeys=new WeakMap();
  function groupLabel(el){
    const legend=el.closest('fieldset')?.querySelector('legend');
    if(legend)return clean(legend.textContent);
    const container=el.closest('[role="radiogroup"],[role="group"]');
    if(container)return clean(container.getAttribute('aria-label')||container.getAttribute('aria-labelledby')?.split(/\s+/).map(id=>document.getElementById(id)?.textContent||'').join(' ')||'');
    const parent=el.closest('[class*="radio-group"],[class*="radioGroup"],[class*="gender"],[class*="sex"]');
    if(parent){const title=parent.querySelector('legend,h2,h3,h4,[class*="title"],[class*="label"]');if(title)return clean(title.textContent);}
    return clean(el.name||el.getAttribute('aria-label')||'');
  }
  for(const el of document.querySelectorAll('input,textarea,select')) {
    if(++scanned>750){truncated=true;break;}
    if(ignored.has((el.type || '').toLowerCase()) || !visible(el) || isSearch(el))continue;
    const key=el.form || el.closest('form') || document.body;
    if(!groups.has(key)){if(groups.size>=30){truncated=true;continue;}groups.set(key,[]);radioKeys.set(key,new Set());}
    const fields=groups.get(key);if(fields.length>=250){truncated=true;continue;}
    let members=[el];
    if(el.type==='radio'){
      const name=el.name||el.id;
      if(!name)continue;
      if(radioKeys.get(key).has(name))continue;
      radioKeys.get(key).add(name);
      members=[...document.querySelectorAll('input[type="radio"]')].filter(x=>(x.form||x.closest('form')||document.body)===key && x.name===el.name && visible(x));
      if(!members.length)continue;
    }
    const result=classify(el);
    if(el.type==='radio'){
      const text=groupLabel(el);
      if(/gender|sex|性別/i.test(text+' '+el.name)){result.field='gender';result.confidence='high';}
    }
    const displayLabel=el.type==='radio'?groupLabel(el):(label(el)||clean(el.name||el.id));
    fields.push({index:fields.length+1,tag:el.tagName.toLowerCase(),inputType:clean(el.type || el.tagName),
      ...result,label:displayLabel,required:!!el.required,
      options:el.type==='radio'?members.map(x=>({label:clean(label(x)||x.value),value:String(x.value).slice(0,120)})):
        el instanceof HTMLSelectElement?[...el.options].slice(0,100).map(x=>({label:clean(x.textContent),value:String(x.value).slice(0,120)})):[],
      value:''
    });
  }
  const forms=[...groups.values()].map((fields,i)=>{
    const types=new Set(fields.map(f=>f.field));
    return {index:i+1,kind:types.has('password')?'authentication_or_registration':
      (types.has('email') || types.has('address') || types.has('full_name'))?'personal_information':'other',
      recognized:fields.filter(f=>f.field!=='unknown').length,fields};
  });
  return {ok:true,protocol:2,origin:location.origin,formCount:forms.length,
    fieldCount:forms.reduce((n,f)=>n+f.fields.length,0),truncated,forms};
})();
