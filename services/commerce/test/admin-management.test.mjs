import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

async function fixture(t) {
  let now = 1900000000;
  const store = new Store(":memory:", () => now);
  const app = await createApp({ store, config: { testing: true, publicURL: "https://example.test/account", live: false,
    prices: {}, signingKey: generateKeyPairSync("ed25519").privateKey,
    adminEmails: ["admin@example.test", "second@example.test"], supportAdmins: ["support@example.test"] },
    stripe: {}, mailer: { sendMail: async (message) => ({ accepted: [message.to.address] }) } });
  t.after(() => app.close());
  const user = (email) => store.consumeMagic(store.magic(email));
  const req = (u, method, path, payload, headers = {}) => app.inject({ method, url: "/account/v1/admin" + path, payload,
    headers: { ...(u ? { cookie: "pm_session=" + u.session } : {}), origin: "https://example.test", ...headers } });
  const admin = user("admin@example.test"), buyer = user("buyer@example.test");
  const grant = (target = buyer, body = {}) => req(admin, "POST", "/accounts/" + target.user.id + "/promotions",
    { days: 7, reason: "Campagne de découverte", requestId: randomUUID(), confirmed: true, ...body });
  const entitlement = (u, { id = randomUUID(), plan = "monthly", status = "active", until = now + 86400, payment = null } = {}) => {
    store.run("INSERT INTO entitlements VALUES(?,?,?,?,?,NULL,?,?)", id, u.user.id, plan, status, until, payment, now);
    return id;
  };
  return { app, store, user, req, admin, buyer, grant, entitlement, now: () => now, setNow: (value) => { now = value; } };
}

test("all management reads and writes reject anonymous, support-only, customer, device and bearer sessions", async (t) => {
  const f = await fixture(t), support = f.user("support@example.test");
  const device = f.store.device("Test Mac", digest("proof"));
  f.store.approveDevice(device.userCode, f.admin.user.id);
  const paired = f.store.exchangeDevice(device.deviceCode, "proof");
  const routes = ["/accounts", "/accounts/" + f.buyer.user.id, "/registrations"];
  for (const path of routes) {
    assert.equal((await f.req(null, "GET", path)).statusCode, 401);
    assert.equal((await f.req(support, "GET", path)).statusCode, 403);
    assert.equal((await f.req(f.buyer, "GET", path)).statusCode, 403);
    assert.equal((await f.req(null, "GET", path, undefined, { authorization: "Bearer " + f.admin.session })).statusCode, 403);
    assert.equal((await f.req(null, "GET", path, undefined, { cookie: "pm_session=" + paired.token })).statusCode, 403);
  }
  const body = { days: 7, reason: "Découverte", requestId: randomUUID(), confirmed: true };
  const path = "/accounts/" + f.buyer.user.id + "/promotions";
  for (const [u, status] of [[null, 401], [support, 403], [f.buyer, 403]]) assert.equal((await f.req(u, "POST", path, body)).statusCode, status);
  assert.equal((await f.req(f.admin, "POST", path, body, { origin: "https://other.test" })).statusCode, 403);
  assert.equal((await f.req(null, "POST", path, body, { authorization: "Bearer " + f.admin.session })).statusCode, 403);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 0);
});

test("accounts search is literal, filters use real active rights and pages are bounded and stable", async (t) => {
  const f = await fixture(t);
  f.store.setInternalEmails([f.admin.user.email]);
  const percent = f.user("percent%buyer@example.test"), google = f.user("google@example.test");
  f.store.run("INSERT INTO password_credentials VALUES(?,?,?)", f.buyer.user.id, "secret-hash", f.now());
  f.store.run("INSERT INTO oauth_identities VALUES('google','private-subject',?,?)", google.user.id, f.now());
  f.entitlement(f.buyer, { status: "trialing" });
  f.entitlement(google, { plan: "lifetime", until: null });
  for (let i = 0; i < 125; i++) f.store.run("INSERT INTO users(id,email,created) VALUES(?,?,?)", "seed_" + i, "seed" + i + "@example.test", f.now());
  const get = async (q) => (await f.req(f.admin, "GET", "/accounts?" + q)).json();
  assert.deepEqual((await get("q=%25")).items.map((u) => u.id), [percent.user.id]);
  assert.equal((await get("scope=internal")).total, 1);
  assert.equal((await get("scope=customers&method=password&access=trialing")).items[0].id, f.buyer.user.id);
  assert.equal((await get("method=google&access=lifetime")).items[0].id, google.user.id);
  const one = await get("pageSize=100"), two = await get("page=2&pageSize=100");
  assert.equal(one.items.length, 100);
  assert.equal(one.total, 129);
  assert.equal(two.items.length, 29);
  assert.equal(new Set([...one.items, ...two.items].map((u) => u.id)).size, 129);
  for (const q of ["page=0", "page=1.5", "pageSize=10000", "scope=unknown", "access=free", "method=token", "q=" + "a".repeat(161)])
    assert.equal((await f.req(f.admin, "GET", "/accounts?" + q)).statusCode, 400);
  assert.equal((await get("q=no-such-email")).total, 0);
});

test("invalidated email links are not authentication evidence and pending registrations exclude existing, expired and consumed links", async (t) => {
  const f = await fixture(t), invalidated = f.user("invalidated@example.test");
  f.store.run("UPDATE magic_links SET confirmed=NULL WHERE email=?", invalidated.user.email);
  const token = f.store.magic("pending@example.test");
  f.store.run("INSERT INTO password_registrations VALUES(?,?)", digest(token), "must-never-leave");
  f.store.magic("pending@example.test");
  f.store.magic(f.buyer.user.email);
  const expired = f.store.magic("expired@example.test");
  f.store.run("UPDATE magic_links SET expires=? WHERE hash=?", f.now(), digest(expired));
  const registrations = (await f.req(f.admin, "GET", "/registrations")).json();
  assert.equal(registrations.total, 1);
  assert.deepEqual(registrations.items[0], { email: "pending@example.test", expires: f.now() + 900, pendingLinks: 2, passwordRequested: true });
  assert.ok(!JSON.stringify(registrations).includes(digest(token)));
  assert.ok(!JSON.stringify(registrations).includes("must-never-leave"));
  const filtered = (await f.req(f.admin, "GET", "/accounts?method=email_link")).json();
  assert.ok(!filtered.items.some((u) => u.id === invalidated.user.id));
  f.store.consumeMagic(token);
  assert.equal((await f.req(f.admin, "GET", "/registrations")).json().total, 0);
});

test("customer detail is bounded, includes current rights, and never reveals credentials, codes, session or billing IDs", async (t) => {
  const f = await fixture(t), code = f.store.issueOwnerCode(f.buyer.user.email);
  f.store.run("UPDATE users SET stripe_customer='cus_private' WHERE id=?", f.buyer.user.id);
  f.store.run("INSERT INTO password_credentials VALUES(?,?,?)", f.buyer.user.id, "private-password-hash", f.now());
  for (let i = 0; i < 25; i++) {
    f.entitlement(f.buyer, { status: "expired" });
    f.store.run("INSERT INTO devices VALUES(?,?,?,0,?)", "d" + i, f.buyer.user.id, "Mac " + i, f.now());
  }
  const response = await f.req(f.admin, "GET", "/accounts/" + f.buyer.user.id), d = response.json();
  assert.equal(d.registration, "account_created");
  assert.equal(d.entitlements.total, 25);
  assert.equal(d.entitlements.items.length, 20);
  assert.equal(d.devices.total, 25);
  assert.equal(d.devices.items.length, 20);
  assert.equal(d.ownerCodes.items[0].state, "available");
  for (const secret of [code, digest(code), f.buyer.session, "private-password-hash", "cus_private"]) assert.ok(!response.body.includes(secret));
  assert.equal((await f.req(f.admin, "GET", "/accounts/no-such-id")).statusCode, 404);
});

test("overview totals retain all receipts while exposing only the latest 100 and no invented visitor identities", async (t) => {
  const f = await fixture(t);
  f.store.setInternalEmails([f.admin.user.email]);
  f.store.transaction(() => {
    for (let i = 0; i < 130; i++) {
      f.store.run("INSERT INTO payment_reserves VALUES(?,?,?,?,?,?,?)", "receipt" + i, f.buyer.user.id, "pi" + i, 100, "eur", f.now(), f.now() + 86400);
      f.store.run("INSERT INTO blocked_payments VALUES(?, 'review')", "pi" + i);
    }
    f.store.run("INSERT INTO payment_reserves VALUES('internal',?,'pi_internal',99999,'eur',?,?)", f.admin.user.id, f.now(), f.now() + 86400);
  });
  f.store.activity("page_view", "site.direct");
  const overview = (await f.req(f.admin, "GET", "/overview")).json();
  assert.equal(overview.payments.length, 100);
  assert.equal(overview.totals.receiptsCents, 13000);
  assert.equal(overview.totals.flaggedPayments, 130);
  assert.equal(overview.series.at(-1).receiptsCents, 13000);
  assert.equal(overview.totals.pageViews, 1);
  assert.equal(overview.uniqueVisitors, undefined);
  assert.equal(overview.visitors, undefined);
});

test("promotional grant is temporary, audited, idempotent and cannot silently extend or become lifetime", async (t) => {
  const f = await fixture(t), requestId = randomUUID();
  const first = await f.grant(f.buyer, { days: 30, requestId }), g = first.json();
  assert.equal(first.statusCode, 201);
  assert.equal(g.plan, "promotional");
  assert.equal(g.until, f.now() + 30 * 86400);
  assert.equal(f.store.entitlement(f.buyer.user.id).id, g.id);
  assert.equal((await f.grant(f.buyer, { days: 30, requestId })).statusCode, 200);
  assert.equal((await f.grant(f.buyer, { days: 90, requestId })).json().error, "idempotency_conflict");
  assert.equal((await f.grant()).json().error, "already_has_access");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements WHERE user_id=?", f.buyer.user.id).n, 1);
  const audit = f.store.get("SELECT * FROM admin_access_audit WHERE entitlement_id=?", g.id);
  assert.equal(audit.actor_id, f.admin.user.id);
  assert.equal(audit.user_id, f.buyer.user.id);
  assert.equal(audit.duration_days, 30);
  assert.equal(audit.reason, "Campagne de découverte");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 1);
  f.setNow(g.until);
  assert.equal(f.store.entitlement(f.buyer.user.id), null);
  assert.equal(f.store.get("SELECT until FROM entitlements WHERE id=?", g.id).until, g.until);
  const freshAdmin = f.user("admin@example.test");
  const ninety = await f.req(freshAdmin, "POST", "/accounts/" + f.buyer.user.id + "/promotions",
    { days: 90, reason: "Nouvelle campagne explicite", requestId: randomUUID(), confirmed: true });
  assert.equal(ninety.statusCode, 201);
  assert.equal(ninety.json().until, f.now() + 90 * 86400);
});

test("promotion schema rejects unconfirmed, extra, unlimited and malformed mutations before any write", async (t) => {
  const f = await fixture(t);
  for (const patch of [{ days: 0 }, { days: "7" }, { days: 365 }, { days: null }, { confirmed: false },
    { reason: " " }, { reason: "a".repeat(301) }, { reason: "invalid\nreason" }, { requestId: "not-uuid" }, { plan: "lifetime" }])
    assert.equal((await f.grant(f.buyer, patch)).statusCode, 400);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 0);
});

test("paid, lifetime, trial, internal and flagged payment accounts cannot receive a promotional grant", async (t) => {
  const f = await fixture(t);
  for (const [name, plan, status, until] of [["paid", "monthly", "active", f.now() + 100], ["life", "lifetime", "active", null], ["trial", "monthly", "trialing", f.now() + 100]]) {
    const u = f.user(name + "@example.test"); f.entitlement(u, { plan, status, until });
    assert.equal((await f.grant(u)).json().error, "already_has_access");
  }
  f.store.setInternalEmails([f.admin.user.email]);
  assert.equal((await f.grant(f.admin)).json().error, "customer_required");
  f.entitlement(f.buyer, { status: "expired", payment: "pi_flagged" });
  f.store.run("INSERT INTO blocked_payments VALUES('pi_flagged','dispute')");
  assert.equal((await f.grant()).json().error, "payment_review_required");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 0);
});

test("revocation is scoped to the target promotion, audited once, and preserves later paid access", async (t) => {
  const f = await fixture(t), g = (await f.grant()).json();
  const other = f.user("other@example.test"), second = f.user("second@example.test");
  const paid = f.entitlement(f.buyer, { id: "sub_paid", until: f.now() + 90 * 86400 });
  const body = { requestId: randomUUID(), reason: "Fin de la campagne", confirmed: true };
  const path = "/accounts/" + f.buyer.user.id + "/promotions/" + g.id + "/revoke";
  assert.equal((await f.req(null, "POST", path, body)).statusCode, 401);
  assert.equal((await f.req(f.admin, "POST", path, body, { origin: "https://other.test" })).statusCode, 403);
  assert.equal((await f.req(f.admin, "POST", "/accounts/" + other.user.id + "/promotions/" + g.id + "/revoke", body)).statusCode, 404);
  assert.equal((await f.req(f.buyer, "POST", path, body)).statusCode, 403);
  assert.equal((await f.req(second, "POST", path, body)).statusCode, 200);
  assert.equal((await f.req(second, "POST", path, body)).json().replayed, true);
  assert.equal((await f.req(second, "POST", path, { ...body, reason: "Autre motif" })).statusCode, 409);
  assert.equal(f.store.get("SELECT status FROM entitlements WHERE id=?", g.id).status, "revoked");
  assert.equal(f.store.entitlement(f.buyer.user.id).id, paid);
  assert.equal(f.store.get("SELECT status FROM entitlements WHERE id=?", paid).status, "active");
  const audits = f.store.all("SELECT actor_id,action FROM admin_access_audit ORDER BY action");
  assert.deepEqual(audits.map((a) => ({ ...a })), [{ actor_id: f.admin.user.id, action: "grant" }, { actor_id: second.user.id, action: "revoke" }]);
  const detail = (await f.req(f.admin, "GET", "/accounts/" + f.buyer.user.id)).json();
  assert.equal(detail.promotionAudit.total, 2);
  assert.ok(detail.promotionAudit.items.some((a) => a.actor === second.user.email));
});

test("failed audit insertion rolls back the whole promotional grant", async (t) => {
  const f = await fixture(t), original = f.store.run.bind(f.store);
  f.store.run = (sql, ...args) => {
    if (sql.startsWith("INSERT INTO admin_access_audit")) throw Error("isolated audit failure");
    return original(sql, ...args);
  };
  assert.equal((await f.grant()).statusCode, 503);
  f.store.run = original;
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 0);
  const g = (await f.grant()).json();
  f.store.run = (sql, ...args) => {
    if (sql.startsWith("INSERT INTO admin_access_audit")) throw Error("isolated revoke audit failure");
    return original(sql, ...args);
  };
  assert.equal((await f.req(f.admin, "POST", "/accounts/" + f.buyer.user.id + "/promotions/" + g.id + "/revoke",
    { reason: "Révocation test", requestId: randomUUID(), confirmed: true })).statusCode, 503);
  f.store.run = original;
  assert.equal(f.store.get("SELECT status FROM entitlements WHERE id=?", g.id).status, "active");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM admin_access_audit").n, 1);
});
