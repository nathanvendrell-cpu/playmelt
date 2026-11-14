const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const scripts=[...html.matchAll(/<script[^>]*src="([^"/]+\.js)"[^>]*>/g)].map(x=>x[1]);
const sources=scripts.map(name=>fs.readFileSync(path.join(root,'Resources',name),'utf8')).join('\n');
const required=new Set([...html.matchAll(/window\.(Playmelt\w+)\./g)].map(x=>x[1]));
for(const name of required)assert(new RegExp('root\\.'+name+'\\s*=').test(sources),'Missing bundled module: '+name);
assert.equal(new Set(scripts).size,scripts.length,'Modules loaded once');
console.log('UI bundle: all referenced Playmelt modules are loaded');

const allowedBlock=html.match(/const allowedActions = new Set\(\[([\s\S]*?)\]\);/)[1];
const allowed=new Set([...allowedBlock.matchAll(/"([A-Za-z]+)"/g)].map(x=>x[1]));
for(const match of sources.matchAll(/(?:api\.)?send\(['"]([A-Za-z]+)['"]/g))assert(allowed.has(match[1]),'Unroutable UI action: '+match[1]);
for(const action of ['choosePlayerPhoto','chooseGameAvatar','savePlayerProfile','chooseLocalGame','installLocalGame','setVMInstallPreference','setAutomaticBenchmarks','checkInstalledGames'])assert(allowed.has(action),action+' must reach native bridge');
console.log('UI bridge: profile, onboarding, imports and diagnostics commands are authorized');
