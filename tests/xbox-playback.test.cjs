'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const native=fs.readFileSync(require('node:path').join(__dirname,'../main.swift'),'utf8');
const script=native.match(/private static let playbackObservation="""\n([\s\S]*?)\n    """/)[1].replace(/\\\\/g,'\\');
function fixture({host='www.xbox.com',path='/play/launch/game/BT5P2X999VH2',playing=false,recent=[],modern=false}={}){
 const sent=[],handlers={},video={paused:!playing,readyState:playing?2:0,videoWidth:playing?1920:0};
 const section={querySelectorAll:()=>recent.map(id=>({pathname:modern?'/products/'+id+'/game':'/play/games/game/'+id})),parentElement:null};
 const document={documentElement:{},addEventListener:(event,fn)=>handlers[event]=fn,querySelectorAll:selector=>selector==='video'?[video]:recent.length?[{textContent:'Jump back in',parentElement:section}]:[]};
 const context={location:{hostname:host,pathname:path},document,window:{webkit:{messageHandlers:{playmeltXboxPlayback:{postMessage:v=>sent.push(JSON.parse(JSON.stringify(v)))}}}},MutationObserver:class{observe(){}disconnect(){}},setTimeout(){return 1},clearTimeout(){},addEventListener(){}};
 vm.runInNewContext(script,context);return {sent,handlers,video};
}
test('opening a launch page is not recorded as having played',()=>{assert.deepEqual(fixture().sent,[])});
test('actual video playback records the requested title only once',()=>{
 const f=fixture();Object.assign(f.video,{paused:false,readyState:2,videoWidth:1920});f.handlers.playing();f.handlers.playing();
 assert.deepEqual(f.sent,[{ids:['BT5P2X999VH2'],evidence:'video-playback'}]);
});
test('official Xbox Jump back in order is imported without profile or token data',()=>{
 assert.deepEqual(fixture({path:'/play',recent:['9NPKGVXPFRSX','BT5P2X999VH2']}).sent,[{ids:['9NPKGVXPFRSX','BT5P2X999VH2'],evidence:'recent-list'}]);
});
test('an unrelated page cannot use the playback observation bridge',()=>{assert.deepEqual(fixture({host:'xbox.com.invalid',playing:true}).sent,[])});
test('current Xbox stream paths record real playback, not product-page trailers',()=>{
 assert.deepEqual(fixture({host:'play.xbox.com',path:'/stream/9P4NV23Q6QC2/abiotic-factor',playing:true}).sent,[{ids:['9P4NV23Q6QC2'],evidence:'video-playback'}]);
 assert.deepEqual(fixture({host:'play.xbox.com',path:'/products/9P4NV23Q6QC2/abiotic-factor',playing:true}).sent,[]);
});
test('current product links preserve the official recent-game order',()=>{
 assert.deepEqual(fixture({host:'play.xbox.com',path:'/',recent:['9NPKGVXPFRSX','BT5P2X999VH2'],modern:true}).sent,[{ids:['9NPKGVXPFRSX','BT5P2X999VH2'],evidence:'recent-list'}]);
});
