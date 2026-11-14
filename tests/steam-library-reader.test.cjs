const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/SteamLibraryReader.js'), 'utf8');
const account = '76561198000000000', other = '76561198000000001';
const games = [{appid: 427520, name: 'Factorio'}, {appid: 526870, name: 'Satisfactory'}];
const script = new vm.Script(`(function(){${source}\n})()`);
let passed = 0;
const pending = [];
function read(change = {}) {
  const config = {strSteamId: account, bViewingOwnProfile: true, rgGames: games, ...change.config};
  const attrs = {
    gameslist_config: {'data-profile-gameslist': change.raw ?? JSON.stringify(config)},
    application_config: {'data-userinfo': change.rawUser ?? JSON.stringify(change.user ?? {logged_in:true,steamid:account})},
  };
  if (change.noEmbedded) delete attrs.gameslist_config;
  if (change.noUserInfo) delete attrs.application_config;
  if (change.webUser !== undefined || change.rawWebUser !== undefined)
    attrs.webui_config = {'data-userinfo': change.rawWebUser ?? JSON.stringify(change.webUser)};
  const server = change.server;
  const serverAttrs = server ? {
    application_config: {'data-userinfo': JSON.stringify(server.user ?? {logged_in:true,steamid:account})},
    gameslist_config: {'data-profile-gameslist': JSON.stringify({strSteamId:account,bViewingOwnProfile:true,rgGames:games,...server.config})},
  } : {};
  const documentFor = rows => ({getElementById:id=>rows[id]?{getAttribute:name=>rows[id][name]}:null});
  const context = {
    URL, AbortController, TextDecoder, setTimeout:change.timeout ? ((fn,ms)=>{assert.equal(ms,12000);return setTimeout(fn,1);}):setTimeout, clearTimeout, expectedAccountId: change.selected ?? account,
    ...(change.allowDiscovery === undefined ? {} : {allowAccountDiscovery:change.allowDiscovery}),
    window: {location:{href:change.url ?? `https://steamcommunity.com/profiles/${account}/games/?tab=all`}, g_steamID:change.viewer === undefined ? account : change.viewer, UserConfig:change.globalUserConfig},
    document: documentFor(attrs),
    DOMParser: class {parseFromString(_text,type){assert.equal(type,'text/html');return documentFor(serverAttrs);}},
    fetch: async (url,options) => {
      assert.equal(url,change.url ?? `https://steamcommunity.com/profiles/${account}/games/?tab=all`);
      assert.equal(options.credentials,'same-origin');assert.equal(options.cache,'no-store');assert.equal(options.redirect,'follow');
      assert.deepEqual(Object.keys(options).sort(),['cache','credentials','redirect','signal']);
      if (!server) throw new Error('No authenticated server fixture');
      if (server.hang) return new Promise((resolve,reject)=>{if(options.signal.aborted)reject(new Error('aborted'));else options.signal.addEventListener('abort',()=>reject(new Error('aborted')),{once:true});});
      let readOnce=false;
      return {ok:server.ok ?? true,url:server.url ?? `https://steamcommunity.com/profiles/${account}/games/?tab=all`,headers:{get:()=>server.contentType ?? 'text/html; charset=utf-8'},body:{getReader:()=>({
        async read(){if(readOnce)return {done:true};readOnce=true;return {done:false,value:server.tooLarge ? new Uint8Array(8000001):new TextEncoder().encode('inert fixture document')};},
        async cancel(){},releaseLock(){},
      })}};
    },
  };
  const result=script.runInNewContext(context,{timeout:1000});
  return result && typeof result.then==='function' ? result.then(value=>JSON.parse(JSON.stringify(value))):JSON.parse(JSON.stringify(result));
}
function check(name, run) { const result=run();if(result && typeof result.then==='function')pending.push(result);passed++; }
check('complete embedded list before virtualization', () => {
  const result = read(); assert.equal(result.status,'complete'); assert.equal(result.count,2);
  assert.deepEqual(result.games,[{appid:'427520',name:'Factorio'},{appid:'526870',name:'Satisfactory'}]);
});
check('userinfo identity fallback', () => assert.equal(read({viewer:false}).status,'complete'));
check('global identity when optional userinfo absent', () => assert.equal(read({noUserInfo:true}).status,'complete'));
check('current Valve UserConfig identity is accepted without legacy nodes',()=>assert.equal(read({noUserInfo:true,viewer:false,globalUserConfig:{logged_in:true,steamid:account}}).status,'complete'));
check('UserConfig signed out cannot be overridden by an old identity',()=>assert.equal(read({globalUserConfig:{logged_in:false,steamid:account}}).status,'signed-out'));
check('UserConfig disagreement with server config is refused',()=>assert.equal(read({globalUserConfig:{logged_in:true,steamid:other}}).status,'identity-mismatch'));
check('numeric UserConfig SteamID is never normalized',()=>assert.equal(read({noUserInfo:true,viewer:false,globalUserConfig:{logged_in:true,steamid:Number(account)}}).status,'identity-unverified'));
check('UserConfig does not prove ownership of another public profile',()=>assert.equal(read({noUserInfo:true,viewer:false,globalUserConfig:{logged_in:true,steamid:account},config:{bViewingOwnProfile:false}}).status,'identity-mismatch'));
check('UserConfig sensitive fields are never enumerated or serialized',()=>{const u={logged_in:true,steamid:account};Object.defineProperty(u,'webapi_token',{get(){throw new Error('Secret field read');},enumerable:true});assert.equal(read({noUserInfo:true,viewer:false,globalUserConfig:u}).status,'complete');});
check('current Valve WebUI identity with no legacy global/config', () => assert.equal(read({noUserInfo:true,viewer:false,webUser:{logged_in:true,steamid:account}}).status,'complete'));
check('matching legacy and WebUI identities accepted', () => assert.equal(read({webUser:{logged_in:true,steamid:account}}).status,'complete'));
check('WebUI signed out cannot be overridden by legacy login', () => assert.equal(read({webUser:{logged_in:false}}).status,'signed-out'));
check('WebUI identity contradicting legacy config refused', () => assert.equal(read({webUser:{logged_in:true,steamid:other}}).status,'identity-mismatch'));
check('WebUI selected account mismatch refused without legacy config', () => assert.equal(read({noUserInfo:true,viewer:false,selected:other,webUser:{logged_in:true,steamid:account}}).status,'account-mismatch'));
check('WebUI public profile still refused', () => assert.equal(read({noUserInfo:true,viewer:false,webUser:{logged_in:true,steamid:account},config:{bViewingOwnProfile:false}}).status,'identity-mismatch'));
check('malformed WebUI identity cannot use legacy identity', () => assert.equal(read({rawWebUser:'{broken'}).status,'identity-unverified'));
check('WebUI unknown identity cannot use profile URL alone', () => assert.equal(read({noUserInfo:true,viewer:false,webUser:{logged_in:true}}).status,'identity-unverified'));
check('signed out refused despite stale global', () => assert.equal(read({user:{logged_in:false}}).status,'signed-out'));
check('viewer mismatch refused', () => assert.equal(read({viewer:other}).status,'identity-mismatch'));
check('selected account mismatch refused', () => assert.equal(read({selected:other}).status,'account-mismatch'));
check('owner mismatch refused', () => assert.equal(read({config:{strSteamId:other}}).status,'identity-mismatch'));
check('another profile refused', () => assert.equal(read({config:{bViewingOwnProfile:false}}).status,'identity-mismatch'));
check('URL owner mismatch refused', () => assert.equal(read({url:`https://steamcommunity.com/profiles/${other}/games/?tab=all`}).status,'identity-mismatch'));
check('vanity own profile accepted', () => assert.equal(read({url:'https://steamcommunity.com/id/fixture/games?tab=all'}).status,'complete'));
check('partial/recent tab refused', () => assert.equal(read({url:`https://steamcommunity.com/profiles/${account}/games/?tab=recent`}).status,'wrong-page'));
check('external origin refused', () => assert.equal(read({url:`https://steamcommunity.com.evil.example/profiles/${account}/games/?tab=all`}).status,'wrong-page'));
check('HTTP refused', () => assert.equal(read({url:`http://steamcommunity.com/profiles/${account}/games/?tab=all`}).status,'wrong-page'));
check('login page refused', () => assert.equal(read({url:'https://steamcommunity.com/login/home/'}).status,'wrong-page'));
check('missing embedded list never scrapes cards', () => assert.equal(read({noEmbedded:true}).status,'embedded-library-unavailable'));
check('empty seed not treated as empty owned library', () => assert.equal(read({config:{rgGames:[]}}).status,'empty-unverified'));
check('malformed JSON refused', () => assert.equal(read({raw:'{broken'}).status,'malformed-library'));
check('duplicate IDs refused', () => assert.equal(read({config:{rgGames:[games[0],games[0]]}}).status,'duplicate-game'));
check('equivalent string IDs deduplicated by validation', () => assert.equal(read({config:{rgGames:[games[0],{appid:'0427520',name:'Duplicate'}]}}).status,'duplicate-game'));
check('invalid IDs refused', () => assert.equal(read({config:{rgGames:[{appid:'1;open anything',name:'X'}]}}).status,'invalid-game'));
check('overflow IDs refused', () => assert.equal(read({config:{rgGames:[{appid:4294967296,name:'X'}]}}).status,'invalid-game'));
check('empty names refused', () => assert.equal(read({config:{rgGames:[{appid:1,name:' '} ]}}).status,'invalid-game'));
check('names bounded', () => assert.equal(read({config:{rgGames:[{appid:1,name:'x'.repeat(300)}]}}).games[0].name.length,200));
check('array app ID cannot be coerced into valid ID', () => assert.equal(read({config:{rgGames:[{appid:[427520],name:'Array'}]}}).status,'invalid-game'));
check('boolean app ID refused', () => assert.equal(read({config:{rgGames:[{appid:true,name:'Boolean'}]}}).status,'invalid-game'));
check('empty selection requires explicit native discovery opt-in', () => assert.equal(read({selected:''}).status,'account-unselected'));
check('discovery only accepts fully verified own library', () => {
  const result = read({selected:'',allowDiscovery:true});
  assert.equal(result.status,'complete'); assert.equal(result.accountId,account);
  assert.deepEqual(result.games,[{appid:'427520',name:'Factorio'},{appid:'526870',name:'Satisfactory'}]);
});
check('truthy discovery flag refused', () => assert.equal(read({selected:'',allowDiscovery:'true'}).status,'account-unselected'));
check('malformed selected account never becomes discovery', () => assert.equal(read({selected:'invalid',allowDiscovery:true}).status,'account-unselected'));
check('discovery cannot override an existing selected account', () => assert.equal(read({selected:other,allowDiscovery:true}).status,'account-mismatch'));
check('discovery refuses another profile', () => assert.equal(read({selected:'',allowDiscovery:true,config:{bViewingOwnProfile:false}}).status,'identity-mismatch'));
check('discovery refuses contradictory URL owner', () => assert.equal(read({selected:'',allowDiscovery:true,url:`https://steamcommunity.com/profiles/${other}/games/?tab=all`}).status,'identity-mismatch'));
check('discovery refuses contradictory list owner', () => assert.equal(read({selected:'',allowDiscovery:true,config:{strSteamId:other}}).status,'identity-mismatch'));
check('discovery refuses signed-out viewer', () => assert.equal(read({selected:'',allowDiscovery:true,user:{logged_in:false}}).status,'signed-out'));
check('discovery cannot create an account from an empty seed', () => assert.equal(read({selected:'',allowDiscovery:true,config:{rgGames:[]}}).status,'empty-unverified'));
check('userinfo malformed JSON refused', () => assert.equal(read({rawUser:'{broken'}).status,'identity-unverified'));
check('userinfo present but identity missing cannot use stale global', () => assert.equal(read({user:{logged_in:true}}).status,'identity-unverified'));
check('unsafe numeric account identity refused', () => assert.equal(read({user:{logged_in:true,steamid:Number(account)}}).status,'identity-unverified'));
check('numeric identity diagnostic never normalizes the account', () => assert.equal(read({user:{logged_in:true,steamid:Number(account)}}).reason,'userinfo-id-number'));
check('string login diagnostic never treats a truthy value as authenticated', () => {const r=read({user:{logged_in:'true',steamid:account}});assert.equal(r.status,'signed-out');assert.equal(r.reason,'logged-in-string-true');});
check('numeric login diagnostic distinguishes one and zero without accepting either', () => {for(const [n,reason] of [[1,'logged-in-number-one'],[0,'logged-in-number-zero']]) {const r=read({user:{logged_in:n,steamid:account}});assert.equal(r.status,'signed-out');assert.equal(r.reason,reason);}});
check('missing login diagnostic is distinct from signed out', () => assert.equal(read({user:{steamid:account}}).reason,'logged-in-unavailable'));
check('absent identity blocks are reported without scraping profile cards', async () => assert.equal((await read({viewer:false,noUserInfo:true})).reason,'identity-node-unavailable'));
check('consumed identity nodes can be read in the authenticated inert server document', async()=>{const r=await read({viewer:false,noUserInfo:true,server:{}});assert.equal(r.status,'complete');assert.equal(r.count,2);});
check('fresh document still rejects a signed-out viewer', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{user:{logged_in:false}}})).status,'signed-out'));
check('fresh document cannot import another public profile', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{config:{bViewingOwnProfile:false}}})).status,'identity-mismatch'));
check('fresh read of a vanity public profile never substitutes the current account', async()=>assert.equal((await read({viewer:false,noUserInfo:true,url:'https://steamcommunity.com/id/another-profile/games?tab=all',server:{config:{bViewingOwnProfile:false}}})).status,'identity-mismatch'));
check('fresh document cannot replace selected account', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{user:{logged_in:true,steamid:other}}})).status,'account-mismatch'));
check('login redirect is reported as signed out without parsing account data', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{url:'https://steamcommunity.com/login/home/'}})).status,'signed-out'));
check('cross-origin response cannot supply an account', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{url:'https://example.org/profiles/'+account+'/games?tab=all'}})).reason,'identity-node-unavailable'));
check('fresh complete HTTP document alone is not an authenticated owned library', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{config:{rgGames:[]}}})).status,'empty-unverified'));
check('fresh response stream is bounded before parsing', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{tooLarge:true}})).status,'too-large'));
check('fresh document URL owner must agree with its validated account', async()=>assert.equal((await read({viewer:false,noUserInfo:true,server:{url:'https://steamcommunity.com/profiles/'+other+'/games?tab=all'}})).status,'identity-mismatch'));
check('a hanging fresh read is aborted and preserves the previous failure without a partial library', async()=>assert.equal((await read({viewer:false,noUserInfo:true,timeout:true,server:{hang:true}})).reason,'identity-node-unavailable'));
check('invalid JSON diagnostic exports no original payload', () => {const r=read({rawUser:'{private-fixture-secret'});assert.equal(r.reason,'userinfo-malformed');assert.equal(JSON.stringify(r).includes('secret'),false);});
check('duplicate tab parameters refused', () => assert.equal(read({url:`https://steamcommunity.com/profiles/${account}/games/?tab=all&tab=recent`}).status,'wrong-page'));
check('no config/credential fields exported', () => {
  const result=read({user:{logged_in:true,steamid:account,webapi_token:'fixture-secret'},config:{webapi_token:'other-secret'}});
  assert.equal(JSON.stringify(result).includes('secret'),false);
  assert.deepEqual(Object.keys(result).sort(),['accountId','count','games','source','status']);
});
Promise.all(pending).then(()=>console.log(`Steam embedded-library reader: ${passed} cases passed; no browser, real network or credentials used`)).catch(error=>{console.error(error);process.exitCode=1;});
