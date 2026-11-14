'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {create}=require('../Resources/AppIntro.js');
function fixture(reduced=false){
 const nodes=[],timers=new Map(),listeners=new Map();let count=0;
 function el(tag,cls,text){const n={tag,cls,textContent:text,children:[],handlers:{},append(...v){this.children.push(...v)},setAttribute(k,v){this[k]=v},addEventListener(k,v){this.handlers[k]=v},showModal(){this.open=true},close(){this.open=false},remove(){this.removed=true}};nodes.push(n);return n;}
 const motion={matches:reduced,addEventListener(k,fn){listeners.set(k,fn)},removeEventListener(k){listeners.delete(k)}};
 const intro=create({el,document:{body:{append(){}}},matchMedia:()=>motion,setTimer(fn,ms){timers.set(++count,{fn,ms});return count},clearTimer(id){timers.delete(id)}});
 return {intro,nodes,timers,listeners};
}
test('intro is one bounded animation with the original local mark',()=>{
 const f=fixture();f.intro.start();f.intro.start();assert.equal(f.nodes.filter(n=>n.tag==='dialog').length,1);assert.equal(f.timers.size,1);assert.equal([...f.timers.values()][0].ms,3800);assert(f.nodes.filter(n=>n.tag==='img').every(n=>['PlaymeltMarkInk.png','PlaymeltMarkOrange.png','PlaymeltWordmark.png'].includes(n.src)));
 let finished=0;f.intro.after(()=>finished++);assert.equal(finished,0);[...f.timers.values()][0].fn();assert.equal(finished,1);assert.equal(f.timers.size,0);assert.equal(f.listeners.size,0);assert(f.nodes.find(n=>n.tag==='dialog').removed);f.intro.after(()=>finished++);assert.equal(finished,2);
});
test('Reduce Motion skips immediately without a timer or dialog',()=>{
 const f=fixture(true);let complete=false;f.intro.after(()=>complete=true);f.intro.start();assert(complete);assert.equal(f.nodes.length,0);assert.equal(f.timers.size,0);
});
test('only the overlay exit animation releases the next screen',()=>{
 const f=fixture();f.intro.start();const d=f.nodes.find(n=>n.tag==='dialog');d.handlers.animationend({target:f.nodes[1],animationName:'playmeltIntroReveal'});assert(!f.intro.finished);d.handlers.animationend({target:d,animationName:'playmeltIntroExit'});assert(f.intro.finished);assert.equal(f.timers.size,0);
});
test('switching Reduce Motion on releases the UI and cleans up',()=>{
 const f=fixture();f.intro.start();f.listeners.get('change')({matches:true});assert(f.intro.finished);assert.equal(f.timers.size,0);assert.equal(f.listeners.size,0);
});
test('Escape can skip the intro without leaving a blocking dialog',()=>{
 const f=fixture();f.intro.start();let prevented=false;f.nodes[0].handlers.cancel({preventDefault(){prevented=true}});assert(prevented);assert(f.intro.finished);assert(f.nodes[0].removed);
});
