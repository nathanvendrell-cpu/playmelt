import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, chmodSync, symlinkSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Worker } from "node:worker_threads";
import { DatabaseSync } from "node:sqlite";
import { Store, digest, token } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { normalizeNetworkIP, publicNetworkIP, networkPolicyOptions, loadNetworkPolicy, registerNetworkPolicy } from "../src/network-policy.mjs";

const ORIGIN="https://network.example.test", BASE="/Playmelt/compte", A="8.8.8.8", B="1.1.1.1", C="9.9.9.9";
const PEPPER=Buffer.alloc(32,42);
async function fixture(t, extra={}, mailHandler, path=":memory:") {
  let now=1900000000;
  const store=new Store(path,()=>now),mail=[];
  const {privateKey}=generateKeyPairSync("ed25519");
  const config={testing:true,publicURL:ORIGIN+BASE,live:false,billingEnabled:false,prices:{},signingKey:privateKey,
    mailFrom:"fixture@example.test",adminEmails:[],internalEmails:[],networkEnabled:true,
    networkOriginQualified:true,networkIPSource:"direct",networkPepper:PEPPER,...extra};
  const app=await createApp({store,config,stripe:{},mailer:{sendMail:async message=>{
    mail.push(message);return mailHandler ? mailHandler(message) : {accepted:[message.to.address],rejected:[]};
  }}});
  t.after(()=>app.close());
  const req=(path,{method="GET",body,ip=A,session,native,headers={}}={})=>app.inject({method,url:BASE+"/v1/"+path,
    payload:body,remoteAddress:ip,headers:{origin:ORIGIN,...(session?{cookie:"pm_session="+session}:{}),...(native?{authorization:"Bearer "+native}:{}),...headers}});
  const user=(email="first@example.test")=>{
    const account=store.consumeMagic(store.magic(email));
    store.run("INSERT INTO entitlements VALUES(?,?,?,'active',NULL,NULL,NULL,?)","fixture-"+account.user.id,account.user.id,"lifetime",store.now());
    return account;
  };
  const device=(account)=>{const proof=token(),request=store.device("Fixture Mac",digest(proof));store.approveDevice(request.userCode,account.user.id);return store.exchangeDevice(request.deviceCode,proof).token;};
  const launch=(native,ip=A,headers={})=>req("launch-ticket",{method:"POST",body:{},native,ip,headers});
  const change=(account,ip=B,body={})=>req("network/change",{method:"POST",body,session:account.session,ip});
  const confirmation=()=>mail.at(-1).text.match(/#networkToken=([A-Za-z0-9_-]{43})/)[1];
  const confirm=(account,value,ip=C,headers={})=>req("network/confirm",{method:"POST",body:{token:value},session:account.session,ip,headers});
  return {app,store,config,mail,req,user,device,launch,change,confirmation,confirm,advance:seconds=>now+=seconds};
}

test("canonical IPs collapse mapped IPv4 and equivalent IPv6; nonpublic or malformed sources are rejected",()=>{
  assert.equal(normalizeNetworkIP("::ffff:8.8.8.8").canonical,A);
  assert.equal(normalizeNetworkIP("::ffff:0808:0808").canonical,A);
  assert.deepEqual(normalizeNetworkIP("2606:4700:4700::1111"),normalizeNetworkIP("2606:4700:4700:0:0:0:0:1111"));
  assert.equal(normalizeNetworkIP("2606:4700:4700::1111").masked,"2606:4700:4700:…");
  for(const ip of ["",null,"008.8.8.8","8.8.8.8:90","[2606:4700::1]","fe80::1%en0","8.8.8.8,1.1.1.1","bad"])
    assert.equal(normalizeNetworkIP(ip),null);
  for(const ip of ["0.0.0.0","10.1.1.1","100.64.1.1","127.0.0.1","169.254.1.1","172.16.0.1","192.168.1.1","192.0.2.1","198.51.100.1","203.0.113.1","224.0.0.1","255.255.255.255","::","::1","::ffff:127.0.0.1","fc00::1","fe80::1","ff02::1","2001:db8::1","2002::1","3fff::1"])
    assert.equal(publicNetworkIP(ip),null,ip);
  assert.ok(publicNetworkIP(A));assert.ok(publicNetworkIP("2606:4700:4700::1111"));
});

test("network policy starts disabled and refuses unknown/unqualified or broad header-trusting configurations",()=>{
  assert.deepEqual(networkPolicyOptions({}),{enabled:false,trustProxy:false});
  assert.deepEqual(loadNetworkPolicy({PLAYMELT_NETWORK_PEPPER_FILE:"/must-not-be-read"},{}),{networkEnabled:false});
  const valid={networkEnabled:true,networkOriginQualified:true,networkPepper:PEPPER,networkIPSource:"direct"};
  for(const bad of [{networkOriginQualified:false},{networkIPSource:"unknown"},{networkIPSource:"trusted-proxy"},{networkPepper:Buffer.alloc(31)},
    {trustProxy:true},{trustProxy:["127.0.0.1"]},{networkTrustedProxies:["127.0.0.1"]},
    {networkIPSource:"passenger-protected",networkPassengerPeers:[]},{networkIPSource:"passenger-protected",networkPassengerPeers:["127.0.0.0/8"]}])
    assert.throws(()=>networkPolicyOptions({...valid,...bad}));
});

test("feature off preserves native grants, sessions and account routes without binding an address",async t=>{
  const f=await fixture(t,{networkEnabled:false,networkPepper:undefined}),u=f.user(),native=f.device(u);
  assert.deepEqual((await f.req("network/config")).json(),{networkEnabled:false});
  assert.equal((await f.launch(native,"127.0.0.1",{"x-forwarded-for":A})).statusCode,200);
  assert.equal((await f.launch(native,"invalid")).statusCode,200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM account_networks").n,0);
  assert.deepEqual((await f.req("network",{session:u.session})).json(),{enabled:false,phase:"unbound",activeNetworkMasked:null,currentNetworkMasked:null,changePending:false});
  assert.equal((await f.change(u)).json().error,"network_policy_disabled");
  assert.ok(f.store.authenticate(native));assert.ok(f.store.authenticate(u.session));assert.equal(f.mail.length,0);
});

test("first entitled launch binds once; all devices on that exact IP work while account/support remain accessible elsewhere",async t=>{
  const f=await fixture(t),u=f.user(),one=f.device(u),two=f.device(u);
  assert.equal((await f.req("network",{session:u.session})).json().phase,"unbound");
  assert.equal((await f.change(u)).json().error,"network_not_bound");
  assert.equal((await f.launch(one)).statusCode,200);
  assert.equal((await f.launch(two,"::ffff:8.8.8.8")).statusCode,200);
  const denied=await f.launch(one,B);
  assert.equal(denied.statusCode,403);assert.deepEqual(denied.json(),{error:"network_change_required",accountURL:ORIGIN+BASE+"/#network"});
  assert.equal((await f.req("me",{session:u.session,ip:B})).statusCode,200);
  assert.equal((await f.req("support",{session:u.session,ip:B})).statusCode,200);
  assert.equal((await f.req("checkout",{method:"POST",body:{},session:u.session,ip:B})).json().error,"billing_not_ready");
  assert.equal(f.store.entitlement(u.user.id).plan,"lifetime");assert.ok(f.store.authenticate(one));assert.ok(f.store.authenticate(two));
  const saved=f.store.get("SELECT * FROM account_networks");assert.match(saved.ip_hash,/^[a-f0-9]{64}$/);assert.equal(saved.masked,"8.8.8.*");
  assert.ok(!JSON.stringify(saved).includes(A));
});

test("email confirmation from a third IP activates only the originally requested target without revoking devices or licences",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);await f.launch(native);
  assert.equal((await f.change(u)).statusCode,200);const value=f.confirmation();
  const message=f.mail.at(-1);assert.ok(!message.text.includes(A));assert.ok(!message.text.includes(B));assert.match(message.text,/1\.1\.1\.\*/);
  assert.ok(!JSON.stringify(f.store.get("SELECT * FROM network_changes")).includes(value));
  assert.equal((await f.req("network",{session:u.session,ip:B})).json().changePending,true);
  assert.equal((await f.confirm(u,value,C)).statusCode,200);
  assert.equal((await f.launch(native,B)).statusCode,200);assert.equal((await f.launch(native,A)).statusCode,403);assert.equal((await f.launch(native,C)).statusCode,403);
  assert.equal((await f.confirm(u,value)).statusCode,400);
  assert.ok(f.store.authenticate(u.session));assert.ok(f.store.authenticate(native));assert.equal(f.store.entitlement(u.user.id).plan,"lifetime");
  assert.equal(f.store.get("SELECT generation FROM account_networks").generation,2);
  assert.equal((await f.req("network",{session:u.session,ip:B})).json().phase,"active");
});

test("wrong account, device bearer, foreign Origin and malformed input cannot consume or replace a challenge",async t=>{
  const f=await fixture(t),u=f.user(),other=f.user("second@example.test"),native=f.device(u);await f.launch(native);await f.change(u);const value=f.confirmation();
  assert.equal((await f.confirm(other,value)).statusCode,400);
  assert.equal((await f.confirm(u,value,C,{origin:"https://evil.example"})).statusCode,403);
  assert.equal((await f.req("network/confirm",{method:"POST",body:{token:value},native,ip:C})).statusCode,403);
  assert.equal((await f.req("network/change",{method:"POST",body:{},session:u.session,ip:B,headers:{origin:"https://evil.example"}})).statusCode,403);
  assert.equal((await f.change(u,B,{ip:C})).statusCode,400);
  assert.equal((await f.req("network/confirm",{method:"POST",body:{token:value,ip:C},session:u.session,ip:C})).statusCode,400);
  for(const malformed of [null,"",[],{},"bad",[value]])
    assert.equal((await f.req("network/confirm",{method:"POST",body:{token:malformed},session:u.session,ip:C})).statusCode,400);
  assert.equal((await f.confirm(u,value)).statusCode,200);
});

test("expiry is ten minutes, generation changes supersede challenges and parallel confirmations are one-use",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);await f.launch(native);await f.change(u);const expired=f.confirmation();f.advance(600);
  assert.equal((await f.confirm(u,expired)).statusCode,400);
  await f.change(u);const superseded=f.confirmation();f.store.run("UPDATE account_networks SET generation=generation+1 WHERE user_id=?",u.user.id);
  assert.equal((await f.confirm(u,superseded)).statusCode,409);
  f.advance(61);await f.change(u);const value=f.confirmation();
  const results=await Promise.all([f.confirm(u,value),f.confirm(u,value)]);
  assert.deepEqual(results.map(r=>r.statusCode).sort(),[200,400]);
});

test("anti-spam is per account; an active-IP request does not invalidate a pending remote challenge",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);await f.launch(native);await f.change(u);const value=f.confirmation();
  assert.equal((await f.change(u,A)).json().error,"network_change_not_needed");
  assert.equal((await f.change(u,B)).statusCode,429);assert.equal(f.mail.length,1);
  for(let i=0;i<4;i++){f.advance(61);assert.equal((await f.change(u)).statusCode,200);}
  f.advance(61);assert.equal((await f.change(u)).statusCode,429);assert.equal(f.mail.length,5);
  assert.equal((await f.confirm(u,value)).statusCode,400,"newer challenges replace old ones");
  assert.equal((await f.confirm(u,f.confirmation())).statusCode,200);
});

test("failed SMTP cannot leave a valid confirmation or change the active network",async t=>{
  const f=await fixture(t,{},()=>({accepted:[],rejected:[]})),u=f.user(),native=f.device(u);await f.launch(native);
  assert.equal((await f.change(u)).statusCode,503);const value=f.confirmation();
  assert.equal((await f.confirm(u,value)).statusCode,400);assert.equal((await f.launch(native,A)).statusCode,200);assert.equal((await f.launch(native,B)).statusCode,403);
});

test("an in-flight older email cannot revive a replaced challenge and pending delivery cannot be confirmed",async t=>{
  let release,started,count=0;
  const sending=new Promise(resolve=>{started=resolve});
  const f=await fixture(t,{},message=>++count===1 ? new Promise(resolve=>{release=()=>resolve({accepted:[message.to.address],rejected:[]});started();}) : {accepted:[message.to.address],rejected:[]});
  const u=f.user(),native=f.device(u);await f.launch(native);
  const first=f.change(u);await sending;
  try {
    const old=f.confirmation();assert.equal((await f.confirm(u,old)).statusCode,400);
    f.advance(61);assert.equal((await f.change(u,C)).statusCode,200);const newer=f.confirmation();
    release();assert.equal((await first).statusCode,200);
    assert.equal((await f.confirm(u,old)).statusCode,400);
    assert.equal(f.store.get("SELECT hash FROM network_changes").hash,digest(newer));
    assert.equal((await f.confirm(u,newer)).statusCode,200);
    assert.equal((await f.launch(native,C)).statusCode,200);assert.equal((await f.launch(native,B)).statusCode,403);
  }
  finally {release();await first;}
});

test("IPv6 equivalence is accepted while a second address in the same prefix still needs confirmation",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);
  assert.equal((await f.launch(native,"2606:4700:4700::1111")).statusCode,200);
  assert.equal((await f.launch(native,"2606:4700:4700:0:0:0:0:1111")).statusCode,200);
  assert.equal((await f.launch(native,"2606:4700:4700::2222")).statusCode,403);
  assert.equal((await f.launch(native,A)).statusCode,403);
});

test("unauthenticated, browser-only, unentitled or revoked devices cannot establish a first network",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);
  assert.equal((await f.launch("invalid")).statusCode,401);
  assert.equal((await f.req("launch-ticket",{method:"POST",body:{},session:u.session})).statusCode,403);
  f.store.run("UPDATE entitlements SET status='canceled' WHERE user_id=?",u.user.id);
  assert.equal((await f.launch(native)).statusCode,402);
  f.store.run("UPDATE entitlements SET status='active' WHERE user_id=?",u.user.id);
  f.store.run("UPDATE devices SET revoked=1 WHERE user_id=?",u.user.id);
  assert.equal((await f.launch(native)).statusCode,401);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM account_networks").n,0);
});

test("additive migration/reopening preserves old accounts and access; pepper drift cannot silently rebind them",()=>{
  const dir=mkdtempSync(join(tmpdir(),"playmelt-network-migrate-")),path=join(dir,"fixture.sqlite");
  let db,store;
  const policy=()=>registerNetworkPolicy({get(){},post(){}},{store,
    options:networkPolicyOptions({networkEnabled:true,networkOriginQualified:true,networkIPSource:"direct",networkPepper:PEPPER}),
    url:p=>ORIGIN+BASE+p,config:{},mailer:{},browser(){},fail(){}});
  try {
    db=new DatabaseSync(path);
    db.exec(`CREATE TABLE users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,created INTEGER NOT NULL);
      CREATE TABLE sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL,device_id TEXT,expires INTEGER NOT NULL);
      CREATE TABLE devices(id TEXT PRIMARY KEY,user_id TEXT NOT NULL,label TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL);
      CREATE TABLE entitlements(id TEXT PRIMARY KEY,user_id TEXT NOT NULL,plan TEXT NOT NULL,status TEXT NOT NULL,until INTEGER,invoice TEXT,payment_intent TEXT,updated INTEGER NOT NULL);
      INSERT INTO users VALUES('legacy','legacy@example.test',12);
      INSERT INTO devices VALUES('mac','legacy','Existing Mac',0,13);
      INSERT INTO entitlements VALUES('licence','legacy','lifetime','active',NULL,NULL,NULL,14);`);
    db.prepare("INSERT INTO sessions VALUES(?,'legacy','mac',2100000000)").run(digest("existing-token"));db.close();db=null;
    store=new Store(path,()=>1900000000);const p=policy();
    assert.equal(p.authorize({ip:A},{code(){throw Error("denied")}},store.authenticate("existing-token")).networkGeneration,1);
    const saved=store.get("SELECT * FROM account_networks");store.close();store=new Store(path,()=>1900000000);policy();
    assert.deepEqual(store.get("SELECT * FROM account_networks"),saved);
    assert.equal(store.authenticate("existing-token").id,"legacy");assert.equal(store.entitlement("legacy").plan,"lifetime");
    assert.equal(store.get("SELECT created FROM users WHERE id='legacy'").created,12);
    assert.throws(()=>registerNetworkPolicy({get(){},post(){}},{store,
      options:networkPolicyOptions({networkEnabled:true,networkOriginQualified:true,networkIPSource:"direct",networkPepper:Buffer.alloc(32,43)})}),/rotation/);
    assert.deepEqual(store.get("SELECT * FROM account_networks"),saved);
  } finally {db?.close();store?.close();rmSync(dir,{recursive:true,force:true});}
});

test("forwarded/Cloudflare headers never set direct identity; protected Passenger header requires qualified transport and public scalar IP",async t=>{
  const direct=await fixture(t),u=direct.user(),native=direct.device(u);
  assert.equal((await direct.launch(native,A,{"x-forwarded-for":B,"cf-connecting-ip":B,"!~passenger-client-address":B})).statusCode,200);
  assert.equal((await direct.launch(native,B,{"x-forwarded-for":A})).statusCode,403);
  const f=await fixture(t,{networkIPSource:"passenger-protected",networkPassengerPeers:["127.0.0.1"]}),p=f.user(),device=f.device(p);
  assert.equal((await f.launch(device,"127.0.0.1",{"x-forwarded-for":A,"cf-connecting-ip":A})).statusCode,503);
  assert.equal((await f.launch(device,C,{"!~passenger-client-address":A})).statusCode,503);
  for(const value of ["host.example",A+","+B,"127.0.0.1"])
    assert.equal((await f.launch(device,"127.0.0.1",{"!~passenger-client-address":value})).statusCode,503);
  assert.equal((await f.launch(device,"127.0.0.1",{"!~passenger-client-address":A,"x-forwarded-for":B})).statusCode,200);
  assert.equal((await f.launch(device,"127.0.0.1",{"!~passenger-client-address":B,"x-forwarded-for":A})).statusCode,403);
});

test("invalid/nonpublic request source never binds even when body or public headers claim an allowed IP",async t=>{
  const f=await fixture(t),u=f.user(),native=f.device(u);
  assert.equal((await f.launch(native,"127.0.0.1",{"x-forwarded-for":A})).statusCode,503);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM account_networks").n,0);
  await f.launch(native,A);
  assert.equal((await f.change(u,"192.168.1.1")).statusCode,503);
});

test("private pepper loader validates separation, exact size, private modes and no symlinks",()=>{
  const dir=realpathSync(mkdtempSync(join(tmpdir(),"playmelt-network-config-")));
  try {
    const privateRoot=join(dir,"private"),documentRoot=join(dir,"public"),path=join(privateRoot,"network.key");mkdirSync(privateRoot);mkdirSync(documentRoot);writeFileSync(path,PEPPER,{mode:0o600});
    const env={PLAYMELT_NETWORK_ENABLED:"1",PLAYMELT_NETWORK_ORIGIN_QUALIFIED:"1",PLAYMELT_NETWORK_IP_SOURCE:"direct",PLAYMELT_NETWORK_PEPPER_FILE:path};
    const options={privateRoot,documentRoot,signingKeyFile:join(privateRoot,"signing.key")};
    assert.equal(loadNetworkPolicy(env,options).networkPepper.length,32);
    assert.throws(()=>loadNetworkPolicy({...env,PLAYMELT_NETWORK_TRUSTED_PROXIES:"127.0.0.1"},options));
    chmodSync(path,0o644);assert.throws(()=>loadNetworkPolicy(env,options));chmodSync(path,0o600);
    writeFileSync(path,Buffer.alloc(31));assert.throws(()=>loadNetworkPolicy(env,options));writeFileSync(path,PEPPER);
    assert.throws(()=>loadNetworkPolicy(env,{...options,signingKeyFile:path}));
    const link=join(privateRoot,"link.key");symlinkSync(path,link);assert.throws(()=>loadNetworkPolicy({...env,PLAYMELT_NETWORK_PEPPER_FILE:link},options));
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test("simultaneous first launches through independent SQLite workers bind only one IP",async()=>{
  const dir=mkdtempSync(join(tmpdir(),"playmelt-network-race-")),path=join(dir,"fixture.sqlite"),workers=[];
  const store=new Store(path);const u=store.consumeMagic(store.magic("race@example.test")).user;
  const code=`import {parentPort,workerData} from 'node:worker_threads';
    import {Store} from ${JSON.stringify(new URL("../src/store.mjs",import.meta.url).href)};
    import {registerNetworkPolicy,networkPolicyOptions} from ${JSON.stringify(new URL("../src/network-policy.mjs",import.meta.url).href)};
    const store=new Store(workerData.path);const policy=registerNetworkPolicy({get(){},post(){}},{store,
      options:networkPolicyOptions({networkEnabled:true,networkOriginQualified:true,networkIPSource:'direct',networkPepper:Buffer.alloc(32,42)}),
      browser(){},mailer:{},config:{},url:p=>'https://network.example.test'+p,fail(){}});
    parentPort.postMessage({ready:true});parentPort.once('message',()=>{try{const reply={status:200,code(n){this.status=n;return this},send(){}};
      const allowed=policy.authorize({ip:workerData.ip},reply,{id:workerData.id});parentPort.postMessage({status:reply.status,allowed:!!allowed});}
      finally{store.close();parentPort.close()}});`;
  try {
    const ready=[],done=[];
    for(const ip of [A,B]){
      const worker=new Worker(new URL("data:text/javascript,"+encodeURIComponent(code)),{workerData:{path,id:u.id,ip}});workers.push(worker);
      ready.push(new Promise((resolve,reject)=>{worker.on("message",m=>{if(m.ready)resolve()});worker.on("error",reject)}));
      done.push(new Promise((resolve,reject)=>{worker.on("message",m=>{if(m.status)resolve(m)});worker.on("error",reject)}));
    }
    await Promise.all(ready);workers.forEach(w=>w.postMessage("go"));const results=await Promise.all(done);
    assert.deepEqual(results.map(r=>r.status).sort(),[200,403]);assert.equal(store.get("SELECT COUNT(*) AS n FROM account_networks").n,1);
  } finally {await Promise.allSettled(workers.map(w=>w.terminate()));store.close();rmSync(dir,{recursive:true,force:true});}
});
