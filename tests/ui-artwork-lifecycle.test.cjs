'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const timers=new Map();let timerID=0;
const sandbox={module:{exports:{}},setTimeout:fn=>{timers.set(++timerID,fn);return timerID;},clearTimeout:id=>timers.delete(id),Date};sandbox.globalThis=sandbox;
vm.runInNewContext(fs.readFileSync('Resources/Artwork.js','utf8'),sandbox);const loader=sandbox.module.exports;
function image(){return {assigned:[],classList:{add(){},remove(){}},set src(x){this.assigned.push(x);},removeAttribute(){this.cleared=true;}};}
const images=Array.from({length:9},image);
images.forEach((img,i)=>loader.bind(img,[`https://cdn.example/${i}`,`https://fallback.example/${i}`],{eager:true}));
assert.equal(loader.stats().active,6);assert.equal(loader.stats().pending,3);assert.equal(images[6].assigned.length,0);
images[0].onerror();assert.equal(images[0].assigned[1],'https://fallback.example/0');
const oldError=images[0].onerror;loader.dispose(images[0]);oldError();assert.equal(images[0].assigned.length,2);assert.equal(images[0].onerror,null);assert.equal(images[6].assigned.length,1);
images[1].onload();const next=image();loader.bind(next,['https://cdn.example/1','https://fallback.example/1'],{eager:true});
images.forEach(x=>loader.dispose(x));assert.equal(next.assigned[0],'https://cdn.example/1');loader.dispose(next);
assert.equal(loader.stats().active,0);assert.equal(loader.stats().tracked,0);assert.equal(timers.size,0);
const fail=image();loader.bind(fail,['https://bad.example/image']);fail.onerror();loader.dispose(fail);const retry=image();loader.bind(retry,['https://bad.example/image','https://good.example/image']);assert.equal(retry.assigned[0],'https://good.example/image');loader.dispose(retry);
console.log('Artwork queue: concurrency, fallback, cancelled callbacks, cleanup, source reuse and failed-source cooldown passed');
