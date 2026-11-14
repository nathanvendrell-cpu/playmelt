'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function block(start,end){const a=html.indexOf(start),b=html.indexOf(end,a);assert.ok(a>0&&b>a);return html.slice(a,b);}
const helpers=block('        function installationJobs()','        function installJobFor(game)')+block('        function jobPhase(job) {','        function steamCompletionSignature');
function setup(extra={}){const context={...extra};vm.createContext(context);vm.runInContext(helpers,context);return context;}
const stages=()=>[
 {id:'engine',label:'ignored',status:'completed',progress:1},
 {id:'download',status:'completed',progress:1,completedUnits:2048,totalUnits:2048,unit:'bytes'},
 {id:'prepare',status:'completed',progress:1,completedUnits:20,totalUnits:20,unit:'files'},
 {id:'verify',status:'active',progress:.25,completedUnits:5,totalUnits:20,unit:'files'},
];
test('validating is Verification even when the legacy phase, percentage and byte counters still describe a download',()=>{
 const c=setup(),job={status:'validating',phase:'Téléchargement',progress:.82,bytesDownloaded:82,bytesTotal:100,speed:'0 Mo/s',activeStage:'download'};
 assert.equal(c.jobPhase(job),'Vérification');assert.equal(c.jobRatio(job),null);
 const markup=c.installStagesMarkup(job);assert.match(markup,/Vérification/);assert.match(markup,/data-mode="indeterminate"/);
 assert.doesNotMatch(markup,/Téléchargement|82 %|0 Mo\/s|aria-valuenow=/);
});
test('each observed step has its own bar and measurement; completed stages remain distinct from the current verification',()=>{
 const c=setup(),job={status:'validating',phase:'Téléchargement',progress:.82,activeStage:'verify',stages:stages()};
 const markup=c.installStagesMarkup(job,'manager');assert.equal((markup.match(/role="progressbar"/g)||[]).length,4);
 assert.equal(c.jobRatio(job),.25);assert.match(markup,/5 \/ 20 fichiers/);assert.match(markup,/data-stage="download" data-state="completed"/);
 assert.match(markup,/data-stage="verify" data-state="active"/);assert.match(markup,/25 %/);assert.doesNotMatch(markup,/82 %/);
 assert.equal((markup.match(/Terminée/g)||[]).length>=3,true);
});
test('unknown preparation, components and client work is indeterminate only while active, with no invented percentage',()=>{
 const c=setup();
 for(const id of ['prepare','components','client']){
  const active=c.installStagesMarkup({status:id==='prepare'?'preparing-files':id==='client'?'preparing-client':'configuring',activeStage:id,stages:[{id,status:'active',progress:null}]});
  assert.match(active,/data-mode="indeterminate"/);assert.match(active,/Progression non mesurée/);assert.doesNotMatch(active,/aria-valuenow=|\d+ %/);
 }
 const waiting=c.installStagesMarkup({status:'awaiting-account',stages:[{id:'client',status:'waiting',progress:null}]});
 assert.match(waiting,/En attente/);assert.doesNotMatch(waiting,/data-mode="indeterminate"|En cours|aria-valuenow=/);
});
test('measured units determine copy and verification progress without borrowing the global percentage',()=>{
 const c=setup(),copy={status:'preparing-files',progress:.82,activeStage:'prepare',stages:[{id:'prepare',status:'active',progress:null,completedUnits:3,totalUnits:12,unit:'files'}]};
 assert.equal(c.jobRatio(copy),.25);assert.match(c.installStagesMarkup(copy),/3 \/ 12 fichiers/);
 const bytes={status:'validating',activeStage:'verify',stages:[{id:'verify',status:'active',progress:null,completedUnits:1024,totalUnits:4096,unit:'verified-bytes'}]};
 assert.equal(c.jobRatio(bytes),.25);assert.match(c.installStagesMarkup(bytes),/1 \/ 4 Kio vérifiés/);
 const overflow={status:'validating',activeStage:'verify',stages:[{id:'verify',status:'active',progress:1,completedUnits:130,totalUnits:100,unit:'files'}]};
 assert.equal(c.jobRatio(overflow),null);assert.match(c.installStagesMarkup(overflow),/130 \/ 100 fichiers · mesure à vérifier/);assert.doesNotMatch(c.installStagesMarkup(overflow),/aria-valuenow=|100 %/);
});
test('failures and cancellations freeze the current bar and preserve completed stage history',()=>{
 const c=setup();
 for(const status of ['failed','cancelled','timed-out','interrupted','paused','disk-space']){
  const job={status,activeStage:'verify',stages:stages()},markup=c.installStagesMarkup(job);
  assert.equal(c.jobRatio(job),null);assert.doesNotMatch(markup,/data-mode="indeterminate"|data-state="active"/);
  assert.match(markup,/data-stage="download" data-state="completed"/);assert.match(markup,/25 %/);
  assert.equal((markup.match(/role="progressbar"/g)||[]).length,4);
 }
});
test('restoration preserves known completed statuses with unknown counters and never fabricates zero or full progress',()=>{
 const c=setup(),restored=stages().map(row=>({id:row.id,status:row.status==='active'?'waiting':row.status,progress:null}));
 const markup=c.installStagesMarkup({status:'interrupted',stages:restored});
 assert.match(markup,/Terminée/);assert.match(markup,/Reprise requise/);assert.doesNotMatch(markup,/aria-valuenow=|\d+ %|data-mode="indeterminate"/);
});
test('untrusted stage labels, identifiers, units and invalid metrics cannot inject markup or become made-up progress',()=>{
 const c=setup(),payload='<img src=x onerror="bad()">',job={status:'validating',stages:[
  {id:'verify',label:payload,status:'active',progress:payload,completedUnits:1,totalUnits:2,unit:payload},
  {id:payload,label:payload,status:'active',progress:1},
  {id:'client',status:payload,progress:1}
 ]};
 const markup=c.installStagesMarkup(job);assert.equal((markup.match(/role="progressbar"/g)||[]).length,1);
 assert.doesNotMatch(markup,/<img|onerror|aria-valuenow=/);assert.match(markup,/Progression non mesurée/);
});
test('the detail patches Verification and its own bars while hiding stale transfer speed',()=>{
 const job={id:'job',status:'validating',phase:'Téléchargement',progress:.82,speed:'0 Mo/s',bytesDownloaded:82,bytesTotal:100,message:'Vérification des fichiers',activeStage:'verify',stages:stages(),cancellable:true};
 const refs={kind:'install',gameId:'game',jobId:'job',terminal:false,cancellable:true,launchRequested:false,phase:{textContent:''},percent:{textContent:'82 %'},progress:null,stages:{innerHTML:''},stats:{textContent:'0 Mo/s'},note:{textContent:''}};
 const c=setup({ui:{dialogProgress:refs,dialogGameId:'game'},state:{games:[]}});
 vm.runInContext(block('        function patchProgressValues(','        function patchRuntimeProgress(')+block('        function patchInstallProgress(','        function refreshVisibleDialog()'),c);
 assert.equal(c.patchInstallProgress(job),true);assert.equal(refs.phase.textContent,'Vérification');assert.equal(refs.percent.textContent,'25 %');
 assert.equal(refs.stats.hidden,true);assert.equal(refs.stats.textContent,'');assert.match(refs.stages.innerHTML,/5 \/ 20 fichiers/);
});
test('the compact HUD shares the actual verification stage and freezes history on failure',()=>{
 const elements={};
 function element(className=''){return {className,children:[],classList:{toggle(){}},textContent:'',style:{},attributes:{},parentElement:{hidden:false},setAttribute(k,v){this.attributes[k]=v;},append(child){this.children.push(child);},querySelector(selector){return this.children.find(child=>'.'+child.className===selector)||null;}};}
 for(const id of ['installJobButton','installationHUD','hudTitle','hudStatus','hudPct','hudBarFill','hudSpeed','hudEta','hudDetails','hudOpen','hudMinimize','hudClose'])elements[id]=element();
 const job={id:'job',gameId:'game',title:'Jeu',status:'validating',phase:'Téléchargement',progress:.82,speed:'0 Mo/s',bytesDownloaded:82,bytesTotal:100,activeStage:'verify',stages:stages()};
 const c=setup({state:{installJob:job,games:[{id:'game',title:'Jeu'}]},ui:{view:'library'},$:id=>elements[id],el:(_tag,className)=>element(className),document:{querySelectorAll:()=>[]},imageSources:()=>[],renderProtectionEnabled:()=>false});
 vm.runInContext(block('        function updateJobIndicator() {','        function resolveCardAction('),c);c.updateJobIndicator();
 assert.equal(elements.hudStatus.textContent,'Vérification');assert.equal(elements.hudPct.textContent,'25 %');assert.equal(elements.hudSpeed.textContent,'');assert.equal(elements.hudBarFill.parentElement.hidden,true);
 const history=elements.hudDetails.querySelector('.hud-stage-history');assert.equal((history.innerHTML.match(/role="progressbar"/g)||[]).length,4);
 c.state.installJob={...job,status:'failed'};c.updateJobIndicator();
 assert.equal(elements.installationHUD.hidden,false);assert.equal(elements.installationHUD.attributes['aria-busy'],'false');
 assert.doesNotMatch(history.innerHTML,/data-mode="indeterminate"|data-state="active"/);assert.match(history.innerHTML,/data-stage="download" data-state="completed"/);
});
