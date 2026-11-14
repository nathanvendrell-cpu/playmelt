'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const start=html.indexOf('        function runCardAction('),end=html.indexOf('        function ',start+30),source=html.slice(start,end);
function fixture(game){const sent=[],opened=[];const context={state:{games:[game]},platforms:g=>g.platforms||[g.platform],send:(...args)=>sent.push(args),openGame:g=>opened.push(g)};vm.createContext(context);vm.runInContext(source,context);context.runCardAction(game);return {sent,opened};}
test('Xbox poster Play routes by game identity when no browser URL is serialized',()=>{
 const result=fixture({id:'xbox:9NPKGVXPFRSX',store:'xbox',platform:'cloud',platforms:['cloud','windows']});
 assert.equal(result.sent.length,1);assert.equal(result.sent[0][0],'launchGame');assert.equal(result.sent[0][1].gameId,'xbox:9NPKGVXPFRSX');assert(!('url' in result.sent[0][1]));
});
test('Xbox PC-only poster opens its dossier instead of attempting cloud play',()=>{
 const result=fixture({id:'xbox:fixture',store:'xbox',platform:'windows',platforms:['windows']});assert.equal(result.sent.length,0);assert.equal(result.opened.length,1);
});
