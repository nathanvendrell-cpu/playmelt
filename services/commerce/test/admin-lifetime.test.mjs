import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Store, digest, token } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { grantLifetimeAccess, revokeLifetimeAccess } from "../src/admin.mjs";

const ORIGIN = "https://lifetime.example.test";
const body = (extra = {}) => ({ reason: "Attribution client explicite", requestId: randomUUID(), confirmed: true, ...extra });
async function fixture(t) {
  const now = 1900000000, store = new Store(":memory:", () => now), keys = generateKeyPairSync("ed25519");
  let stripeCalls = 0;
  const app = await createApp({ store, config: {
    testing: true, live: false, billingEnabled: false, publicURL: ORIGIN + "/account", prices: {}, signingKey: keys.privateKey,
    adminEmails: ["owner@example.test", "second@example.test"], internalEmails: ["owner@example.test", "second@example.test"],
    supportAdmins: ["support@example.test"],
  }, stripe: new Proxy({}, { get() { stripeCalls++; throw Error("Stripe must not be used"); } }),
  mailer: { sendMail: async () => { throw Error("No email expected"); } } });
  t.after(() => app.close());
  const user = (email) => store.consumeMagic(store.magic(email));
  const owner = user("owner@example.test"), buyer = user("buyer@example.test");
  const req = (u, method, path, payload, headers = {}) => app.inject({ method, url: "/account/v1" + path, payload,
    headers: { origin: ORIGIN, ...(u ? { cookie: "pm_session=" + u.session } : {}), ...headers } });
  const path = (u = buyer) => "/admin/accounts/" + u.user.id + "/lifetime";
  const grant = (u = buyer, payload = body(), actor = owner) => req(actor, "POST", path(u), payload);
  const revoke = (id, u = buyer, payload = body(), actor = owner) => req(actor, "POST", path(u) + "/" + id + "/revoke", payload);
  const detail = async (u = buyer) => (await req(owner, "GET", "/admin/accounts/" + u.user.id)).json();
  const entitlement = (u, { id = randomUUID(), plan = "monthly", status = "active", until = now + 86400, payment = null } = {}) => {
    store.run("INSERT INTO entitlements VALUES(?,?,?,?,?,NULL,?,?)", id, u.user.id, plan, status, until, payment, now);
    return id;
  };
  return { store, app, keys, now, user, owner, buyer, req, path, grant, revoke, detail, entitlement, stripeCalls: () => stripeCalls };
}

test("lifetime mutations require the existing browser admin session and same origin", async (t) => {
  const f = await fixture(t), support = f.user("support@example.test");
  const request = f.store.device("Fixture", digest("proof")); f.store.approveDevice(request.userCode, f.owner.user.id);
  const paired = f.store.exchangeDevice(request.deviceCode, "proof");
  for (const path of [f.path(), f.path() + "/admin_lifetime_" + randomUUID() + "/revoke"]) {
    for (const [u, code] of [[null, 401], [f.buyer, 403], [support, 403]])
      assert.equal((await f.req(u, "POST", path, body())).statusCode, code);
    assert.equal((await f.req(f.owner, "POST", path, body(), { origin: "https://other.test" })).statusCode, 403);
    assert.equal((await f.req(null, "POST", path, body(), { authorization: "Bearer " + f.owner.session })).statusCode, 403);
    assert.equal((await f.req(null, "POST", path, body(), { cookie: "pm_session=" + paired.token })).statusCode, 403);
  }
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_lifetime_access_audit").n, 0);
});

test("lifetime input is exact, confirmed, bounded and cannot choose plan, price, actor or expiry", async (t) => {
  const f = await fixture(t);
  const invalid = [body({ confirmed: false }), body({ reason: "ab" }), body({ reason: "x".repeat(301) }),
    body({ reason: "line\nbreak" }), body({ requestId: "invalid" }), body({ until: null }),
    body({ plan: "lifetime" }), body({ price: 0 }), body({ actor: f.owner.user.id }), body({ days: 7 })];
  for (const value of invalid) assert.equal((await f.grant(f.buyer, value)).statusCode, 400);
  assert.equal((await f.grant(f.buyer, { reason: "Valid reason", confirmed: true })).statusCode, 400);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
});

test("a targeted lifetime grant is permanent, audited and grants neither billing changes nor administration", async (t) => {
  const f = await fixture(t), payload = body();
  f.store.run("UPDATE users SET stripe_customer='cus_fixture_preserved' WHERE id=?", f.buyer.user.id);
  const beforeUser = f.store.get("SELECT * FROM users WHERE id=?", f.buyer.user.id);
  assert.equal((await f.detail()).lifetimeAccess.canGrant, true);
  const response = await f.grant(f.buyer, payload), result = response.json();
  assert.equal(response.statusCode, 201);
  assert.match(result.id, /^admin_lifetime_[a-f0-9-]{36}$/);
  assert.deepEqual({ plan: result.plan, phase: result.phase, until: result.until }, { plan: "lifetime", phase: "active", until: null });
  assert.equal(result.billingUnaffected, true); assert.match(result.billingNotice, /ne résilie ni ne modifie/);
  assert.deepEqual(f.store.get("SELECT * FROM users WHERE id=?", f.buyer.user.id), beforeUser);
  assert.ok(f.store.authenticate(f.buyer.session));
  const e = f.store.get("SELECT * FROM entitlements WHERE id=?", result.id);
  assert.equal(e.user_id, f.buyer.user.id); assert.equal(e.payment_intent, null); assert.equal(e.invoice, null);
  const detail = await f.detail();
  assert.equal(detail.lifetimeAccess.available, true); assert.equal(detail.lifetimeAccess.canGrant, false);
  assert.deepEqual(detail.lifetimeAccess.revocableGrants, [{ id: result.id, created: f.now }]);
  assert.deepEqual(detail.lifetimeAccess.audit.items, [{ action: "grant", actor: f.owner.user.email, reason: payload.reason, created: f.now }]);
  assert.equal((await f.req(f.buyer, "GET", "/me")).json().isAdmin, false);
  assert.equal((await f.req(f.buyer, "GET", "/admin/overview")).statusCode, 403);
  assert.equal(f.stripeCalls(), 0);
});

test("internal accounts, existing lifetime rights and blocked payments fail closed without mutations", async (t) => {
  const f = await fixture(t), paid = f.user("paid-lifetime@example.test"), blocked = f.user("blocked@example.test"), reserve = f.user("reserve@example.test");
  f.entitlement(paid, { plan: "lifetime", until: null, payment: "pi_lifetime" });
  f.entitlement(blocked, { status: "canceled", payment: "pi_blocked" });
  f.store.run("INSERT INTO blocked_payments VALUES('pi_blocked','dispute')");
  f.store.run("INSERT INTO blocked_payments VALUES('pi_reserve','refund')");
  f.store.run("INSERT INTO payment_reserves VALUES(?,?,?,?,?,?,?)", "reserve", reserve.user.id, "pi_reserve", 1999, "eur", f.now, f.now + 86400);
  for (const [u, error] of [[f.owner, "customer_required"], [paid, "already_has_lifetime"], [blocked, "payment_review_required"], [reserve, "payment_review_required"]]) {
    const response = await f.grant(u);
    assert.equal(response.statusCode, 409); assert.equal(response.json().error, error);
    const capability = (await f.detail(u)).lifetimeAccess;
    assert.equal(capability.canGrant, false); assert.ok(capability.blockedReason);
  }
  assert.equal((await f.req(f.owner, "POST", "/admin/accounts/" + randomUUID() + "/lifetime", body())).statusCode, 404);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_lifetime_access_audit").n, 0);
});

test("paid subscriptions, trials and promotions remain intact when explicit lifetime access is added and removed", async (t) => {
  for (const mode of ["paid", "trial", "promo"]) await t.test(mode, async (t) => {
    const f = await fixture(t);
    if (mode === "promo") {
      const p = await f.req(f.owner, "POST", "/admin/accounts/" + f.buyer.user.id + "/promotions", { ...body(), days: 7 });
      assert.equal(p.statusCode, 201);
    } else {
      f.entitlement(f.buyer, { status: mode === "trial" ? "trialing" : "active", payment: "pi_preserved" });
      if (mode === "trial") f.store.run("INSERT INTO trials VALUES(?,?,?,?)", f.buyer.user.id, "sub_preserved", f.now, f.now + 86400);
    }
    f.store.run("INSERT INTO checkout_requests VALUES(?,?,?,?,?)", f.buyer.user.id, "monthly", "cs_preserved", "https://checkout.stripe.com/fixture", f.now + 3600);
    const prior = f.store.all("SELECT * FROM entitlements WHERE user_id=? ORDER BY id", f.buyer.user.id);
    const checkout = f.store.get("SELECT * FROM checkout_requests WHERE user_id=?", f.buyer.user.id);
    const trial = f.store.get("SELECT * FROM trials WHERE user_id=?", f.buyer.user.id);
    const promoAudit = f.store.all("SELECT * FROM admin_access_audit WHERE user_id=?", f.buyer.user.id);
    assert.equal((await f.detail()).lifetimeAccess.canGrant, true);
    const response = await f.grant(); assert.equal(response.statusCode, 201); const id = response.json().id;
    assert.equal(f.store.entitlement(f.buyer.user.id).id, id);
    assert.equal((await f.revoke(id)).statusCode, 200);
    assert.deepEqual(f.store.all("SELECT * FROM entitlements WHERE user_id=? AND id<>? ORDER BY id", f.buyer.user.id, id), prior);
    assert.deepEqual(f.store.get("SELECT * FROM checkout_requests WHERE user_id=?", f.buyer.user.id), checkout);
    assert.deepEqual(f.store.get("SELECT * FROM trials WHERE user_id=?", f.buyer.user.id), trial);
    assert.deepEqual(f.store.all("SELECT * FROM admin_access_audit WHERE user_id=?", f.buyer.user.id), promoAudit);
    assert.ok(f.store.entitlement(f.buyer.user.id));
    assert.equal(f.stripeCalls(), 0);
  });
});

test("idempotency is bound to actor, beneficiary, action and reason, including promotion request IDs", async (t) => {
  const f = await fixture(t), payload = body(), second = f.user("second@example.test"), other = f.user("other@example.test");
  const first = await f.grant(f.buyer, payload), id = first.json().id;
  assert.equal((await f.grant(f.buyer, payload)).statusCode, 200);
  assert.equal((await f.grant(f.buyer, { ...payload, requestId: payload.requestId.toUpperCase() })).statusCode, 200);
  for (const response of [await f.grant(f.buyer, { ...payload, reason: "Different reason" }), await f.grant(f.buyer, payload, second), await f.grant(other, payload), await f.revoke(id, f.buyer, payload)])
    assert.equal(response.statusCode, 409);
  const revokeBody = body(); assert.equal((await f.revoke(id, f.buyer, revokeBody)).statusCode, 200);
  assert.equal((await f.revoke(id, f.buyer, revokeBody)).statusCode, 200);
  const replay = await f.grant(f.buyer, payload); assert.equal(replay.statusCode, 200); assert.equal(replay.json().phase, "revoked");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_lifetime_access_audit").n, 2);
  const promotion = await f.req(f.owner, "POST", "/admin/accounts/" + other.user.id + "/promotions", { ...body({ requestId: payload.requestId }), days: 7 });
  assert.equal(promotion.statusCode, 409);
  const freshPromo = body(); assert.equal((await f.req(f.owner, "POST", "/admin/accounts/" + other.user.id + "/promotions", { ...freshPromo, days: 7 })).statusCode, 201);
  assert.equal((await f.grant(other, freshPromo)).statusCode, 409);
});

test("revocation touches only an audited admin lifetime grant for that exact beneficiary", async (t) => {
  const f = await fixture(t), other = f.user("other@example.test");
  const forged = "admin_lifetime_" + randomUUID(); f.entitlement(other, { id: forged, plan: "lifetime", until: null, payment: "pi_paid" });
  const paid = f.store.get("SELECT * FROM entitlements WHERE id=?", forged);
  assert.equal((await f.revoke(forged, other)).statusCode, 404);
  f.store.run("INSERT INTO admin_lifetime_access_audit VALUES(?,?,?,?,'grant',?,?,?)", randomUUID(), forged, other.user.id, f.owner.user.id, "Fixture audit", f.now, randomUUID());
  assert.equal((await f.revoke(forged, other)).statusCode, 404);
  assert.deepEqual((await f.detail(other)).lifetimeAccess.revocableGrants, []);
  const ownerCode = f.store.issueOwnerCode(f.owner.user.email); f.store.redeemOwnerCode(ownerCode, f.owner.user);
  const ownerRight = f.store.entitlement(f.owner.user.id);
  assert.equal((await f.revoke(ownerRight.id, f.owner)).statusCode, 400);
  const response = await f.grant(), id = response.json().id;
  assert.equal((await f.revoke(id, other)).statusCode, 404);
  assert.equal(f.store.entitlement(f.buyer.user.id).id, id);
  assert.equal((await f.revoke(id)).statusCode, 200);
  assert.equal(f.store.entitlement(f.buyer.user.id), null);
  assert.deepEqual(f.store.get("SELECT * FROM entitlements WHERE id=?", forged), paid);
  assert.deepEqual(f.store.entitlement(f.owner.user.id), ownerRight);
});

test("existing signed capability gates use lifetime access and refuse the next grant after its scoped revocation", async (t) => {
  const f = await fixture(t), verifier = token(), request = f.store.device("Fixture Mac", digest(verifier));
  f.store.approveDevice(request.userCode, f.buyer.user.id); const paired = f.store.exchangeDevice(request.deviceCode, verifier);
  const launch = () => f.req(null, "POST", "/launch-ticket", {}, { authorization: "Bearer " + paired.token });
  assert.equal((await launch()).statusCode, 402);
  const grant = await f.grant(), ticket = await launch(); assert.equal(ticket.statusCode, 200);
  const [payload, signature] = ticket.json().ticket.split(".");
  assert.ok(verify(null, Buffer.from(payload), f.keys.publicKey, Buffer.from(signature, "base64url")));
  const decoded = JSON.parse(Buffer.from(payload, "base64url"));
  assert.equal(decoded.sub, f.buyer.user.id); assert.equal(decoded.device, paired.deviceID); assert.equal(decoded.plan, "lifetime");
  assert.deepEqual(decoded.capabilities, ["launch", "runtime.download"]); assert.equal(decoded.exp, f.now + 900);
  await f.revoke(grant.json().id); assert.equal((await launch()).statusCode, 402);
  assert.equal((await f.req(f.buyer, "GET", "/me")).json().isAdmin, false);
});

test("failed audit inserts roll back both lifetime grant and scoped revocation", async (t) => {
  const f = await fixture(t);
  assert.throws(() => grantLifetimeAccess(f.store, { id: "missing-actor" }, f.buyer.user.id, body()), /FOREIGN KEY/);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  const granted = grantLifetimeAccess(f.store, f.owner.user, f.buyer.user.id, body());
  assert.throws(() => revokeLifetimeAccess(f.store, { id: "missing-actor" }, f.buyer.user.id, granted.id, body()), /FOREIGN KEY/);
  assert.equal(f.store.entitlement(f.buyer.user.id).id, granted.id);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_lifetime_access_audit").n, 1);
});

test("lifetime audit history remains counted but its detail payload is bounded", async (t) => {
  const f = await fixture(t);
  for (let i = 0; i < 35; i++) {
    const grant = grantLifetimeAccess(f.store, f.owner.user, f.buyer.user.id, body());
    revokeLifetimeAccess(f.store, f.owner.user, f.buyer.user.id, grant.id, body());
  }
  const d = (await f.detail()).lifetimeAccess;
  assert.equal(d.audit.total, 70); assert.equal(d.audit.items.length, 30); assert.deepEqual(d.revocableGrants, []);
  assert.equal(d.canGrant, true);
});

test("additive lifetime schema preserves the existing promo CHECK, accounts, sessions and rights across reopen", () => {
  const directory = mkdtempSync(join(tmpdir(), "playmelt-lifetime-schema-")), path = join(directory, "fixture.sqlite");
  const now = 1900000000, session = token(); let legacy, store;
  try {
    legacy = new DatabaseSync(path);
    legacy.exec(`CREATE TABLE users(id TEXT PRIMARY KEY,email TEXT NOT NULL UNIQUE,stripe_customer TEXT UNIQUE,created INTEGER NOT NULL,is_internal INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),device_id TEXT,expires INTEGER NOT NULL);
      CREATE TABLE entitlements(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),plan TEXT NOT NULL,status TEXT NOT NULL,until INTEGER,invoice TEXT,payment_intent TEXT,updated INTEGER NOT NULL);
      CREATE TABLE admin_access_audit(id TEXT PRIMARY KEY,entitlement_id TEXT NOT NULL REFERENCES entitlements(id),user_id TEXT NOT NULL REFERENCES users(id),actor_id TEXT NOT NULL REFERENCES users(id),action TEXT NOT NULL CHECK(action IN ('grant','revoke')),duration_days INTEGER,until INTEGER NOT NULL,reason TEXT NOT NULL,created INTEGER NOT NULL,request_id TEXT NOT NULL UNIQUE);`);
    const priorSchema = legacy.prepare("SELECT sql FROM sqlite_master WHERE name='admin_access_audit'").get().sql;
    legacy.prepare("INSERT INTO users VALUES('owner','owner@example.test',NULL,?,1)").run(now);
    legacy.prepare("INSERT INTO users VALUES('buyer','buyer@example.test','cus_preserved',?,0)").run(now);
    legacy.prepare("INSERT INTO sessions VALUES(?,'buyer',NULL,?)").run(digest(session), now + 3600);
    legacy.prepare("INSERT INTO entitlements VALUES('promo_legacy','buyer','promotional','active',?,NULL,NULL,?)").run(now + 86400, now);
    legacy.prepare("INSERT INTO admin_access_audit VALUES('old','promo_legacy','buyer','owner','grant',7,?,'Legacy fixture',?,?)").run(now + 86400, now, randomUUID());
    legacy.close(); legacy = null;
    store = new Store(path, () => now);
    assert.equal(store.get("SELECT sql FROM sqlite_master WHERE name='admin_access_audit'").sql, priorSchema);
    const granted = grantLifetimeAccess(store, { id: "owner" }, "buyer", body());
    store.close(); store = new Store(path, () => now);
    assert.equal(store.entitlement("buyer").id, granted.id); assert.equal(store.entitlement("buyer").until, null);
    assert.equal(store.authenticate(session).id, "buyer"); assert.equal(store.get("SELECT stripe_customer FROM users WHERE id='buyer'").stripe_customer, "cus_preserved");
    assert.equal(store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 1);
    assert.equal(store.get("SELECT status FROM entitlements WHERE id='promo_legacy'").status, "active");
    assert.deepEqual(store.all("PRAGMA foreign_key_check"), []);
  } finally { legacy?.close(); store?.close(); rmSync(directory, { recursive: true, force: true }); }
});
