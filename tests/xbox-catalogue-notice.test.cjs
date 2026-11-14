'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const html=fs.readFileSync(process.env.PLAYMELT_XBOX_PATCHED_INDEX||path.join(__dirname,'../index.html'),'utf8');
const match=html.match(/          const xboxNotice=\$\("xboxCatalogNotice"\);[\s\S]*?\n          if \(ui.view === "xbox"\) \{/);
assert(match,'Xbox catalogue notice owner patch must be integrated');
const source=match[0].replace(/\n          if \(ui.view === "xbox"\) \{$/,'');
function render(xbox,view='xbox') { const notice={}; vm.runInNewContext(source,{$:()=>notice,state:{xbox},ui:{view}});return notice; }
test('warm cache failure is visible while Microsoft is disconnected',()=>{
 const message='Actualisation impossible. Dernier catalogue conservé : 2030-03-17.';
 const n=render({authenticated:false,catalogError:'incomplete',catalogStale:true,message});assert.equal(n.hidden,false);assert.equal(n.textContent,message);
});
test('same error is visible while connected; successful recovery hides it',()=>{
 assert.equal(render({authenticated:true,catalogError:'incomplete',message:'cached'}).hidden,false);
 assert.equal(render({catalogError:'',catalogStale:false,message:'ready'}).hidden,true);
});
test('stale catalogue remains visible without an error and other sections hide the Xbox notice',()=>{
 assert.equal(render({catalogStale:true,message:'last good date'}).hidden,false);
 assert.equal(render({catalogError:'incomplete',message:'cached'},'steam').hidden,true);
});
