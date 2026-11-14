'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const start=source.indexOf('        function renderInstallManager() {'),end=source.indexOf('        function updateJobIndicator()',start);
assert.ok(start>0&&end>start,'manager function boundaries exist');
const manager=source.slice(start,end);
const windowsHelpers=source.slice(source.indexOf('        function isSteamWindowsGame(game)'),source.indexOf('        function renderSteamWindowsInstallation'));
const ratio=source.slice(source.indexOf('        function jobPhase(job) {'),source.indexOf('        function steamCompletionSignature',source.indexOf('        function jobPhase(job) {')));
function assertNoHandlers(html){
 for(const [tag] of html.matchAll(/<(?:[^"'<>]|"[^"]*"|'[^']*')+>/g)){
  const outsideValues=tag.replace(/"[^"]*"|'[^']*'/g,'');
  assert.doesNotMatch(outsideValues,/\s+on[a-z]+\s*=/i,'no executable event attribute outside quoted text');
 }
 assert.doesNotMatch(html,/<script\b/i);
}
function render(job,options={}){
 const elements={},sent=[],opened=[];
 const escape=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const decode=s=>String(s).replace(/&(amp|lt|gt|quot|#39);/g,(_,c)=>({amp:'&',lt:'<',gt:'>',quot:'"','#39':"'"}[c]));
 class Element{
  constructor(tag){this.tag=tag;this.children=[];this.attributes={};this.dataset={};this.style={};this.listeners={};this.parent=null;this._text='';this.disabled=false;this.hidden=false;this.assignments=0;}
  set id(value){this.attributes.id=value;elements[value]=this;} get id(){return this.attributes.id;}
  set textContent(value){this._text=String(value);this.children=[];} get textContent(){return this._text+this.children.map(n=>n.textContent).join('');}
  append(...nodes){for(const node of nodes)this.insertBefore(node,null);}
  insertBefore(node,before){if(node.parent)node.parent.children.splice(node.parent.children.indexOf(node),1);const index=before?this.children.indexOf(before):this.children.length;this.children.splice(index,0,node);node.parent=this;}
  remove(){if(this.parent)this.parent.children.splice(this.parent.children.indexOf(this),1);this.parent=null;}
  setAttribute(key,value){this.attributes[key]=String(value);if(key==='id')elements[value]=this;if(key==='disabled')this.disabled=true;if(key==='hidden')this.hidden=true;if(key.startsWith('data-'))this.dataset[key.slice(5).replace(/-([a-z])/g,(_,c)=>c.toUpperCase())]=String(value);}
  getAttribute(key){return this.attributes[key]??null;}
  removeAttribute(key){delete this.attributes[key];if(key==='disabled')this.disabled=false;if(key==='hidden')this.hidden=false;}
  addEventListener(type,callback){this.listeners[type]=callback;}
  set innerHTML(value){
   this.assignments++;const removeIDs=node=>{if(node.id&&elements[node.id]===node)delete elements[node.id];node.children.forEach(removeIDs);};this.children.forEach(removeIDs);this.children=[];this._text='';
   const stack=[this],voids=new Set(['img','path','input','br','hr','use']);
   for(const token of String(value).matchAll(/<([a-z][\w-]*)\b([^>]*)>|<\/([a-z][\w-]*)\s*>|([^<]+)/gi)){
    if(token[1]){const node=new Element(token[1].toLowerCase());for(const attr of token[2].matchAll(/([\w:-]+)(?:="([^"]*)")?/g))node.setAttribute(attr[1],decode(attr[2]??''));stack.at(-1).append(node);if(!voids.has(node.tag)&&!token[2].endsWith('/'))stack.push(node);}
    else if(token[3]){if(stack.length>1)stack.pop();}
    else if(token[4]){const node=new Element('#text');node.textContent=decode(token[4]);stack.at(-1).append(node);}
   }
  }
  get innerHTML(){return escape(this._text)+this.children.map(node=>node.outerHTML).join('');}
  get outerHTML(){if(this.tag==='#text')return escape(this._text);const attrs={...this.attributes};for(const [k,v]of Object.entries(this.dataset))attrs['data-'+k.replace(/[A-Z]/g,c=>'-'+c.toLowerCase())]=v;if(this.hidden)attrs.hidden='';else delete attrs.hidden;if(this.disabled)attrs.disabled='';else delete attrs.disabled;return '<'+this.tag+Object.entries(attrs).map(([k,v])=>' '+k+'="'+escape(v)+'"').join('')+'>'+this.innerHTML+(new Set(['img','path','input','br','hr','use']).has(this.tag)?'':'</'+this.tag+'>');}
 }
 const pane=new Element('div');pane.id='installManagerPane';
 const account='76561198000000001';
 const state={installJob:job,games:options.games||[{id:'steam:game',title:'Clair Obscur',store:'steam',canLaunch:false}],selectedAccountId:options.account||account,accounts:options.accounts||[{id:account}],runtimes:options.runtimes||[{id:'playmelt-d3dmetal',platform:'windows'}],windowsRuntime:options.runtime||{}};
 if(Object.hasOwn(options,'jobs'))state.installJobs=options.jobs;
 const context={URL,state,ui:{},$:id=>elements[id],el:(tag,cls,text)=>{const n=new Element(tag);if(cls)n.setAttribute('class',cls);if(text!==undefined)n.textContent=text;return n;},platforms:g=>g.platforms||[],installJobFor:()=>job,windowsExecutionUnavailable:()=>options.unavailable===true,imageSources:()=>[],jobPhase:j=>j.phase||j.status,renderProtectionEnabled:()=>options.protected===true,send:(...args)=>sent.push(args),openGame:g=>opened.push(g),updateToolbar(){},renderLibrary(){}};
 const jobsHelpers=source.slice(source.indexOf('        function installationJobs()'),source.indexOf('        function installJobFor(game)'));
 vm.createContext(context);const api=vm.runInContext(windowsHelpers+jobsHelpers+ratio+manager+';renderInstallManager();({renderInstallManager,installationJobs});',context);
 return {get html(){return pane.innerHTML;},elements,sent,opened,state,ui:context.ui,rerender:()=>api.renderInstallManager(),jobs:()=>api.installationJobs(),click(id){elements[id]?.listeners.click?.();}};
}
const stale={id:'job-1',gameId:'steam:game',status:'failed',phase:'Installation',message:'Échec du client officiel',progress:.9,bytesDownloaded:900,bytesTotal:1000,speed:'99 MiB/s',eta:'1 min',cancellable:false};
test('failed, cancelled and timed-out jobs never present stale telemetry as current activity',()=>{
 for(const status of ['failed','interrupted','cancelled','timed-out']){
  const view=render({...stale,status});
  assert.match(view.html,/Échec du client officiel/);
  assert.doesNotMatch(view.html,/En cours|99 MiB\/s|1 min|mgr-step active|mgr-progress-bar-fill|Annuler l’installation/);
  assert.equal(view.elements.mgrCancelBtn,undefined);
  assert.equal(view.elements.mgrRetryBtn.disabled,true);
  assert.match(view.html,/Historique des étapes non disponible/);
 }
});
test('active downloads show only measured progress and transmitted ETA, without invented machine claims',()=>{
 const measured=render({...stale,status:'downloading',phase:'Téléchargement',cancellable:true});
 assert.match(measured.html,/90 %/);assert.match(measured.html,/99 MiB\/s/);assert.match(measured.html,/1 min/);assert.ok(measured.elements.mgrCancelBtn);
 const unknown=render({id:'job-2',gameId:'steam:game',status:'downloading',cancellable:true});
 assert.match(unknown.html,/Progression non mesurée/);assert.match(unknown.html,/Non mesuré/);assert.doesNotMatch(unknown.html,/0 %|Calcul en cours/);
 for(const view of [measured,unknown])assert.doesNotMatch(view.html,/431|MetalFX|Metal 4|M3|DirectX 12 Natif|Zéro latence|À venir \(|~1-2 min|Prêt à jouer|Prêt !/);
});
test('prepared files never claim gameplay and only expose existing safe follow-up actions',()=>{
 for(const status of ['files-prepared','launch-ready']){
  const view=render({...stale,status});
  assert.match(view.html,/Fichiers préparés/);assert.match(view.html,/premier lancement.*restent à vérifier/);assert.doesNotMatch(view.html,/Prêt à jouer|Tu peux jouer|Prêt !|En cours/);
  assert.ok(view.elements.mgrPreparedBtn);assert.equal(view.elements.mgrLaunchBtn,undefined);
 }
 const launch=render({...stale,status:'launch-ready'},{games:[{id:'steam:game',title:'Clair Obscur',store:'steam',canLaunch:true}]});
 assert.match(launch.html,/Tester le lancement/);launch.click('mgrLaunchBtn');assert.equal(launch.sent[0][0],'launchGame');
 const protectedView=render({...stale,status:'launch-ready'},{protected:true,games:[{id:'steam:game',canLaunch:true}]});
 assert.equal(protectedView.elements.mgrLaunchBtn,undefined);
});
test('retry sends only the failed job identity when the exact native capability is present, once',()=>{
 const recovery={canRetry:true,action:'retryInstallAndPlay'};
 const view=render({...stale,recovery});assert.equal(view.elements.mgrRetryBtn.disabled,false);
 view.click('mgrRetryBtn');view.click('mgrRetryBtn');
 assert.equal(view.sent.length,1);assert.equal(view.sent[0][0],'retryInstallAndPlay');assert.equal(view.sent[0][1].jobId,'job-1');assert.deepEqual(Object.keys(view.sent[0][1]),['jobId']);
 for(const patch of [{recovery:{canRetry:true,action:'installGame'}},{recovery:{canRetry:false,action:'retryInstallAndPlay'}},{id:''},{status:'cancelled'},{status:'timed-out'}]){
  const blocked=render({...stale,recovery,...patch});blocked.click('mgrRetryBtn');assert.equal(blocked.sent.length,0);assert.notEqual(blocked.elements.mgrRetryBtn?.disabled,false);
 }
 const changed=render({...stale,recovery});changed.state.installJob={...stale,id:'another-job',recovery};changed.click('mgrRetryBtn');assert.equal(changed.sent.length,0);
 const revoked=render({...stale,recovery});revoked.state.installJob={...stale,recovery:{...recovery,canRetry:false}};revoked.click('mgrRetryBtn');assert.equal(revoked.sent.length,0);
 const protectedView=render({...stale,recovery},{protected:true});protectedView.click('mgrRetryBtn');assert.equal(protectedView.sent.length,0);assert.equal(protectedView.elements.mgrRetryBtn.disabled,true);
});
test('native messages and titles remain text; unsafe artwork cannot create markup',()=>{
 const view=render({...stale,message:'<script>bad()</script> & diagnostic',recovery:{reason:'<b>Reconnectez-vous</b>'}},{games:[{id:'steam:game',title:'<img src=x onerror=bad()>',imageURL:'javascript:bad()'}]});
 assert.match(view.html,/&lt;script&gt;bad\(\)&lt;\/script&gt; &amp; diagnostic/);
 assert.match(view.html,/&lt;img/);assert.match(view.html,/&lt;b&gt;Reconnectez-vous/);
 assert.doesNotMatch(view.html,/<script|<b>Reconnectez|javascript:/);
});
test('all remote and error text fields remain text, including image-handler payloads',()=>{
 const payload='<img src=x onerror="globalThis.injected=1">',escaped='&lt;img src=x onerror=&quot;globalThis.injected=1&quot;&gt;';
 const active=render({...stale,status:'downloading',phase:payload,message:payload,speed:payload,eta:payload},{games:[{id:'steam:game',title:payload,store:'steam',imageURL:'https://assets.example.test/game.png'}]});
 assert.equal(active.html.split(escaped).length-1,6,'list title, detail title and alt, message, speed and ETA are escaped; phase uses the canonical status');
 assertNoHandlers(active.html);
 assert.equal((active.html.match(/<img\b/g)||[]).length,2,'only the two intended artwork nodes exist');
 assert.match(active.html,/src="https:\/\/assets.example.test\/game.png"/);
 assert.equal(active.sent.length,0);
});
test('artwork accepts canonical HTTPS and exact local Steam artwork; rejects scripts, credentials, malformed and CSS payloads',()=>{
 for(const imageURL of ['javascript:alert(1)','data:image/svg+xml,<svg onload=bad()>','file:///tmp/private','https://user:secret@example.test/a.png','https://','https://example.test/a\\b.png','https://example.test/a\nb.png','metalmaxart:/steam/1/../../file','metalmaxart:/steam/1?x=bad']){
  const view=render(stale,{games:[{id:'steam:game',title:'Jeu',imageURL}]});
  assert.doesNotMatch(view.html,/<img\b|background-image\s*:/);
 }
 for(const imageURL of ['https://assets.example.test/a.png','metalmaxart:/steam/1903340','metalmaxart://steam/1903340/portrait']){
  const view=render(stale,{games:[{id:'steam:game',title:'Jeu',imageURL}]});assert.match(view.html,/<img\b/);
 }
 const view=render(stale,{games:[{id:'steam:game',title:'Jeu',imageURL:'https://assets.example.test/a.png" onerror="bad()'}]});
 assert.match(view.html,/%22%20onerror=%22bad\(\)/);
 assertNoHandlers(view.html);
 assert.doesNotMatch(view.html,/background-image\s*:|url\(/i,'untrusted artwork never enters CSS');
});
test('interrupted restoration stays stopped until a permitted explicit retry sends the same job ID',()=>{
 const recovery={canRetry:true,action:'retryInstallAndPlay'};
 const view=render({...stale,status:'interrupted',recovery});
 assert.match(view.html,/Installation à reprendre/);assert.equal(view.sent.length,0);assert.equal(view.elements.mgrRetryBtn.disabled,false);
 assert.doesNotMatch(view.html,/En cours|99 MiB\/s|90 %/);
 view.click('mgrRetryBtn');assert.equal(view.sent.length,1);assert.equal(view.sent[0][0],'retryInstallAndPlay');assert.equal(view.sent[0][1].jobId,stale.id);
 const blocked=render({...stale,status:'interrupted'});blocked.click('mgrRetryBtn');assert.equal(blocked.sent.length,0);
});
test('post-download stages never inherit download progress, speed or ETA; account wait remains human',()=>{
 for(const status of ['preparing-client','awaiting-account','preparing-files','awaiting-steam']){
  const view=render({...stale,status,phase:'Téléchargement',message:'',cancellable:true});
  assert.doesNotMatch(view.html,/90 %|99 MiB\/s|1 min|mgr-progress-bar-fill/);
  assert.match(view.html,/Progression non mesurée/);assert.ok(view.elements.mgrCancelBtn);
  assert.equal(view.elements.mgrRetryBtn,undefined);assert.equal(view.sent.length,0);
  for(const [,step] of view.html.matchAll(/<div class="mgr-step active">([\s\S]*?)<\/div>/g))assert.doesNotMatch(step,/Téléchargement/);
  if(status==='awaiting-account'){
   assert.match(view.html,/En attente de connexion Steam/);assert.match(view.html,/Connecte le compte Steam/);assert.doesNotMatch(view.html,/En cours|mgr-step active/);
  }
 }
});

test('a stopped historical cancellation offers a fresh current-context completion from the manager',()=>{
 const game={id:'steam:1903340:local:fixture',appId:'1903340',store:'steam',platform:'windows',installed:true,canLaunch:false,runtimeId:'playmelt-d3dmetal'};
 const job={...stale,id:'legacy-fixture',gameId:game.id,appId:game.appId,accountId:'76561198000000001',runtimeId:'playmelt-d3dmetal',status:'failed',restored:true,autoLaunch:false,
  error:{code:'cancelled',retryable:false},stages:[],recovery:{canRetry:false,action:'retryInstallAndPlay'}};
 const view=render(job,{games:[game]});
 assert.match(view.html,/Terminer l’installation/);assert.ok(view.elements.mgrFreshInstallBtn);
 assert.equal(view.elements.mgrRetryBtn,undefined);assert.equal(view.sent.length,0);
 view.click('mgrFreshInstallBtn');view.click('mgrFreshInstallBtn');
 assert.equal(view.sent.length,1);assert.equal(view.sent[0][0],'installAndPlay');
 assert.equal(view.sent[0][1].gameId,game.id);assert.equal(view.sent[0][1].runtimeId,'playmelt-d3dmetal');
 assert.deepEqual(Object.keys(view.sent[0][1]).sort(),['gameId','runtimeId']);
});

test('the manager always offers a safe exit when current state cannot qualify a new terminal request',()=>{
 const view=render(stale);assert.ok(view.elements.mgrGameBtn);view.click('mgrGameBtn');assert.equal(view.opened.length,1);
 const missing=render({...stale,gameId:'missing-game'},{games:[]});
 assert.match(missing.html,/Retour à la bibliothèque/);assert.ok(missing.elements.mgrGameBtn);
 assert.equal(missing.elements.mgrFreshInstallBtn,undefined);missing.click('mgrGameBtn');assert.equal(missing.sent.length,0);
});

function observedGOG(extra={}){
 return {id:'gog:1423049311:fixture',gameId:'gog:1423049311',appId:'1423049311',title:'Cyberpunk native fixture',store:'gog',platform:'mac',runtimeId:'gog-mac',
  status:'installing',phase:'Installation GOG Galaxy',message:'Installation GOG détectée ; progression du transfert non fournie',progress:null,bytesDownloaded:null,bytesTotal:68606283631,speed:null,eta:null,
  stages:[{id:'client',status:'active',progress:null}],cancellable:false,autoLaunch:false,source:'galaxy',observed:true,updatedAt:1900000000,...extra};
}
test('GOG native Mac observation uses the same list with unknown transfer and a known total, without Steam controls',()=>{
 const job=observedGOG(),view=render(stale,{jobs:[stale,job],games:[{id:stale.gameId,title:'Steam fixture',store:'steam'},
  {id:job.gameId,appId:job.appId,title:job.title,store:'gog',platform:'mac',installed:false,canLaunch:false}]});
 assert.equal(view.elements.installJobsList.children.length,2);
 assert.match(view.html,/GOG · Mac natif/);assert.match(view.html,/Client GOG Galaxy/);assert.match(view.html,/68,6 Go/);
 assert.match(view.html,/Non mesuré/);assert.match(view.html,/data-mode="indeterminate"/);
 assert.doesNotMatch(view.html,/0 %|aria-valuenow="0"|Installer Steam|Ouvrir GOG|Ouvrir Steam|Préparation du moteur/);
 assert.equal(view.elements.mgrCancelBtn,undefined);assert.equal(view.elements.mgrRetryBtn,undefined);assert.equal(view.sent.length,0);
 assert.equal(view.ui.installManagerJobKey,'gog:'+job.id,'an active observed operation is selected before an old failed Steam job');
});
test('explicit empty snapshots are authoritative while an absent array still supports the legacy job',()=>{
 const empty=render(stale,{jobs:[]});assert.equal(empty.jobs().length,0);assert.match(empty.html,/Aucun téléchargement en cours/);
 const legacy=render(stale);assert.equal(legacy.jobs().length,1);assert.match(legacy.html,/Échec du client officiel/);
});
test('progress updates preserve rows, selection, detail nodes and focusable controls',()=>{
 const job=observedGOG(),other={...stale,id:'steam-other'};
 const view=render(other,{jobs:[other,job]});
 const list=view.elements.installJobsList,row=list.children[1],detail=view.elements.installJobDetail,phase=view.elements.mgrPhase,rootAssignments=view.elements.installManagerPane.assignments;
 const detailAssignments=detail.assignments;
 job.updatedAt++;job.message='Installation GOG toujours observée';view.rerender();
 assert.equal(view.elements.installJobsList,list);assert.equal(list.children[1],row);assert.equal(view.elements.installJobDetail,detail);assert.equal(view.elements.mgrPhase,phase);
 assert.equal(view.elements.installManagerPane.assignments,rootAssignments);assert.equal(detail.assignments,detailAssignments);
 assert.equal(view.ui.installManagerJobKey,'gog:'+job.id);assert.match(view.html,/toujours observée/);
 job.status='waiting';job.stages=[{id:'client',status:'waiting',progress:null}];view.rerender();
 assert.equal(view.elements.mgrPhase,phase);assert.equal(row,list.children[1]);assert.match(phase.textContent,/à vérifier/);
 assert.doesNotMatch(view.html,/data-mode="indeterminate"|En pause|Installation terminée/);
});
test('a measured stage can progress without replacing the active download row or action',()=>{
 const job={...stale,status:'downloading',cancellable:true,recovery:undefined};
 const view=render(job),row=view.elements.installJobsList.children[0],cancel=view.elements.mgrCancelBtn,detail=view.elements.installJobDetail;
 const assignments=detail.assignments;
 job.bytesDownloaded=950;job.speed='1 MiB/s';view.rerender();
 assert.equal(view.elements.installJobsList.children[0],row);assert.equal(view.elements.mgrCancelBtn,cancel);assert.equal(detail.assignments,assignments);
 assert.match(view.html,/95 %/);assert.equal(view.sent.length,0);
});
test('same IDs across stores stay separate and an observed job can never advertise managed Steam commands',()=>{
 const gog=observedGOG({id:'collision',gameId:'shared',status:'failed',cancellable:true,recovery:{canRetry:true,action:'retryInstallAndPlay'}}),steam={...stale,id:'collision',gameId:'shared',store:'steam'};
 const view=render(steam,{jobs:[steam,gog],games:[{id:'shared',store:'steam',title:'Steam title'},{id:'shared',store:'gog',title:'GOG title',platform:'mac'}]});
 view.elements.installJobsList.children[1].listeners.click();
 assert.equal(view.elements.installJobsList.children.length,2);assert.equal(view.elements.mgrRetryBtn,undefined);assert.equal(view.elements.mgrCancelBtn,undefined);
 assert.match(view.html,/GOG title/);assert.equal(view.sent.length,0);
});
