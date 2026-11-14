'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {create}=require('../Resources/AccountLogin.js');
function node(tag,cls='',text=''){
 return {tag,cls,textContent:text,children:[],handlers:{},classList:{toggle(){}},value:'',open:false,append(...items){this.children.push(...items)},setAttribute(k,v){this[k]=v},addEventListener(k,fn){this.handlers[k]=fn},focus(){this.focused=true},showModal(){this.open=true},close(){this.open=false;this.handlers.close?.()}};
}
function fixture(account={},afterIntro){
 const state={account:{configured:true,serviceReady:true,passwordLoginReady:true,signedIn:false,enabled:true,...account}},body=node('body'),sent=[],timers=new Map();let clock=1000,counter=0,signed=0;
 const control=create({el:node,getState:()=>state,send:(...args)=>sent.push(args),document:{body},clock:()=>clock,setTimer:fn=>{timers.set(++counter,fn);return counter},clearTimer:id=>timers.delete(id),onSignedIn:()=>signed++,afterIntro});
 const all=n=>[n,...n.children.filter(x=>typeof x==='object').flatMap(all)];
 return {state,body,sent,timers,control,rows:()=>all(body),find:fn=>all(body).find(fn),tick(value){clock=value;const pending=[...timers.values()];timers.clear();pending.forEach(fn=>fn())},signed:()=>signed};
}
test('a published password flow opens a local form without pairing codes',()=>{
 const f=fixture({userCode:'ABCDEF1234'});f.control.sync();
 assert(f.find(n=>n.tag==='dialog').open);assert(f.find(n=>n.name==='email').focused);assert.equal(f.find(n=>n.name==='password').type,'password');
 assert(!f.rows().some(n=>n.textContent.includes('ABCDEF1234')));assert.deepEqual(f.sent,[]);
 const close=f.find(n=>n['aria-label']==='Fermer la connexion');assert(close.hidden);
 let prevented=false;f.find(n=>n.tag==='dialog').handlers.cancel({preventDefault(){prevented=true}});assert(prevented);
});
test('existing credentials never produce a new login form or logout',()=>{
 const f=fixture({signedIn:true});f.control.sync();assert.equal(f.body.children.length,0);assert.deepEqual(f.sent,[]);
 f.control.open();assert.deepEqual(f.sent,[['refreshPlaymelt']]);
});
test('a disabled service cannot send credentials or auto-open a form',()=>{
 const f=fixture({passwordLoginReady:false});f.control.sync();assert.equal(f.body.children.length,0);
 f.control.open();assert(f.find(n=>n.type==='submit').disabled);
 f.find(n=>n.name==='email').value='fixture@example.invalid';f.find(n=>n.name==='password').value='fixture-password';f.find(n=>n.tag==='form').handlers.submit({preventDefault(){}});assert.deepEqual(f.sent,[]);
});
test('a login submits only Playmelt fields and erases the password',()=>{
 const f=fixture();f.control.sync();const email=f.find(n=>n.name==='email'),password=f.find(n=>n.name==='password');
 email.value=' fixture@example.invalid ';password.value=' fixture password ';
 f.find(n=>n.tag==='form').handlers.submit({preventDefault(){}});
 assert.deepEqual(f.sent,[['signInPlaymelt',{email:'fixture@example.invalid',password:' fixture password '}]]);assert.equal(password.value,'');
 f.state.account.pending=true;f.state.account.message='Connexion…';f.control.sync();assert.equal(f.find(n=>n.name==='email'),email);assert.equal(email.value,' fixture@example.invalid ');assert(f.find(n=>n.type==='submit').disabled);
 f.state.account={...f.state.account,pending:false,signedIn:true};f.control.sync();assert(!f.find(n=>n.tag==='dialog').open);assert.equal(f.signed(),1);f.control.sync();assert.equal(f.signed(),1);
});
test('cooldown creates one bounded timer and closes without leaving a timer',()=>{
 const f=fixture({enabled:false,loginRetryAt:3});f.control.sync();assert(f.find(n=>n.type==='submit').disabled);assert.equal(f.timers.size,1);
 f.tick(3100);assert(!f.find(n=>n.type==='submit').disabled);assert.equal(f.timers.size,0);
 f.state.account.loginRetryAt=6;f.control.sync();assert.equal(f.timers.size,1);f.control.close();assert.equal(f.timers.size,0);
});
test('registration and password reset use explicit account actions',()=>{
 const f=fixture();f.control.sync();f.find(n=>n.textContent==='Créer mon compte').handlers.click();f.find(n=>n.textContent==='Mot de passe oublié').handlers.click();
 assert.deepEqual(f.sent,[['openPlaymeltAccount',{section:'registration'}],['openPlaymeltAccount',{section:'password'}]]);
});
test('Google is hidden until the native state confirms availability',()=>{
 const f=fixture();f.control.sync();const google=f.find(n=>n.cls==='login-google');assert(google.hidden);google.handlers.click();assert.deepEqual(f.sent,[]);
 f.state.account.googleLoginReady=true;f.control.sync();assert(!google.hidden);f.find(n=>n.name==='password').value='erase-on-google';google.handlers.click();assert.deepEqual(f.sent,[['signInPlaymeltGoogle']]);assert.equal(f.find(n=>n.name==='password').value,'');
 f.state.account.pending=true;f.control.sync();assert(google.disabled);google.handlers.click();assert.equal(f.sent.length,1);
});
test('closing a Google attempt cancels its own browser flow',()=>{
 const f=fixture({enabled:false,googleLoginReady:true});f.control.sync();f.find(n=>n.cls==='login-google').handlers.click();f.control.close();assert.deepEqual(f.sent,[['signInPlaymeltGoogle'],['cancelPlaymeltGoogle']]);assert.equal(f.timers.size,0);
});
test('Google availability does not enable an unavailable password endpoint',()=>{
 const f=fixture({passwordLoginReady:false,googleLoginReady:true});f.control.sync();assert(f.find(n=>n.tag==='dialog').open);assert(f.find(n=>n.type==='submit').disabled);assert(!f.find(n=>n.cls==='login-google').disabled);
 f.find(n=>n.name==='email').value='fixture@example.invalid';f.find(n=>n.name==='password').value='not-sent';f.find(n=>n.tag==='form').handlers.submit({preventDefault(){}});assert.deepEqual(f.sent,[]);
});
test('Google is the primary action while email remains available on request',()=>{
 const f=fixture({googleLoginReady:true});f.control.sync();const google=f.find(n=>n.cls==='login-google');assert(google.children.some(n=>n.tag==='span'&&n.textContent==='Continuer avec Google'),'Google accessible label stays inside its button');assert(f.find(n=>n.tag==='form').hidden);assert(f.find(n=>n.cls==='login-google').focused);const toggle=f.find(n=>n.cls==='login-email-toggle');assert.equal(toggle['aria-expanded'],'false');toggle.handlers.click();assert(!f.find(n=>n.tag==='form').hidden);assert(f.find(n=>n.name==='email').focused);
});
test('the login waits for the short intro without sending a request',()=>{
 let release,callbacks=0;const f=fixture({googleLoginReady:true},fn=>{release=fn;callbacks++});f.control.sync();f.control.sync();assert.equal(callbacks,1);assert(!f.find(n=>n.tag==='dialog').open);assert.deepEqual(f.sent,[]);release();assert(f.find(n=>n.tag==='dialog').open);assert(f.find(n=>n.cls==='login-google').focused);
});
