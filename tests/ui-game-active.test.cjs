"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
const html=fs.readFileSync(path.join(__dirname,"..","index.html"),"utf8");
const start=html.indexOf("const activeGameSessions"),end=html.indexOf("window.onLaunchProgress =",start);
function fixture(){const classes=new Set();const root={classList:{toggle(name,on){on?classes.add(name):classes.delete(name)}}};
 const api=vm.runInNewContext(html.slice(start,end)+";({gameSessionChanged})",{Set,String,document:{documentElement:root}});return {api,classes};}
test("Playmelt idles while any game runs and resumes after the last one closes",()=>{
 const {api,classes}=fixture();
 api.gameSessionChanged({title:"Spider-Man 2",state:"preparing"});assert(classes.has("game-active"));
 api.gameSessionChanged({title:"Megabonk",state:"running"});
 api.gameSessionChanged({title:"Spider-Man 2",state:"ended"});assert(classes.has("game-active"),"another game still runs");
 api.gameSessionChanged({title:"Megabonk",state:"failed"});assert(!classes.has("game-active"));
});
test("unknown states never pause the interface",()=>{
 const {api,classes}=fixture();api.gameSessionChanged({title:"X",state:"weird"});assert(!classes.has("game-active"));
});
test("the CSS pauses animations and drops backdrop blur only under game-active",()=>{
 assert.match(html,/html\.game-active \*[^{]*\{\s*animation-play-state: paused !important;\s*backdrop-filter: none !important;/);
});
