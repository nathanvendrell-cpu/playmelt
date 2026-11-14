'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(process.env.PLAYMELT_UI_SOURCE||path.join(__dirname,'../index.html'),'utf8');
const start=source.indexOf('        function renderProtectionEnabled()'),end=source.indexOf('        function renderLibrary()',start);
assert(start>0&&end>start);
const walk=n=>[n,...n.children.flatMap(walk)],button=(n,label)=>walk(n).find(x=>x.tag==='button'&&x.textContent===label);
function fixture(extra={},options={}){
 const elements={},sent=[],made=[];
 function node(tag,cls='',text=''){
  const created={tag,cls,textContent:text,children:[],dataset:{},handlers:{},value:'',style:{},disabled:false,
   append(...children){this.children.push(...children)},replaceChildren(...children){this.children=[...children];this.textContent=''},
   addEventListener(type,handler){this.handlers[type]=handler},setAttribute(k,v){this[k]=v},hasAttribute(k){return k==='value'?this.value!=='':this[k]!==undefined},removeAttribute(k){delete this[k]},
   showModal(){this.open=true},close(){this.open=false},get text(){return this.textContent}};
  made.push(created);return created;
 }
 for(const id of ['dialogTitle','dialogStore','dialogBody','dialogHeroBadges','gameDialog','gameSettingsDialog','gameSettingsBody','gameSettingsSubtitle','installJobButton'])elements[id]=node('div');
 const game={id:'steam:1250790:local:fixture',appId:'1250790',title:'Windows fixture',store:'steam',platform:'windows',platforms:['windows'],installed:true,canLaunch:false,canInstall:false,requiresOfficialSteam:true,launchIsTest:true,steamCompletionRuntime:'playmelt-windows',launchBlockReason:'Le client Steam officiel doit être préparé.',...extra};
 const state={games:[game],runtimes:[],selectedAccountId:'76561198000000001',renderProtectionEnabled:false,windowsRuntime:{status:'ready',readyEngine:true,steamInstalled:false,steamPhase:'failed'},...options.state};
 const context={state,ui:{},$:id=>elements[id],el:node,document:{getElementById:id=>elements[id]||null,querySelectorAll:selector=>selector==='[data-pending-fresh-installation]'?made.filter(n=>n.dataset.pendingFreshInstallation):[]},
  send:(action,payload)=>{sent.push({action,payload});return true},platforms:g=>g.platforms||[],platformLabel:g=>g.platform==='mac'?'Mac':'Windows',storeName:s=>s,
  Option:function(text,value){this.text=text;this.value=value},URL};
 vm.createContext(context);
 const api=vm.runInContext(source.slice(start,end)+';({openGame,refreshVisibleDialog,resolveCardAction,runCardAction,isSteamWindowsGame,steamWindowsView,updateD3DMetalSettings,installJobFor,freshInstallRequest,releaseFreshInstallActions})',context);
 api.openGame(game);
 return {elements,sent,game,state,context,api,body:elements.dialogBody,click(label){const b=button(elements.dialogBody,label);assert(b,'Missing '+label);b.handlers.click?.();return b},text(n=elements.dialogBody){return walk(n).map(x=>x.textContent).join(' ')}};
}

test('payload-only Windows installs show completion, never installed/ready, and use the common pipeline for any app',()=>{
 for(const appId of ['1903340','1250790','999001']){
  const f=fixture({id:'steam:'+appId+':local:fixture',appId});
  assert.equal(f.sent.length,0,'opening a sheet never installs or launches');
  assert(button(f.body,'Terminer l’installation'));
  assert.equal(button(f.body,'Jouer'),undefined);
  assert.match(f.text(f.elements.dialogHeroBadges),/À terminer/);
  assert.doesNotMatch(f.elements.dialogStore.textContent,/Installé/);
  assert.equal(f.api.resolveCardAction(f.game),'Terminer l’installation');
  f.click('Terminer l’installation');f.click('Terminer l’installation');
  assert.equal(f.sent.length,1);
  assert.equal(f.sent[0].action,'installAndPlay');assert.equal(f.sent[0].payload.gameId,f.game.id);
  assert.equal(f.sent[0].payload.runtimeId,'playmelt-windows');
 }
});

test('unknown readiness remains incomplete and a stale affirmative canLaunch cannot override a block reason',()=>{
 for(const canLaunch of [undefined,false,true]){
  const f=fixture({canLaunch});
  assert(button(f.body,'Terminer l’installation'));
  assert.equal(button(f.body,'Jouer'),undefined);
  assert.match(f.text(f.elements.dialogHeroBadges),/À terminer/);
 }
});

test('ready Windows games play directly even with an absent optional DLSS bridge',()=>{
 for(const bridge of ['absent','partial','complete']){
  const f=fixture({canLaunch:true,launchBlockReason:'',requiredRenderer:'d3dmetal',runtimeId:'playmelt-d3dmetal'},
   {state:{windowsRuntime:{d3dMetal:{status:'ready',imported:true,prepared:true,steamInstalled:true,nvidiaBridge:bridge}}}});
  assert(button(f.body,'Jouer'));assert.equal(f.api.resolveCardAction(f.game),'Jouer');
  assert.match(f.text(f.elements.dialogHeroBadges),/Installé/);
  assert.doesNotMatch(f.text(),/Installer le pont|Ouvrir Steam|Importer le composant|Préparer DirectX/);
  assert.equal(f.sent.length,0);f.click('Jouer');assert.equal(f.sent[0].action,'launchGame');
 }
});

test('DX11 and DX12 installation share one entry point, no component installer or engine selector',()=>{
 for(const requiredRenderer of ['dxmt','d3dmetal','auto']){
  const f=fixture({id:'steam:999001',appId:'999001',installed:false,requiresOfficialSteam:false,requiredRenderer,runtimeId:'',rendererNeedsSelection:requiredRenderer==='auto'},
   {state:{windowsRuntime:{status:'missing',readyEngine:false,d3dMetal:{status:'missing',imported:false}}}});
  assert(button(f.body,'Installer'));
  assert.doesNotMatch(f.text(),/Ouvrir Steam|Installer Steam|pont DLSS|DMG|NSIS/);
  assert.equal(walk(f.body).filter(x=>x.tag==='select').length,0);
  f.click('Installer');assert.equal(f.sent[0].action,'installAndPlay');
  assert.equal(f.sent[0].payload.runtimeId,requiredRenderer==='d3dmetal'?'playmelt-d3dmetal':undefined);
 }
});

test('prepared and launch-ready jobs cannot turn payload presence into Play while a launch block remains',()=>{
 for(const status of ['files-prepared','launch-ready']){
  const f=fixture({}, {state:{installJob:{id:'prepared-fixture',gameId:'steam:1250790:local:fixture',status,cancellable:false}}});
  assert(button(f.body,'Terminer l’installation'));assert.equal(button(f.body,'Jouer'),undefined);
  assert.doesNotMatch(f.text(),/Ouvrir Steam|Préparer Steam Windows|pont DLSS/);
  assert.equal(f.sent.length,0);
 }
});

test('automatic post-preparation progresses without exposing another install request or relaunching',()=>{
 const job={id:'post-fixture',gameId:'steam:1250790:local:fixture',status:'preparing-client',cancellable:true};
 const f=fixture({}, {state:{installJob:job}});
 for(const status of ['preparing-client','awaiting-account','preparing-files','awaiting-steam']){
  job.status=status;f.api.refreshVisibleDialog();
  assert.equal(button(f.body,'Installer'),undefined);assert.equal(button(f.body,'Terminer l’installation'),undefined);
  assert.equal(f.sent.length,0);
  assert.match(f.text(f.elements.dialogHeroBadges),/Installation en cours/);
 }
 const phase=f.context.ui.dialogProgress.phase;
 job.message='Connexion au compte attendue';f.api.refreshVisibleDialog();
 assert.equal(f.context.ui.dialogProgress.phase,phase,'a progress update preserves its DOM');
 assert.equal(f.sent.length,0,'state notifications do not restart the pipeline');
});

test('a retained Steam login intent is informative, manually cancellable and cannot prompt another component setup',()=>{
 const f=fixture({}, {state:{windowsRuntime:{status:'ready',readyEngine:true,steamInstalled:false,steamPreparation:{gameId:'steam:1250790:local:fixture',waitingForLogin:true,busy:false}}}});
 assert.match(f.text(),/En attente de connexion Steam/);
 assert(button(f.body,'Arrêter la préparation Steam'));
 assert.equal(button(f.body,'Terminer l’installation'),undefined);
 assert.doesNotMatch(f.text(),/Ouvrir Steam Windows|Installer le pont|Préparer DirectX/);
 f.click('Arrêter la préparation Steam');assert.equal(f.sent[0].action,'cancelInstallAndPlay');
 assert.equal(f.sent[0].payload.gameId,f.game.id);assert.equal(f.sent[0].payload.preparationOnly,true);
});

test('catalog-to-installed identity remains correlated throughout post-preparation without crossing accounts or choosing duplicate copies',()=>{
 const job={id:'correlated',gameId:'steam:1250790',appId:'1250790',accountId:'76561198000000001',runtimeId:'playmelt-windows',status:'files-prepared',cancellable:true};
 const f=fixture({}, {state:{installJob:job}});
 for(const status of ['preparing-client','awaiting-account','preparing-files','awaiting-steam','failed','interrupted']){
  job.status=status;f.api.refreshVisibleDialog();
  assert.equal(f.api.installJobFor(f.game)?.id,'correlated');
  assert.equal(f.context.ui.dialogProgress?.kind,'install');
  assert.equal(button(f.body,'Terminer l’installation'),undefined);
  assert.equal(f.sent.length,0);
 }
 job.accountId='different-account';assert.equal(f.api.installJobFor(f.game),null);
 job.accountId=f.state.selectedAccountId;
 f.state.games.push({...f.game,id:'steam:1250790:local:other'});assert.equal(f.api.installJobFor(f.game),null);
 f.state.games=[f.game];job.runtimeId='steam-mac';assert.equal(f.api.installJobFor(f.game),null);
});

test('failed or interrupted native recovery exposes one correlated explicit retry and never a component button',()=>{
 for(const status of ['failed','interrupted']){
  const job={id:'retry-fixture',gameId:'steam:1250790:local:fixture',status,cancellable:false,recovery:{canRetry:true,action:'retryInstallAndPlay'}};
  const f=fixture({}, {state:{installJob:job}});
  assert.equal(f.sent.length,0);assert(button(f.body,'Reprendre l’installation'));
  f.click('Reprendre l’installation');f.click('Reprendre l’installation');
  assert.equal(f.sent.length,1);assert.equal(f.sent[0].action,'retryInstallAndPlay');
  assert.deepEqual(Object.keys(f.sent[0].payload),['jobId']);assert.equal(f.sent[0].payload.jobId,job.id);
 }
 const f=fixture({}, {state:{installJob:{id:'no-retry',gameId:'steam:1250790:local:fixture',status:'failed',recovery:{canRetry:false}}}});
 assert.equal(button(f.body,'Reprendre l’installation'),undefined);
 f.state.installJob.recovery={canRetry:true,action:'retryInstallAndPlay'};f.api.refreshVisibleDialog();
 assert(button(f.body,'Reprendre l’installation'),'a newly verified recovery appears after a native state refresh');
 f.state.installJob.recovery.canRetry=false;f.api.refreshVisibleDialog();
 assert.equal(button(f.body,'Reprendre l’installation'),undefined,'revoked native recovery disappears without reopening the sheet');
});

test('render protection, stale game readiness and a newly active pipeline veto an old primary action',()=>{
 const protectedView=fixture({}, {state:{renderProtectionEnabled:true}});
 assert.equal(button(protectedView.body,'Terminer l’installation').disabled,true);
 protectedView.click('Terminer l’installation');assert.equal(protectedView.sent.length,0);
 const f=fixture({canLaunch:true,launchBlockReason:''});
 f.game.canLaunch=false;f.game.launchBlockReason='Steam indisponible';f.click('Jouer');
 assert.equal(f.sent.length,0);assert(button(f.body,'Terminer l’installation'));
 const old=button(f.body,'Terminer l’installation');f.state.windowsRuntime.steamPreparation={gameId:f.game.id,busy:true};old.handlers.click();
 assert.equal(f.sent.length,0);assert.equal(button(f.body,'Terminer l’installation'),undefined);
});

test('native Mac, Epic and GOG keep their existing actions; advanced engine controls remain in Settings',()=>{
 for(const game of [{store:'steam',platform:'mac',platforms:['mac'],runtimeId:'steam-mac',canLaunch:true,launchBlockReason:''},
  {store:'epic',platform:'windows',canLaunch:true,launchBlockReason:''},{store:'gog',platform:'windows',canLaunch:true,launchBlockReason:''}]){
  const f=fixture({...game,requiresOfficialSteam:false,launchIsTest:false});
  assert.equal(f.api.isSteamWindowsGame(f.game),false);assert(button(f.body,'Jouer'));
  f.click('Jouer');assert.equal(f.sent[0].action,'launchGame');
 }
 const f=fixture({}, {state:{windowsRuntime:{d3dMetal:{status:'ready',imported:true,prepared:true,steamInstalled:true,nvidiaBridge:'absent'}}}});
 const target={dataset:{},replaceChildren(...children){this.children=children}};
 f.api.updateD3DMetalSettings(target);
 assert(button(target,'Ouvrir Steam DirectX 12'));
 assert(button(target,'Installer le pont DLSS → MetalFX'));
});

function stoppedRequest(jobExtra={},gameExtra={},stateExtra={}){
 const account='76561198000000001',id='steam:1903340:local:fixture';
 const job={id:'legacy-stopped-fixture',gameId:id,appId:'1903340',accountId:account,store:'steam',runtimeId:'playmelt-d3dmetal',status:'failed',phase:'Échec',
  error:{code:'cancelled',retryable:false},autoLaunch:false,restored:true,stages:[],cancellable:false,
  message:'La tentative précédente est arrêtée. Une reprise manuelle est nécessaire.',recovery:{action:'retryInstallAndPlay',canRetry:false,reason:'Aucune reprise autorisée pour cet état ou ce contexte.'},...jobExtra};
 return fixture({id,appId:'1903340',runtimeId:'playmelt-d3dmetal',requiredRenderer:'d3dmetal',...gameExtra},{state:{
  installJob:job,accounts:[{id:account}],runtimes:[{id:'playmelt-d3dmetal',platform:'windows',executionAllowed:true}],...stateExtra}});
}

test('the actual restored cancelled shape offers a new explicit completion request without replaying old authority',()=>{
 const f=stoppedRequest(),before=JSON.stringify(f.state.installJob);
 assert.equal(f.sent.length,0);assert(button(f.body,'Terminer l’installation'));
 assert.equal(button(f.body,'Reprendre l’installation'),undefined);
 f.click('Terminer l’installation');f.click('Terminer l’installation');
 assert.equal(f.sent.length,1);assert.equal(f.sent[0].action,'installAndPlay');
 assert.equal(f.sent[0].payload.gameId,f.game.id);assert.equal(f.sent[0].payload.runtimeId,'playmelt-d3dmetal');
 assert.deepEqual(Object.keys(f.sent[0].payload).sort(),['gameId','runtimeId']);
 assert.equal(JSON.stringify(f.state.installJob),before,'the old cancellation and autoLaunch=false are untouched');
});

test('historical security/account/runtime failure cannot permanently veto a new current-context request',()=>{
 for(const code of ['access_required','account_changed','corrupt_manifest','cancelled']){
  const f=stoppedRequest({restored:false,error:{code,retryable:false},stages:[{id:'engine',status:'failed'}],accountId:'old-account',runtimeId:'playmelt-windows'});
  assert(button(f.body,'Terminer l’installation'));
  f.click('Terminer l’installation');
  assert.equal(f.sent[0].action,'installAndPlay');assert.equal(f.sent[0].payload.runtimeId,'playmelt-d3dmetal');
  assert.deepEqual(Object.keys(f.sent[0].payload).sort(),['gameId','runtimeId'],'native authorization receives only the new current request');
 }
});

test('a fresh terminal request still requires a present current game/account/runtime and no active protection or pipeline',()=>{
 const cases=[()=>stoppedRequest({}, {}, {accounts:[]}),()=>stoppedRequest({}, {}, {runtimes:[]}),
  ()=>stoppedRequest({}, {}, {runtimes:[{id:'playmelt-d3dmetal',platform:'windows',executionAllowed:false}]}),
  ()=>stoppedRequest({}, {}, {renderProtectionEnabled:true}),
  ()=>stoppedRequest({}, {}, {windowsRuntime:{steamPreparation:{gameId:'another-game',busy:true}}}),
  ()=>stoppedRequest({}, {installBlockReason:'Licence du jeu à vérifier'}),
  ()=>stoppedRequest({status:'preparing-client',cancellable:true})];
 for(const make of cases){const f=make();assert.equal(button(f.body,'Terminer l’installation'),undefined);assert.equal(f.sent.length,0);}
 const f=stoppedRequest();const old=button(f.body,'Terminer l’installation');
 f.state.selectedAccountId='76561198000000002';f.state.accounts=[{id:f.state.selectedAccountId}];old.handlers.click();
 assert.equal(f.sent.length,0,'an already-rendered action cannot silently switch accounts');
 f.state.selectedAccountId='76561198000000001';f.state.accounts=[{id:f.state.selectedAccountId}];
 f.state.games=[];old.handlers.click();assert.equal(f.sent.length,0,'a removed game cannot be started from a stale sheet');
});

test('current qualified recovery stays a job retry; an old-account recovery becomes a separate new request',()=>{
 const recovery={canRetry:true,action:'retryInstallAndPlay'};
 const same=stoppedRequest({recovery});
 assert(button(same.body,'Reprendre l’installation'));assert.equal(button(same.body,'Terminer l’installation'),undefined);
 same.click('Reprendre l’installation');assert.equal(same.sent[0].action,'retryInstallAndPlay');
 const changed=stoppedRequest({recovery,accountId:'old-account'});
 assert.equal(button(changed.body,'Reprendre l’installation'),undefined);changed.click('Terminer l’installation');
 assert.equal(changed.sent[0].action,'installAndPlay');assert.equal('jobId' in changed.sent[0].payload,false);
});

test('the terminal card starts a qualified fresh completion once instead of reopening the same dead-end sheet',()=>{
 const f=stoppedRequest(),trigger={disabled:false};
 f.api.runCardAction(f.game,{currentTarget:trigger,stopPropagation(){}});
 f.api.runCardAction(f.game,{currentTarget:trigger,stopPropagation(){}});
 assert.equal(f.sent.length,1);assert.equal(f.sent[0].action,'installAndPlay');assert.equal(trigger.disabled,true);
});

test('a native refusal releases a pending fresh action for another explicit request, without auto-sending',()=>{
 const f=stoppedRequest();const action=f.click('Terminer l’installation');
 assert.equal(action.disabled,true);assert.equal(f.sent.length,1);
 f.api.releaseFreshInstallActions();assert.equal(action.disabled,false);assert.equal(f.sent.length,1);
 f.click('Terminer l’installation');assert.equal(f.sent.length,2);assert.equal(f.sent[1].action,'installAndPlay');
});

test('GOG observed operations use the same detail and strict store identity without any managed command',()=>{
 const id='gog:1423049311',gog={id:'gog:1423049311:fixture',gameId:id,appId:'1423049311',store:'gog',platform:'mac',runtimeId:'gog-mac',status:'installing',phase:'Installation GOG Galaxy',observed:true,cancellable:true,autoLaunch:false,
  recovery:{canRetry:true,action:'retryInstallAndPlay'},stages:[{id:'client',status:'active',progress:null}],bytesDownloaded:null,bytesTotal:68606283631};
 const f=fixture({id,appId:'1423049311',store:'gog',platform:'mac',platforms:['mac'],installed:false,canLaunch:false,requiresOfficialSteam:false},{state:{installJob:null,installJobs:[gog]}});
 assert.equal(f.api.installJobFor(f.game),gog);assert.match(f.text(),/Installation GOG Galaxy/);
 assert.equal(button(f.body,'Arrêter le suivi'),undefined);assert.equal(button(f.body,'Reprendre l’installation'),undefined);
 assert.doesNotMatch(f.text(),/Ouvrir GOG|Lancer via GOG|Préparer Steam|0 %/);
 f.api.runCardAction(f.game,{stopPropagation(){}});assert.equal(f.sent.length,0);
 const wrong={...gog,store:'steam'};f.state.installJobs=[wrong];f.api.refreshVisibleDialog();
 assert.equal(f.api.installJobFor(f.game),null);assert.doesNotMatch(f.text(),/Ouvrir GOG|Lancer via GOG/);assert.equal(f.sent.length,0);
});


test('GOG file removal requires the verified native capability and never promises a Galaxy uninstall',()=>{
 for(const canRemoveFiles of [undefined,false,true]){
  const f=fixture({id:'gog:1423049311',appId:'1423049311',store:'gog',platform:'mac',platforms:['mac'],installed:true,canLaunch:true,launchBlockReason:'',requiresOfficialSteam:false,canRemoveFiles});
  const removal=walk(f.body).find(n=>n.tag==='button'&&n.cls==='dialog-subtle-uninstall-btn');
  assert(removal);assert.match(removal.innerHTML,/Retirer les fichiers/);assert.doesNotMatch(removal.innerHTML,/Désinstaller/);
  assert.equal(removal.disabled,canRemoveFiles!==true);removal.handlers.click();
  assert.equal(f.sent.length,canRemoveFiles===true?1:0);
  if(canRemoveFiles===true){assert.equal(f.sent[0].action,'uninstallGame');assert.equal(f.sent[0].payload.gameId,f.game.id);f.game.canRemoveFiles=false;removal.handlers.click();assert.equal(f.sent.length,1,'stale capabilities cannot dispatch removal');}
  else assert.match(f.text(),/dossier du jeu doit être vérifié/);
 }
 const steam=fixture({platform:'mac',platforms:['mac'],runtimeId:'steam-mac',canLaunch:true,launchBlockReason:'',requiresOfficialSteam:false});
 assert.match(walk(steam.body).find(n=>n.tag==='button'&&n.cls==='dialog-subtle-uninstall-btn').innerHTML,/Désinstaller/);
});


test('terminal GOG history no longer hides the native installed-game actions or removal capability',()=>{
 for(const status of ['launch-ready','failed','error','interrupted','cancelled','timed-out','completed']){
  for(const canRemoveFiles of [true,false,undefined]){
   const id='gog:1423049311',job={id:'gog:1423049311:history',gameId:id,store:'gog',status,observed:true,stages:[{id:'client',status:'completed'}]};
   const f=fixture({id,appId:'1423049311',store:'gog',platform:'mac',platforms:['mac'],installed:true,canLaunch:true,canRemoveFiles,launchBlockReason:'',requiresOfficialSteam:false,launchIsTest:false},{state:{installJobs:[job]}});
   const removal=walk(f.body).find(n=>n.tag==='button'&&n.cls==='dialog-subtle-uninstall-btn');assert(removal,status);assert.match(removal.innerHTML,/Retirer les fichiers/);assert.equal(removal.disabled,canRemoveFiles!==true);
   assert(button(f.body,'Jouer'));assert.equal(f.context.ui.dialogProgress,null);assert.equal(f.api.resolveCardAction(f.game),'Jouer');assert.equal(f.sent.length,0,'opening a terminal history never removes or launches anything');
  }
 }
});

test('a removed native GOG directory leaves only cold waiting history and never blocks the ordinary game page',()=>{
 const id='gog:1423049311',job={id:'gog:1423049311:installed-fixture',gameId:id,store:'gog',status:'waiting',observed:true,provenance:{kind:'galaxy-installed-registration'},stages:[{id:'client',status:'waiting'}]};
 const f=fixture({id,appId:'1423049311',store:'gog',platform:'mac',platforms:['mac'],installed:false,canLaunch:false,canRemoveFiles:false,requiresOfficialSteam:false,launchIsTest:false},{state:{installJobs:[job]}});
 assert.equal(f.context.ui.dialogProgress,null);assert.match(f.text(),/Aucune installation GOG active ou terminée n’est confirmée/);assert.equal(f.api.installJobFor(f.game),job,'history is retained');assert.equal(f.api.resolveCardAction(f.game),'Voir le jeu');assert.equal(f.sent.length,0);
});

test('observed GOG waiting history leaves current native launch/removal flags authoritative',()=>{const id='gog:1423049311',job={id:'gog:1423049311:1',gameId:id,store:'gog',status:'waiting',observed:true,provenance:{kind:'galaxy-local-jobs'},stages:[{id:'client',status:'waiting'}]};const f=fixture({id,appId:'1423049311',store:'gog',platform:'mac',platforms:['mac'],installed:true,canLaunch:false,canRemoveFiles:false,requiresOfficialSteam:false,launchIsTest:false},{state:{installJobs:[job]}});assert.equal(f.context.ui.dialogProgress,null);const removal=walk(f.body).find(n=>n.tag==='button'&&n.cls==='dialog-subtle-uninstall-btn');assert.equal(removal.disabled,true);assert.equal(button(f.body,'Jouer'),undefined);assert.equal(f.api.installJobFor(f.game),job);assert.equal(f.sent.length,0);});
