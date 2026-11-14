'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../Resources/Settings.js'),'utf8');
function node(tag,cls,text='') {return {tag,cls,textContent:text,children:[],handlers:{},style:{setProperty(){}},classList:{add(){}},isConnected:true,
 append(...items){this.children.push(...items);},replaceChildren(...items){this.children=items;},setAttribute(){},addEventListener(k,fn){this.handlers[k]=fn;},get childElementCount(){return this.children.length;}};}
let state={games:[{store:'steam'},{store:'epic'},{store:'gog'}],libraryStatus:{status:'snapshot'},services:{}};
const context={window:{},localStorage:{getItem:()=>null,setItem(){}}};vm.runInNewContext(source,context);
const panel=node('section',''),calls=[];
const settings=context.window.PlaymeltSettings.create({el:node,getState:()=>state,send:(...args)=>calls.push(args),openLink(){},goProfile(){},renderMachine(){}});
function rows(){settings.render(panel);const result={};function visit(n){if(n.cls==='settings-platform'||n.cls==='settings-platform is-on'){result[n.children[1].children[0].textContent]={status:n.children[2].textContent,detail:n.children[1].children[1].textContent};}for(const child of n.children||[])visit(child);}visit(panel);return result;}
let rendered=rows();
assert.equal(rendered.Steam.status,'À vérifier');
assert.equal(rendered['Epic Games'].status,'À connecter');
assert.equal(rendered['Xbox Game Pass'].status,'À connecter');
assert.equal(rendered.GOG.status,'À connecter');
state={...state,libraryStatus:{status:'synced'},xbox:{authenticated:true},gog:{available:true,authenticated:false,message:'Cache local, session distante non vérifiée'},epic:{authenticated:true,credentialStorage:'memory',message:'Session en mémoire uniquement'}};
rendered=rows();assert.equal(rendered.Steam.status,'Connecté');assert.equal(rendered['Xbox Game Pass'].status,'Session détectée');assert.equal(rendered.GOG.status,'Cache local');assert.equal(rendered['Epic Games'].status,'Session temporaire');assert.match(rendered['Epic Games'].detail,/mémoire uniquement/);
state.epic={authenticated:true,credentialStorage:'memory',message:'252 jeux dans la bibliothèque Epic.',storageError:'Trousseau indisponible (code -34018).'};
rendered=rows();assert.equal(rendered['Epic Games'].status,'Session temporaire');assert.match(rendered['Epic Games'].detail,/code -34018/);assert(!rendered['Epic Games'].detail.includes('252 jeux'));
state.epic={authenticated:true,credentialStorage:'keychain',message:'Session conservée dans le Trousseau'};Object.defineProperty(state.epic,'token',{get(){throw new Error('Credential field must not be read');}});
rendered=rows();assert.equal(rendered['Epic Games'].status,'Connecté · Trousseau');assert.match(rendered.GOG.detail,/session distante non vérifiée/);
assert(calls.every(call=>call[0]==='checkServices'),'Rendering connection states has no sign-in, sign-out or launch side effects');
console.log('Settings connection states: cache, live identity, temporary session and Keychain distinctions passed; no credentials or real UI used');
