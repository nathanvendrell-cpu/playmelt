'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const start=html.indexOf('// --- Steam ---'),end=html.indexOf('// --- Epic ---',start);
function toolbar(status){
 const elements={},classes={};const context={state:{games:[],accounts:[],selectedAccountId:'',libraryStatus:{status}},ui:{view:'steam'},locale:new Intl.NumberFormat('fr-FR'),platforms:()=>[],show(){},$:id=>elements[id]||=( {classList:{toggle(name,value){classes[name]=value}}})};
 vm.runInNewContext(html.slice(start,end),context);return {elements,classes};
}
test('a saved Steam library requests verification instead of claiming a logout',()=>{
 const {elements,classes}=toolbar('snapshot');assert.equal(elements.steamPlugPlayText.textContent,'À vérifier');assert.equal(classes['connected-state'],false);assert.match(elements.steamPlugPlayBtn.title,/conservée/);
});
test('only a verified live library is labelled connected',()=>{
 assert.equal(toolbar('synced').elements.steamPlugPlayText.textContent,'Connecté');
 for(const state of ['local','loading','syncing'])assert.equal(toolbar(state).elements.steamPlugPlayText.textContent,'Vérifier Steam');
});
