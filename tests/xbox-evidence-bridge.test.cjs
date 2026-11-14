'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
// The optional path lets the delegated owner validate the proposed main patch before integration.
const native=fs.readFileSync(process.env.PLAYMELT_XBOX_PATCHED_MAIN||path.join(__dirname,'../main.swift'),'utf8');
const script=native.match(/private static let playbackObservation="""\n([\s\S]*?)\n    """/)[1].replace(/\\\\/g,'\\');
function fixture({pathname='/stream/BT5P2X999VH2/game',playing=false,recent=[],host='play.xbox.com'}={}) {
 const sent=[],handlers={},video={paused:!playing,readyState:playing?2:0,videoWidth:playing?1920:0};
 const section={querySelectorAll:()=>recent.map(id=>({pathname:'/products/'+id+'/game'})),parentElement:null};
 const document={documentElement:{},addEventListener:(e,fn)=>handlers[e]=fn,querySelectorAll:s=>s==='video'?[video]:recent.length?[{textContent:'Jump back in',parentElement:section}]:[]};
 const context={location:{hostname:host,pathname},document,window:{webkit:{messageHandlers:{playmeltXboxPlayback:{postMessage:m=>sent.push(JSON.parse(JSON.stringify(m)))}}}},
 MutationObserver:class{observe(){}disconnect(){}},setTimeout(){return 1},clearTimeout(){},addEventListener(){}};
 vm.runInNewContext(script,context);return {sent,handlers,video};
}
test('catalogue navigation labels its list as undated rather than playback',()=>{
 const f=fixture({pathname:'/',recent:['BT5P2X999VH2','9NPKGVXPFRSX']});
 assert.deepEqual(f.sent,[{ids:['BT5P2X999VH2','9NPKGVXPFRSX'],evidence:'recent-list'}]);
 assert(!f.sent.some(x=>x.evidence==='video-playback'));
});
test('launch click or non-playing video emits no play date evidence',()=>assert.deepEqual(fixture().sent,[]));
test('actual stream video emits exactly one explicit playback observation',()=>{
 const f=fixture();Object.assign(f.video,{paused:false,readyState:2,videoWidth:1920});f.handlers.playing();f.handlers.playing();
 assert.deepEqual(f.sent,[{ids:['BT5P2X999VH2'],evidence:'video-playback'}]);
});
test('a product trailer and an unrelated host cannot emit playback evidence',()=>{
 assert.deepEqual(fixture({pathname:'/products/BT5P2X999VH2/game',playing:true}).sent,[]);
 assert.deepEqual(fixture({host:'xbox.com.invalid',playing:true}).sent,[]);
});
