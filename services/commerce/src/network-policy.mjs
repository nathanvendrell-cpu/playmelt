import { isIP, BlockList } from "node:net";
import { createHmac, createHash } from "node:crypto";
import { constants, openSync, fstatSync, readFileSync, closeSync, realpathSync } from "node:fs";
import { isAbsolute, dirname, relative, sep, resolve } from "node:path";
import { digest, token } from "./store.mjs";
import { normalizeEmail } from "./email.mjs";

// Conservative public-unicast policy. Special-use ranges are not customer
// network identities. See the IANA IPv4/IPv6 special-purpose registries.
const special = new BlockList();
for (const [ip, bits] of [["0.0.0.0",8],["10.0.0.0",8],["100.64.0.0",10],["127.0.0.0",8],
  ["169.254.0.0",16],["172.16.0.0",12],["192.0.0.0",24],["192.0.2.0",24],["192.88.99.0",24],
  ["192.168.0.0",16],["198.18.0.0",15],["198.51.100.0",24],["203.0.113.0",24],["224.0.0.0",4],["240.0.0.0",4]])
  special.addSubnet(ip, bits, "ipv4");
for (const [ip,bits] of [["2001::",23],["2001:db8::",32],["2002::",16],["3fff::",20]]) special.addSubnet(ip,bits,"ipv6");

export function normalizeNetworkIP(value) {
  if (typeof value !== "string" || value.length > 64 || /[%\[\]\s]/.test(value)) return null;
  const family = isIP(value);
  if (family === 4) return { canonical: value, family: 4, masked: value.split(".").slice(0,3).join(".") + ".*" };
  if (family !== 6) return null;
  let canonical;
  try { canonical = new URL("http://[" + value + "]/").hostname.slice(1,-1); } catch { return null; }
  const [left,right] = canonical.split("::"), a = left ? left.split(":") : [], b = right ? right.split(":") : [];
  const groups = right === undefined ? a : [...a,...Array(8-a.length-b.length).fill("0"),...b];
  if (groups.length !== 8) return null;
  const numbers = groups.map((part) => parseInt(part,16));
  if (numbers.slice(0,5).every((part) => part === 0) && numbers[5] === 65535)
    return normalizeNetworkIP([numbers[6] >> 8,numbers[6] & 255,numbers[7] >> 8,numbers[7] & 255].join("."));
  return { canonical: numbers.map((part) => part.toString(16).padStart(4,"0")).join(":"), family: 6,
    masked: numbers.slice(0,3).map((part) => part.toString(16)).join(":") + ":…" };
}

export function publicNetworkIP(value) {
  const ip = normalizeNetworkIP(value);
  if (!ip || special.check(ip.canonical, ip.family === 4 ? "ipv4" : "ipv6")) return null;
  // IPv6 global unicast currently occupies 2000::/3. This also rejects mapped,
  // NAT64, ULA, link-local, loopback and multicast sources unless mapped to IPv4.
  if (ip.family === 6 && (parseInt(ip.canonical.slice(0,4),16) & 0xe000) !== 0x2000) return null;
  return ip;
}

export function networkPolicyOptions(config) {
  if (config.trustProxy !== undefined && config.trustProxy !== false) throw Error("Unqualified proxy configuration");
  if (config.networkEnabled !== true) return { enabled: false, trustProxy: false };
  if (config.networkOriginQualified !== true || !Buffer.isBuffer(config.networkPepper) || config.networkPepper.length !== 32 ||
      !["direct","passenger-protected"].includes(config.networkIPSource)) throw Error("Qualified network configuration required");
  let passengerPeers = [];
  if (config.networkIPSource === "passenger-protected") {
    const values = config.networkPassengerPeers;
    if (!Array.isArray(values) || values.length === 0 || values.length > 16 ||
        values.some((value) => !normalizeNetworkIP(value))) throw Error("Explicit Passenger transport peers required");
    passengerPeers = [...new Set(values.map((value) => normalizeNetworkIP(value).canonical))];
  } else if (config.networkPassengerPeers?.length) throw Error("Direct network source cannot accept Passenger headers");
  if (config.networkTrustedProxies?.length) throw Error("Forwarded header network identity is not supported");
  return { enabled:true,trustProxy:false,pepper:config.networkPepper,source:config.networkIPSource,passengerPeers };
}

export function loadNetworkPolicy(env, { privateRoot, documentRoot, signingKeyFile }) {
  if (env.PLAYMELT_NETWORK_ENABLED !== "1") return { networkEnabled: false };
  if (env.PLAYMELT_NETWORK_TRUSTED_PROXIES) throw Error("Forwarded header network identity is not supported");
  const path = env.PLAYMELT_NETWORK_PEPPER_FILE;
  if (!path || !isAbsolute(path) || resolve(path) === resolve(signingKeyFile)) throw Error("Separate private network pepper required");
  const root = realpathSync(privateRoot), parent = realpathSync(dirname(path)), document = realpathSync(documentRoot);
  const inside = (base,target) => { const part = relative(base,target); return part !== ".." && !part.startsWith(".." + sep) && !isAbsolute(part); };
  if (parent !== resolve(dirname(path)) || !inside(root,parent) || inside(document,path)) throw Error("Private network pepper required");
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  let networkPepper;
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size !== 32 || stat.nlink !== 1 || stat.mode & 0o077 ||
        (process.getuid && stat.uid !== process.getuid())) throw Error("Private 32-byte network pepper required");
    networkPepper = readFileSync(fd);
  } finally { closeSync(fd); }
  const value = { networkEnabled: true, networkPepper,
    networkOriginQualified: env.PLAYMELT_NETWORK_ORIGIN_QUALIFIED === "1",
    networkIPSource: env.PLAYMELT_NETWORK_IP_SOURCE,
    networkPassengerPeers: env.PLAYMELT_NETWORK_PASSENGER_PEERS ? env.PLAYMELT_NETWORK_PASSENGER_PEERS.split(",").map((part) => part.trim()) : [] };
  networkPolicyOptions(value);
  return value;
}

export function registerNetworkPolicy(api, { store, options, browser, mailer, config, url, fail }) {
  const deliveries = new Set();
  const fingerprint = options.enabled ? createHash("sha256").update(options.pepper).digest("hex") : null;
  if (options.enabled) store.transaction(() => {
    store.run("INSERT OR IGNORE INTO service_state VALUES('network_pepper_fingerprint',?)", fingerprint);
    if (store.get("SELECT value FROM service_state WHERE key='network_pepper_fingerprint'").value !== fingerprint)
      throw Error("Network pepper rotation requires explicit maintenance");
  });
  const accountURL = url("/") + "#network";
  const active = (id) => store.get("SELECT * FROM account_networks WHERE user_id=?", id);
  const sourceIP = (req) => {
    if (options.source === "direct") return publicNetworkIP(req.ip);
    const peer = normalizeNetworkIP(req.raw?.socket?.remoteAddress);
    if (!peer || !options.passengerPeers.includes(peer.canonical)) return null;
    // Only usable after the host proves Passenger rejects these client-sent
    // headers AND Apache's effective client value is correct through every ingress.
    // Never fall back to XFF, CF-Connecting-IP or a hostname from this header.
    return publicNetworkIP(req.headers["!~passenger-client-address"]);
  };
  const identity = (req,user) => {
    const ip = sourceIP(req);
    if (!ip) return null;
    return { hash: createHmac("sha256", options.pepper).update("playmelt-network-v1\0" + user.id + "\0" + ip.canonical).digest("hex"), masked: ip.masked };
  };
  const pending = (id) => !!store.get("SELECT hash FROM network_changes WHERE user_id=? AND used=0 AND delivery='sent' AND expires>?", id, store.now());
  api.get("/v1/network/config", async () => ({ networkEnabled: options.enabled }));
  api.get("/v1/network", async (req,reply) => {
    const user = browser(req,reply); if (!user) return;
    if (!options.enabled) return { enabled:false,phase:"unbound",activeNetworkMasked:null,currentNetworkMasked:null,changePending:false };
    const current = identity(req,user); if (!current) return fail(reply,503,"network_source_unavailable");
    const saved = active(user.id);
    return { enabled:true,phase:!saved ? "unbound" : saved.ip_hash === current.hash ? "active" : "change_required",
      activeNetworkMasked:saved?.masked ?? null,currentNetworkMasked:current.masked,changePending:pending(user.id) };
  });
  api.post("/v1/network/change", async (req,reply) => {
    const user = browser(req,reply); if (!user) return;
    if (!options.enabled) return fail(reply,409,"network_policy_disabled");
    if (!req.body || typeof req.body !== "object" || Array.isArray(req.body) || Object.keys(req.body).length) return fail(reply,400,"invalid_request");
    if (deliveries.size >= 8) { reply.header("Retry-After","20"); return fail(reply,429,"too_many_requests"); }
    const target = identity(req,user); if (!target) return fail(reply,503,"network_source_unavailable");
    const value = token(), hash = digest(value), now = store.now();
    const result = store.transaction(() => {
      const saved = active(user.id);
      if (!saved) return "network_not_bound";
      if (saved.ip_hash === target.hash) return "network_change_not_needed";
      const limit = store.get("SELECT * FROM network_change_limits WHERE user_id=?", user.id);
      if (limit && (now-limit.last_requested < 60 || (now-limit.window_started < 3600 && limit.requests >= 5))) return "too_many_requests";
      store.run("INSERT INTO network_change_limits VALUES(?,?,1,?) ON CONFLICT(user_id) DO UPDATE SET window_started=excluded.window_started,requests=?,last_requested=excluded.last_requested",
        user.id,limit && now-limit.window_started < 3600 ? limit.window_started : now,now,
        limit && now-limit.window_started < 3600 ? limit.requests+1 : 1);
      store.run("INSERT INTO network_changes VALUES(?,?,?,?,?,?,?,0,'pending') ON CONFLICT(user_id) DO UPDATE SET hash=excluded.hash,target_hash=excluded.target_hash,target_masked=excluded.target_masked,generation=excluded.generation,created=excluded.created,expires=excluded.expires,used=0,delivery='pending'",
        user.id,hash,target.hash,target.masked,saved.generation,now,now+600);
      return saved;
    });
    if (typeof result === "string") {
      if (result === "too_many_requests") reply.header("Retry-After","60");
      return fail(reply,result === "too_many_requests" ? 429 : 409,result);
    }
    const job = (async () => {
      let accepted = false;
      try {
        const sent = await mailer.sendMail({ from:config.mailFrom,to:{address:user.email},subject:"Confirmez votre nouveau réseau Playmelt",
        text:`Pour autoriser le réseau ${target.masked} à la place de ${result.masked}, connectez-vous à votre compte puis confirmez ce lien, valable 10 minutes :\n\n${url("/")}#networkToken=${value}\n\nLe réseau autorisé sera celui de votre demande initiale, même si vous confirmez depuis un téléphone ou une autre connexion. Vos comptes, appareils, jeux et paiements sont conservés. Si vous n’avez pas demandé ce changement, ignorez cet e-mail.` });
        accepted = Array.isArray(sent?.accepted) && sent.accepted.some((email) => normalizeEmail(email) === user.email) && !sent?.rejected?.length;
      } catch { /* Never log a challenge, recipient or source address. */ }
      store.run("UPDATE network_changes SET delivery=?,used=? WHERE user_id=? AND hash=?",accepted ? "sent" : "failed",accepted ? 0 : 1,user.id,hash);
      return accepted;
    })();
    deliveries.add(job);
    void job.then(() => deliveries.delete(job),() => deliveries.delete(job));
    const accepted = await job;
    return accepted ? { requested:true } : fail(reply,503,"network_email_unavailable");
  });
  api.post("/v1/network/confirm", async (req,reply) => {
    const user = browser(req,reply); if (!user) return;
    if (!options.enabled) return fail(reply,409,"network_policy_disabled");
    if (!sourceIP(req)) return fail(reply,503,"network_source_unavailable");
    const value = req.body?.token;
    if (!req.body || typeof req.body !== "object" || Array.isArray(req.body) || Object.keys(req.body).some((key) => key !== "token") ||
        typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value))
      return fail(reply,400,"invalid_network_challenge");
    const error = store.transaction(() => {
      const challenge = store.get("SELECT * FROM network_changes WHERE user_id=? AND hash=? AND used=0 AND delivery='sent' AND expires>?",user.id,digest(value),store.now());
      if (!challenge) return "invalid_network_challenge";
      const changed = store.run("UPDATE account_networks SET ip_hash=?,masked=?,generation=generation+1,updated=? WHERE user_id=? AND generation=?",
        challenge.target_hash,challenge.target_masked,store.now(),user.id,challenge.generation);
      store.run("UPDATE network_changes SET used=1 WHERE user_id=?",user.id);
      return changed.changes === 1 ? null : "network_change_superseded";
    });
    return error ? fail(reply,error === "network_change_superseded" ? 409 : 400,error) : { changed:true };
  });
  return {
    drain: () => Promise.allSettled([...deliveries]),
    authorize(req,reply,user) {
      if (!options.enabled) return {};
      const current = identity(req,user); if (!current) { fail(reply,503,"network_source_unavailable"); return null; }
      const saved = store.transaction(() => {
        store.run("INSERT OR IGNORE INTO account_networks VALUES(?,?,?,1,?)",user.id,current.hash,current.masked,store.now());
        return active(user.id);
      });
      if (saved.ip_hash !== current.hash) { reply.code(403).send({error:"network_change_required",accountURL}); return null; }
      return { networkGeneration:saved.generation };
    },
  };
}
