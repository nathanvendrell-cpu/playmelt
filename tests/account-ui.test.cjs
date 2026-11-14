'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {presentation}=require('../Resources/Account.js');
test('account status distinguishes service readiness, trial, lifetime and verification',()=>{
 const ready={configured:true,serviceReady:true,signedIn:true,accessVerified:true};
 assert.equal(presentation({}).label,'Ouverture prochaine');
 assert.equal(presentation({...ready,signedIn:false}).label,'Compte à connecter');
 const life=presentation({...ready,phase:'active',plan:'lifetime',expiresAt:0});assert.equal(life.label,'Accès à vie');assert.equal(life.manageLabel,'Gérer mon compte');assert(life.verified);assert(!life.detail.includes('1970'));
 const unverified=presentation({...ready,phase:'active',plan:'lifetime',accessVerified:false});assert(!unverified.verified);assert.match(unverified.detail,/confirmer/);
 const trial=presentation({...ready,phase:'trialing',plan:'monthly',expiresAt:1800000000});assert.match(trial.detail,/Essai jusqu’au/);
 const promo=presentation({...ready,phase:'active',plan:'promotional',expiresAt:1800000000});assert.equal(promo.label,'Accès promotionnel');assert.equal(promo.manageLabel,'Gérer mon compte');assert.match(promo.detail,/Jusqu’au/);assert(promo.verified);
 assert.equal(presentation({...ready,phase:'inactive',plan:'promotional'}).label,'Accès à activer');
 assert(!presentation({...ready,phase:'inactive',plan:'lifetime'}).active);
});
function node(tag,cls='',text=''){
 return {tag,cls,textContent:text,children:[],dataset:{},handlers:{},style:{},classList:{add(){},toggle(){}},append(...items){this.children.push(...items)},replaceChildren(...items){this.children=items},setAttribute(k,v){this[k]=v},addEventListener(k,f){this.handlers[k]=f},querySelectorAll(selector){return this.children.filter(x=>selector==='button'&&x.tag==='button')},showModal(){this.open=true},close(){this.open=false}};
}
function fixture(account){
 const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8'),start=html.indexOf('        const euros ='),end=html.indexOf('        $("subscriptionClose")',start),sent=[];
 const elements={subscriptionBody:node('div'),subscriptionDialog:node('dialog'),subscriptionStatus:node('p')};
 const context={window:{PlaymeltAccount:{presentation}},state:{account,plans:[{id:'monthly',label:'1 mois',months:1,priceCents:1999},{id:'annual',label:'1 an',months:12,priceCents:16799},{id:'lifetime',label:'À vie',priceCents:39900}]},ui:{},el:node,$:id=>elements[id],document:{createTextNode:x=>node('text','',x)},ICON:{check:'✓'},send:(...args)=>sent.push(args)};
 vm.createContext(context);vm.runInContext(html.slice(start,end)+'\nopenSubscription();',context);
 const all=n=>[n,...n.children.filter(x=>typeof x==='object').flatMap(all)];return {elements,sent,rows:all(elements.subscriptionBody)};
}
test('prepared service allows reviewing plans but cannot submit activation or checkout',()=>{
 const f=fixture({configured:true,serviceReady:false});assert(f.elements.subscriptionDialog.open);
 assert(f.rows.find(n=>n.tag==='button'&&n.textContent==='Bientôt disponible').disabled);
 assert(f.rows.find(n=>n.tag==='button'&&n.textContent==='Activer un code').disabled);
 assert(!f.rows.some(n=>n.tag==='input'));assert.deepEqual(f.sent,[]);
});
test('plan and activation actions use the same account destination',()=>{
 const f=fixture({configured:true,serviceReady:true,signedIn:false});
 f.rows.find(n=>n.tag==='button'&&n.textContent==='Continuer vers mon compte').handlers.click();
 assert.equal(f.sent[0][0],'openPlaymeltAccount');assert.equal(f.sent[0][1].plan,'annual');
 f.rows.find(n=>n.tag==='button'&&n.textContent==='Activer un code').handlers.click();assert.equal(f.sent[1][1].section,'activation');
});
test('verified lifetime licence presents account management without a purchase CTA',()=>{
 const f=fixture({configured:true,serviceReady:true,signedIn:true,phase:'active',plan:'lifetime',accessVerified:true});
 assert(f.rows.some(n=>n.textContent==='Accès à vie'));assert(!f.rows.some(n=>n.textContent==='Continuer vers mon compte'));
 f.rows.find(n=>n.tag==='button'&&n.textContent==='Gérer mon compte').handlers.click();assert.equal(f.sent[0][0],'openPlaymeltAccount');assert.equal(f.sent[0].length,1);
});
