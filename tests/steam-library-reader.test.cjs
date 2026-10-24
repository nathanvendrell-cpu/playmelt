const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Resources/SteamLibraryReader.js'), 'utf8');
const account = '76561198000000000', other = '76561198000000001';
const games = [{appid: 427520, name: 'Factorio'}, {appid: 526870, name: 'Satisfactory'}];
const script = new vm.Script(`(function(){${source}\n})()`);
let passed = 0;
function read(change = {}) {
  const config = {strSteamId: account, bViewingOwnProfile: true, rgGames: games, ...change.config};
  const attrs = {
    gameslist_config: {'data-profile-gameslist': change.raw ?? JSON.stringify(config)},
    application_config: {'data-userinfo': JSON.stringify(change.user ?? {logged_in:true,steamid:account})},
  };
  if (change.noEmbedded) delete attrs.gameslist_config;
  if (change.noUserInfo) delete attrs.application_config;
  const context = {
    URL, expectedAccountId: change.selected ?? account,
    window: {location:{href:change.url ?? `https://steamcommunity.com/profiles/${account}/games/?tab=all`}, g_steamID:change.viewer === undefined ? account : change.viewer},
    document: {getElementById: id => attrs[id] ? {getAttribute:name => attrs[id][name]} : null},
    fetch: () => {throw new Error('Reader must not request a deprecated endpoint or export credentials');},
  };
  return JSON.parse(JSON.stringify(script.runInNewContext(context, {timeout:1000})));
}
function check(name, run) { run(); passed++; }
check('complete embedded list before virtualization', () => {
  const result = read(); assert.equal(result.status,'complete'); assert.equal(result.count,2);
  assert.deepEqual(result.games,[{appid:'427520',name:'Factorio'},{appid:'526870',name:'Satisfactory'}]);
});
check('userinfo identity fallback', () => assert.equal(read({viewer:false}).status,'complete'));
check('global identity when optional userinfo absent', () => assert.equal(read({noUserInfo:true}).status,'complete'));
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
check('no config/credential fields exported', () => {
  const result=read({user:{logged_in:true,steamid:account,webapi_token:'fixture-secret'},config:{webapi_token:'other-secret'}});
  assert.equal(JSON.stringify(result).includes('secret'),false);
  assert.deepEqual(Object.keys(result).sort(),['accountId','count','games','source','status']);
});
console.log(`Steam embedded-library reader: ${passed} cases passed; no browser, network or credentials used`);
