const assert=require('node:assert/strict');
const store={};global.localStorage={getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=String(v);}};
const {badges}=require('../Resources/Discover.js');
const H=3600,now=Date.now()/1000;
const game=(id,o={})=>({id,title:id,store:'steam',playtime:0,lastPlayed:0,platforms:['windows'],...o});
const games=[game('factorio',{playtime:837*H,lastPlayed:now-3600,platforms:['mac','windows'],installed:true,achievements:{total:88,unlockedCount:58}}),
  game('done',{playtime:60*H,achievements:{total:10,unlockedCount:10}}),game('xb',{store:'xbox',lastPlayed:now-86400}),
  ...Array.from({length:120},(_,i)=>game('epic'+i,{store:'epic'}))];
const state={games,profile:{level:6}};
const s=badges.stats(state);
assert.equal(s.owned,122);assert.equal(s.perfect,1);assert.equal(s.unlocked,68);assert.equal(s.veteran,2);assert.equal(s.xbox,1);assert.equal(s.never,120);assert.equal(s.mac,1);
const r=badges.evaluate(state);
const by=id=>r.families.find(b=>b.id===id);
assert.equal(by('obsession').tier,2,'837 h → Or');assert.equal(by('perfect').tier,0);assert.equal(by('chest').tier,1);assert.equal(by('ascension').tier,1);
assert.ok(r.secrets.find(b=>b.id==='secret-month').tier===0,'720 h secret');assert.ok(r.secrets.find(b=>b.id==='secret-shame').tier===0);
// Un badge acquis reste acquis même si la donnée baisse (désinstallation).
badges.sync(state);
const lower={...state,games:games.map(g=>({...g,installed:false}))};
assert.equal(badges.evaluate(lower,JSON.parse(store.playmelt_badges_v1)).families.find(b=>b.id==='disk').tier,0);
// Pendant la fenêtre d'arrivée, rien n'est annoncé comme nouveau.
assert.equal(badges.sync({...state,games:[...games,game('extra',{playtime:500*H})]}).newly.length,0);
console.log('Badges : statistiques, paliers, secrets et persistance');
