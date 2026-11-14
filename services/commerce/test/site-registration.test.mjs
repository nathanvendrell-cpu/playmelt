import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

const ORIGIN = "https://registration.example.test";
const PASSWORD = "My first private phrase 42";
const NEXT = "My second private phrase 73";
async function fixture(t, delivery) {
  const store = new Store(":memory:"), mail = [];
  const { privateKey } = generateKeyPairSync("ed25519");
  const app = await createApp({ store, config: {
    testing: true, publicURL: ORIGIN + "/Playmelt/compte", live: false,
    billingEnabled: false, prices: {}, signingKey: privateKey,
    mailFrom: "fixture@example.test", adminEmails: [], internalEmails: [],
  }, stripe: {}, mailer: { sendMail: async (message) => {
    mail.push(message);
    return delivery ? delivery(message) : { accepted: [message.to.address], rejected: [] };
  } } });
  t.after(() => app.close());
  const request = (path, payload, session) => app.inject({ method: payload === undefined ? "GET" : "POST",
    url: "/Playmelt/compte/v1/" + path, payload,
    headers: { origin: ORIGIN, ...(session ? { cookie: "pm_session=" + session } : {}) } });
  const session = (response) => response.headers["set-cookie"]?.match(/pm_session=([^;]+)/)?.[1];
  const flush = () => new Promise(setImmediate);
  return { store, app, mail, request, session, flush };
}

test("registering a known email sends a safe recovery path without assigning the submitted password", async (t) => {
  const f = await fixture(t), previous = f.store.consumeMagic(f.store.magic("returning@example.test"));
  const response = await f.request("auth/register", { email: previous.user.email, password: PASSWORD, intent: "download" });
  await f.flush();
  assert.deepEqual(response.json(), { requested: true });
  assert.equal(f.mail.length, 1);
  assert.equal(f.mail[0].to.address, previous.user.email);
  assert.ok(!f.mail[0].text.includes(PASSWORD));
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM password_credentials").n, 0);
  assert.ok(f.store.authenticate(previous.session));
  const reset = f.mail[0].text.match(/#reset=([\w-]+)/)?.[1];
  assert.ok(reset);
  assert.match(f.mail[0].text, /\?intent=download/);
  const confirmed = await f.request("auth/password/reset/confirm", { token: reset, password: NEXT });
  assert.equal(confirmed.statusCode, 200);
  assert.ok(f.store.authenticate(f.session(confirmed)));
  assert.equal((await f.request("auth/login", { email: previous.user.email, password: PASSWORD })).statusCode, 401);
  const signedIn = await f.request("auth/login", { email: previous.user.email, password: NEXT });
  assert.equal(signedIn.statusCode, 200);
  const me = await f.request("me", undefined, f.session(signedIn));
  assert.equal(me.statusCode, 200);
  assert.equal(me.json().id, previous.user.id);
  assert.equal(me.json().hasPassword, true);
  assert.equal(me.json().isAdmin, false);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
});

test("a fresh registration can confirm, sign in and manage its own password with only the newest confirmation link", async (t) => {
  const f = await fixture(t), email = "new@example.test";
  for (const password of [PASSWORD, NEXT]) {
    assert.equal((await f.request("auth/register", { email, password })).statusCode, 200);
    await f.flush();
  }
  assert.equal(f.mail.length, 2);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
  const [oldToken, latest] = f.mail.map((message) => message.text.match(/#token=([\w-]+)/)[1]);
  assert.equal((await f.request("auth/confirm", { token: oldToken })).statusCode, 400);
  assert.equal(f.store.get("SELECT confirmed FROM magic_links WHERE hash=?", digest(oldToken)).confirmed, null);
  const confirmed = await f.request("auth/confirm", { token: latest });
  assert.equal(confirmed.statusCode, 200);
  assert.equal(f.store.get("SELECT confirmed FROM magic_links WHERE hash=?", digest(latest)).confirmed, f.store.now());
  const cookie = f.session(confirmed);
  const me = await f.request("me", undefined, cookie);
  assert.equal(me.json().email, email);
  assert.equal(me.json().hasPassword, true);
  assert.equal(me.json().entitlement, null);
  assert.equal(me.json().isAdmin, false);
  assert.equal((await f.request("auth/password", { currentPassword: NEXT, password: PASSWORD }, cookie)).statusCode, 200);
  assert.equal((await f.request("auth/login", { email, password: PASSWORD })).statusCode, 200);
  assert.equal((await f.request("auth/confirm", { token: latest })).statusCode, 400);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
});

test("SMTP responses that do not accept the recipient invalidate pending confirmation and recovery links", async (t) => {
  for (const [name, delivery] of [["empty accepted list", () => ({ accepted: [], rejected: [] })], ["missing SMTP receipt", () => undefined]]) {
    await t.test(name, async (t) => {
      const f = await fixture(t, delivery);
      await f.request("auth/register", { email: "new@example.test", password: PASSWORD });
      await f.flush();
      const token = f.mail[0].text.match(/#token=([\w-]+)/)[1];
      assert.equal(f.store.get("SELECT used FROM magic_links WHERE hash=?", digest(token)).used, 1);
      assert.equal(f.store.get("SELECT confirmed FROM magic_links WHERE hash=?", digest(token)).confirmed, null);
      assert.equal(f.store.get("SELECT password_hash FROM password_registrations WHERE magic_hash=?", digest(token)).password_hash, "");
      assert.equal((await f.request("auth/confirm", { token })).statusCode, 400);
      const previous = f.store.consumeMagic(f.store.magic("known@example.test"));
      await f.request("auth/password/reset", { email: previous.user.email });
      await f.flush();
      assert.equal(f.store.get("SELECT used FROM password_resets WHERE user_id=?", previous.user.id).used, 1);
      assert.ok(f.store.authenticate(previous.session));
    });
  }
});

test("email sign-in refuses an absent SMTP acceptance and its link cannot open a session", async (t) => {
  for (const [name, delivery] of [["empty accepted list", () => ({ accepted: [], rejected: [] })], ["missing SMTP receipt", () => undefined],
    ["wrong recipient", () => ({ accepted: ["someone-else@example.test"] })],
    ["contradictory rejection", () => ({ accepted: ["new@example.test"], rejected: ["new@example.test"] })]]) {
    await t.test(name, async (t) => {
      const f = await fixture(t, delivery);
      const response = await f.request("auth/email", { email: "new@example.test" });
      assert.equal(response.statusCode, 503);
      assert.deepEqual(response.json(), { error: "service_unavailable" });
      const token = f.mail[0].text.match(/#token=([\w-]+)/)[1];
      assert.equal(f.store.get("SELECT used FROM magic_links WHERE hash=?", digest(token)).used, 1);
      assert.equal(f.store.get("SELECT confirmed FROM magic_links WHERE hash=?", digest(token)).confirmed, null);
      assert.equal((await f.request("auth/confirm", { token })).statusCode, 400);
      assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
    });
  }
});

test("email sign-in supplies a verified session and account recovery when no password exists", async (t) => {
  const f = await fixture(t);
  const response = await f.request("auth/email", { email: "email-only@example.test", intent: "download", source: "app" });
  assert.equal(response.statusCode, 200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
  assert.match(f.mail[0].text, /\?intent=download&source=app/);
  const token = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  const confirmed = await f.request("auth/confirm", { token });
  assert.equal(confirmed.statusCode, 200);
  const me = await f.request("me", undefined, f.session(confirmed));
  assert.equal(me.json().email, "email-only@example.test");
  assert.equal(me.json().hasPassword, false);
  assert.equal(me.json().isAdmin, false);
  assert.equal((await f.request("auth/password", { password: PASSWORD }, f.session(confirmed))).statusCode, 200);
  assert.equal((await f.request("auth/login", { email: "email-only@example.test", password: PASSWORD })).statusCode, 200);
});

test("registration distinguishes malformed input and bounds recovery mail for an existing account", async (t) => {
  const f = await fixture(t), user = f.store.consumeMagic(f.store.magic("known@example.test")).user;
  assert.deepEqual((await f.request("auth/register", { email: "bad-address", password: PASSWORD })).json(), { error: "invalid_email" });
  for (let attempt = 0; attempt < 4; attempt++)
    assert.deepEqual((await f.request("auth/register", { email: user.email, password: PASSWORD })).json(), { requested: true });
  await f.flush();
  assert.equal(f.mail.length, 3);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM password_credentials").n, 0);
});
