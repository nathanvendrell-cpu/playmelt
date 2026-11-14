import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store, digest, token } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";
import { hashPassword, validNewPassword } from "../src/passwords.mjs";

const PASSWORD = "A private testing phrase 42";
const NEXT = "A different testing phrase 73";
const ORIGIN = "https://example.test";
async function fixture(t, mailHandler) {
  let now = 1900000000;
  const store = new Store(":memory:", () => now), mail = [];
  const keys = generateKeyPairSync("ed25519");
  const config = { testing: true, publicURL: ORIGIN + "/account", live: false,
    billingEnabled: false, prices: {}, signingKey: keys.privateKey, mailFrom: "fixture@example.test",
    adminEmails: ["owner@example.test"], supportAdmins: ["owner@example.test"], internalEmails: ["owner@example.test"] };
  const app = await createApp({ store, config, stripe: {}, mailer: { sendMail: async (m) => { mail.push(m); return mailHandler ? mailHandler(m) : { accepted: [m.to.address] }; } } });
  t.after(() => app.close());
  const req = (method, path, payload, session, extra = {}) => app.inject({ method, url: "/account" + path, payload,
    headers: { origin: ORIGIN, ...(session ? { cookie: "pm_session=" + session } : {}), ...extra } });
  const user = (email = "owner@example.test") => store.consumeMagic(store.magic(email));
  const setup = (u, password = PASSWORD) => req("POST", "/v1/auth/password", { password }, u.session);
  const login = (email, password = PASSWORD, device = false) => req("POST", "/v1/auth/" + (device ? "device-login" : "login"), { email, password, label: "Fixture Mac" });
  const sessionCookie = (r) => r.headers["set-cookie"].match(/pm_session=([^;]+)/)[1];
  return { app, store, config, mail, req, user, setup, login, keys, sessionCookie, advance: (n) => { now += n; } };
}
test("password setup stores a salted expensive hash and preserves existing owner access, tokens and lifetime entitlement", async (t) => {
  const f = await fixture(t), u = f.user();
  f.store.redeemOwnerCode(f.store.issueOwnerCode(u.user.email), u.user);
  const d = f.store.device("Existing Mac", digest("existing-proof"));
  f.store.approveDevice(d.userCode, u.user.id);
  const paired = f.store.exchangeDevice(d.deviceCode, "existing-proof");
  assert.equal((await f.req("GET", "/v1/me", undefined, u.session)).json().hasPassword, false);
  assert.equal((await f.setup(u)).statusCode, 200);
  const credential = f.store.get("SELECT * FROM password_credentials WHERE user_id=?", u.user.id);
  assert.match(credential.hash, /^scrypt\$131072\$8\$1\$/);
  assert.ok(!JSON.stringify(credential).includes(PASSWORD));
  assert.ok(f.store.authenticate(u.session));
  assert.ok(f.store.authenticate(paired.token));
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
  assert.equal((await f.req("GET", "/v1/me", undefined, u.session)).json().hasPassword, true);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users WHERE is_internal=0").n, 0);
});
test("browser login creates only an HttpOnly session and returns the same credential error for all failures", async (t) => {
  const f = await fixture(t), u = f.user();
  await f.setup(u);
  f.user("no-password@example.test");
  for (const [email, password] of [[u.user.email, NEXT], ["absent@example.test", PASSWORD], ["no-password@example.test", PASSWORD]]) {
    const r = await f.login(email, password);
    assert.equal(r.statusCode, 401);
    assert.deepEqual(r.json(), { error: "invalid_credentials" });
    assert.equal(r.headers["set-cookie"], undefined);
  }
  const r = await f.login(u.user.email);
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { signedIn: true });
  assert.match(r.headers["set-cookie"], /HttpOnly/);
  assert.match(r.headers["set-cookie"], /SameSite=Strict/);
  assert.ok(f.store.authenticate(f.sessionCookie(r)));
});
test("device login binds a restricted token, never grants a licence and never grants administration", async (t) => {
  const f = await fixture(t), u = f.user();
  await f.setup(u);
  const response = await f.login(u.user.email, PASSWORD, true), body = response.json();
  assert.equal(response.statusCode, 200);
  assert.match(body.token, /^[A-Za-z0-9_-]{43}$/);
  assert.match(body.deviceID, /^[a-f0-9-]{36}$/);
  assert.equal(body.expiresIn, 2592000);
  assert.equal(response.headers["set-cookie"], undefined);
  const bearer = { authorization: "Bearer " + body.token };
  assert.equal((await f.req("POST", "/v1/launch-ticket", {}, undefined, bearer)).statusCode, 402);
  assert.equal((await f.req("GET", "/v1/admin/overview", undefined, undefined, bearer)).statusCode, 403);
  assert.equal((await f.req("POST", "/v1/auth/password", { password: NEXT }, undefined, bearer)).statusCode, 403);
  f.store.redeemOwnerCode(f.store.issueOwnerCode(u.user.email), u.user);
  const ticket = (await f.req("POST", "/v1/launch-ticket", {}, undefined, bearer)).json().ticket;
  const [payload, signature] = ticket.split(".");
  assert.ok(verify(null, Buffer.from(payload), f.keys.publicKey, Buffer.from(signature, "base64url")));
  assert.equal(JSON.parse(Buffer.from(payload, "base64url")).device, body.deviceID);
});
test("failed logins are bounded per account and the limit expires", async (t) => {
  const f = await fixture(t), u = f.user(); await f.setup(u);
  for (let i = 0; i < 8; i++) assert.equal((await f.login(u.user.email, NEXT)).statusCode, 401);
  const blocked = await f.login(u.user.email);
  assert.equal(blocked.statusCode, 429);
  assert.ok(Number(blocked.headers["retry-after"]) > 0);
  f.advance(901);
  assert.equal((await f.login(u.user.email)).statusCode, 200);
});
test("changing a password needs the current secret, invalidates reset links and rejects an old login already in flight", async (t) => {
  const f = await fixture(t), u = f.user(); await f.setup(u);
  assert.equal((await f.req("POST", "/v1/auth/password", { password: NEXT }, u.session)).statusCode, 401);
  await f.req("POST", "/v1/auth/password/reset", { email: u.user.email });
  const reset = f.mail.at(-1).text.match(/#reset=([\w-]+)/)[1];
  const nextHash = await hashPassword(NEXT);
  const flight = f.login(u.user.email);
  await new Promise(setImmediate);
  f.store.run("UPDATE password_credentials SET hash=? WHERE user_id=?", nextHash, u.user.id);
  assert.equal((await flight).statusCode, 401);
  assert.equal((await f.req("POST", "/v1/auth/password", { password: PASSWORD, currentPassword: NEXT }, u.session)).statusCode, 200);
  assert.equal((await f.req("POST", "/v1/auth/password/reset/confirm", { token: reset, password: NEXT })).statusCode, 400);
  assert.ok(f.store.authenticate(u.session));
});
test("reset is one-use, changes only the target account, revokes its Playmelt sessions and preserves its licence", async (t) => {
  const f = await fixture(t), u = f.user(), other = f.user("other@example.test");
  await f.setup(u); f.store.redeemOwnerCode(f.store.issueOwnerCode(u.user.email), u.user);
  const native = (await f.login(u.user.email, PASSWORD, true)).json();
  const magicBeforeReset = f.store.magic(u.user.email);
  const googleGrant = token(), googleVerifier = token();
  f.store.run("INSERT INTO google_native_grants VALUES(?,?,?,?)", digest(googleGrant), u.user.id, digest(googleVerifier), f.store.now() + 60);
  const pending = f.store.device("Pending Mac", digest("pending-proof"));
  f.store.approveDevice(pending.userCode, u.user.id);
  const unknown = await f.req("POST", "/v1/auth/password/reset", { email: "absent@example.test" });
  assert.deepEqual(unknown.json(), { requested: true }); assert.equal(f.mail.length, 0);
  const request = await f.req("POST", "/v1/auth/password/reset", { email: u.user.email });
  assert.deepEqual(request.json(), unknown.json());
  const value = f.mail.at(-1).text.match(/#reset=([\w-]+)/)[1];
  assert.ok(!f.mail.at(-1).text.includes(PASSWORD));
  assert.notEqual(f.store.get("SELECT hash FROM password_resets").hash, value);
  const response = await f.req("POST", "/v1/auth/password/reset/confirm", { token: value, password: NEXT });
  assert.equal(response.statusCode, 200);
  assert.ok(f.store.authenticate(f.sessionCookie(response)));
  assert.equal(f.store.authenticate(u.session), undefined);
  assert.equal(f.store.authenticate(native.token), undefined);
  assert.equal(f.store.consumeMagic(magicBeforeReset), null);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_native_grants WHERE user_id=?", u.user.id).n, 0);
  assert.equal(f.store.exchangeDevice(pending.deviceCode, "pending-proof").error, "expired_token");
  assert.ok(f.store.authenticate(other.session));
  assert.equal(f.store.entitlement(u.user.id).plan, "lifetime");
  assert.equal((await f.req("POST", "/v1/auth/password/reset/confirm", { token: value, password: PASSWORD })).statusCode, 400);
  assert.equal((await f.login(u.user.email, NEXT)).statusCode, 200);
});
test("expired reset links and foreign origins cannot change credentials", async (t) => {
  const f = await fixture(t), u = f.user(); await f.setup(u);
  assert.equal((await f.req("POST", "/v1/auth/login", { email: u.user.email, password: PASSWORD }, undefined, { origin: "https://evil.test" })).statusCode, 403);
  assert.equal((await f.req("POST", "/v1/auth/device-login", { email: u.user.email, password: PASSWORD }, undefined, { origin: "https://evil.test" })).statusCode, 403);
  await f.req("POST", "/v1/auth/password/reset", { email: u.user.email });
  const value = f.mail.at(-1).text.match(/#reset=([\w-]+)/)[1]; f.advance(901);
  assert.equal((await f.req("POST", "/v1/auth/password/reset/confirm", { token: value, password: NEXT })).statusCode, 400);
  assert.equal((await f.login(u.user.email)).statusCode, 200);
});
test("registration keeps the password off email/URLs, creates no account before verification and cannot assign an existing owner's password", async (t) => {
  const f = await fixture(t), owner = f.user();
  const body = { email: "new@example.test", password: PASSWORD, intent: "download", source: "site" };
  assert.equal((await f.req("POST", "/v1/auth/register", body)).statusCode, 200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  const mail = f.mail.at(-1), value = mail.text.match(/#token=([\w-]+)/)[1];
  assert.ok(!mail.text.includes(PASSWORD));
  assert.match(f.store.get("SELECT password_hash FROM password_registrations").password_hash, /^scrypt\$/);
  assert.equal((await f.req("POST", "/v1/auth/confirm", { token: value })).statusCode, 200);
  assert.equal(f.store.get("SELECT password_hash FROM password_registrations").password_hash, "");
  assert.equal((await f.login(body.email)).statusCode, 200);
  const count = f.mail.length;
  assert.equal((await f.req("POST", "/v1/auth/register", { email: owner.user.email, password: NEXT })).statusCode, 200);
  assert.equal(f.mail.length, count + 1);
  assert.match(f.mail.at(-1).text, /#reset=/);
  assert.ok(!f.mail.at(-1).text.includes(NEXT));
  assert.equal(f.store.get("SELECT * FROM password_credentials WHERE user_id=?", owner.user.id), undefined);
  assert.ok(f.store.authenticate(owner.session));
});
test("password phrases retain spaces and unicode, while short or oversized values are rejected", async (t) => {
  const f = await fixture(t), u = f.user();
  assert.equal(validNewPassword(" short "), false);
  assert.equal(validNewPassword("a".repeat(129)), false);
  const value = "  Ma longue phrase été 🎮  ";
  assert.equal((await f.setup(u, value)).statusCode, 200);
  assert.equal((await f.login(u.user.email, value)).statusCode, 200);
  assert.equal((await f.login(u.user.email, value.trim())).statusCode, 401);
});

test("unknown mailboxes receive the same failed-login throttle as existing accounts", async (t) => {
  const f = await fixture(t);
  for (let i = 0; i < 8; i++) assert.equal((await f.login("unknown@example.test")).statusCode, 401);
  const ninth = await f.login("unknown@example.test");
  assert.equal(ninth.statusCode, 429);
  assert.equal(ninth.headers["retry-after"], "900");
  f.advance(901);
  assert.equal((await f.login("unknown@example.test")).statusCode, 401);
});

test("native login accepts an absent Origin while browser login still requires its own Origin", async (t) => {
  const f = await fixture(t), u = f.user(); await f.setup(u);
  const payload = { email: u.user.email, password: PASSWORD, label: "Native Mac" };
  const native = await f.app.inject({ method: "POST", url: "/account/v1/auth/device-login", payload });
  assert.equal(native.statusCode, 200);
  assert.ok(f.store.authenticate(native.json().token));
  assert.equal((await f.app.inject({ method: "POST", url: "/account/v1/auth/login", payload })).statusCode, 403);
});

test("reset replies before SMTP and close drains pending mail before closing the database", async (t) => {
  let finish;
  const f = await fixture(t, () => new Promise((resolve) => { finish = resolve; })), u = f.user();
  const response = await f.req("POST", "/v1/auth/password/reset", { email: u.user.email });
  assert.deepEqual(response.json(), { requested: true });
  assert.equal(typeof finish, "function");
  const reset = f.mail[0].text.match(/#reset=([\w-]+)/)[1];
  assert.equal(f.store.get("SELECT used FROM password_resets WHERE hash=?", digest(reset)).used, 0);
  let closed = false;
  const originalClose = f.store.close.bind(f.store);
  f.store.close = () => {
    assert.equal(f.store.get("SELECT used FROM password_resets WHERE hash=?", digest(reset)).used, 1);
    closed = true; originalClose();
  };
  const closing = f.app.close();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(closed, false);
  finish({ rejected: [u.user.email] });
  await closing;
  assert.equal(closed, true);
});

test("registration mail failure clears the pending credential instead of creating an account", async (t) => {
  const f = await fixture(t, () => { throw Error("fixture delivery failure"); });
  assert.equal((await f.req("POST", "/v1/auth/register", { email: "new@example.test", password: PASSWORD })).statusCode, 200);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
  assert.equal(f.store.get("SELECT used FROM magic_links").used, 1);
  assert.equal(f.store.get("SELECT password_hash FROM password_registrations").password_hash, "");
});

test("salted credentials, existing sessions and the internal lifetime licence survive reopening SQLite", async () => {
  const directory = mkdtempSync(join(tmpdir(), "playmelt-auth-")), path = join(directory, "account.sqlite");
  let store;
  try {
    store = new Store(path); store.setInternalEmails(["owner@example.test"]);
    const u = store.consumeMagic(store.magic("owner@example.test"));
    store.redeemOwnerCode(store.issueOwnerCode(u.user.email), u.user);
    const hash = await hashPassword(PASSWORD);
    store.run("INSERT INTO password_credentials VALUES(?,?,?)", u.user.id, hash, store.now());
    store.close(); store = new Store(path);
    assert.equal(store.get("SELECT hash FROM password_credentials WHERE user_id=?", u.user.id).hash, hash);
    assert.ok(store.authenticate(u.session));
    assert.equal(store.authenticate(u.session).is_internal, 1);
    assert.equal(store.entitlement(u.user.id).plan, "lifetime");
  } finally { store?.close(); rmSync(directory, { recursive: true, force: true }); }
});
