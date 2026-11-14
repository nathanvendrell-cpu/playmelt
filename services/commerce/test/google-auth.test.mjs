import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { OAuth2Client } from "google-auth-library";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

const ORIGIN = "https://example.test", PREFIX = "/account", BASE = ORIGIN + PREFIX;
const ID = "123456789012-fixtureclient.apps.googleusercontent.com";
const SECRET = "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nt-secret";
const NOW = Math.floor(Date.now() / 1000);
const random = () => randomBytes(32).toString("base64url");
const challenge = (value) => createHash("sha256").update(value).digest("base64url");
const cookieOf = (response, name) => {
  const values = response.headers["set-cookie"] || [];
  return (Array.isArray(values) ? values : [values]).find((value) => value.startsWith(name + "="))?.split(";")[0];
};
const errorOf = (response) => new URL(response.headers.location).searchParams.get("authError");

test("password recovery invalidates already-issued Google native grants for that account only", async (t) => {
  const f = await fixture(t), pending = await f.nativeGrant(), other = await f.nativeGrant({ sub: "other-subject", email: "other@gmail.com" });
  const owner = f.store.get("SELECT user_id FROM google_native_grants WHERE hash=?", digest(pending.code));
  const reset = random();
  f.store.run("INSERT INTO password_resets VALUES(?,?,?,0)", digest(reset), owner.user_id, f.store.now() + 900);
  const changed = await f.req("POST", "/v1/auth/password/reset/confirm", { token: reset, password: "A new private fixture phrase 2026" }, { origin: ORIGIN });
  assert.equal(changed.statusCode, 200);
  const rejected = await f.req("POST", "/v1/auth/google/native/exchange", { code: pending.code, verifier: pending.verifier });
  assert.equal(rejected.statusCode, 401);
  assert.deepEqual(rejected.json(), { error: "invalid_grant" });
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM devices WHERE user_id=?", owner.user_id).n, 0);
  assert.equal((await f.req("POST", "/v1/auth/google/native/exchange", { code: other.code, verifier: other.verifier })).statusCode, 200);
});

class FixtureGoogle extends OAuth2Client {
  constructor() {
    super({ clientId: ID, clientSecret: SECRET, redirectUri: BASE + "/v1/auth/google/callback" });
    this.records = new Map();
    this.exchangeCalls = [];
    this.verifyCalls = [];
  }
  async getToken(options) {
    this.exchangeCalls.push(options);
    const record = this.records.get(options.code);
    if (!record || record.exchangeError) throw Error("fixture transport error with secret token");
    return { tokens: { id_token: record.missingToken ? undefined : options.code,
      access_token: "fixture-access-token-never-persist", refresh_token: "fixture-refresh-token-never-persist" } };
  }
  async verifyIdToken(options) {
    this.verifyCalls.push(options);
    const record = this.records.get(options.idToken);
    if (record.signatureError) throw Error("fixture signature error with private ID token");
    return { getPayload: () => record.payload };
  }
}
async function fixture(t, options = {}) {
  let now = options.now ?? NOW;
  const store = new Store(options.path || ":memory:", () => now), google = options.google || new FixtureGoogle();
  const config = { testing: true, publicURL: BASE, prices: {},
    googleClientID: ID, googleClientSecret: SECRET, googleOAuthClient: google,
    adminEmails: ["owner@gmail.com"], internalEmails: ["owner@gmail.com"], ...options.config };
  let app;
  try { app = await createApp({ store, config, stripe: {}, mailer: {} }); }
  catch (error) { store.close(); throw error; }
  let closed = false;
  const close = async () => { if (!closed) { closed = true; await app.close(); } };
  t.after(close);
  const req = (method, path, payload, headers = {}) => app.inject({ method, url: PREFIX + path, payload, headers });
  const start = async (query = "", headers = {}) => {
    const response = await req("GET", "/v1/auth/google/start" + query, undefined, headers);
    assert.equal(response.statusCode, 303);
    const authorization = new URL(response.headers.location);
    return { response, authorization, state: authorization.searchParams.get("state"),
      nonce: authorization.searchParams.get("nonce"), cookie: cookieOf(response, "pm_google_state") };
  };
  const claims = (flow, extra = {}) => ({ iss: "https://accounts.google.com", aud: ID, sub: "google-subject-1",
    email: "customer@gmail.com", email_verified: true, iat: now - 5, exp: now + 3600, nonce: flow.nonce, ...extra });
  const callback = async (flow, extra = {}, flags = {}) => {
    const code = "fixture-code-" + random();
    google.records.set(code, { payload: claims(flow, extra), ...flags });
    return req("GET", "/v1/auth/google/callback?state=" + flow.state + "&code=" + code, undefined, { cookie: flow.cookie });
  };
  const nativeStart = async (extra = {}) => {
    const verifier = random(), state = random();
    const response = await req("POST", "/v1/auth/google/native/start", { challenge: challenge(verifier), state, ...extra });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(Object.keys(response.json()), ["url"]);
    const location = new URL(response.json().url);
    return { response, location, verifier, state };
  };
  const nativeGrant = async (extraClaims = {}) => {
    const native = await nativeStart(), flow = await start(native.location.search), response = await callback(flow, extraClaims);
    assert.equal(response.statusCode, 303);
    const location = new URL(response.headers.location);
    assert.equal(location.protocol, "playmelt:");
    assert.equal(location.host, "account");
    assert.equal(location.pathname, "/google");
    return { ...native, flow, response, code: location.searchParams.get("code"), returnedState: location.searchParams.get("state") };
  };
  return { store, google, config, req, start, claims, callback, nativeStart, nativeGrant, close, advance: (n) => now += n };
}

test("Google is disabled for missing or malformed server credentials and never offers a partial provider", async (t) => {
  for (const config of [
    { googleClientID: undefined }, { googleClientSecret: undefined },
    { googleClientID: "not-google.example" }, { googleClientSecret: "bad\r\nsecret" },
  ]) {
    const f = await fixture(t, { config });
    assert.deepEqual((await f.req("GET", "/v1/auth/providers")).json(), { google: false });
    assert.equal((await f.req("GET", "/v1/auth/google/start")).statusCode, 503);
    assert.equal((await f.req("POST", "/v1/auth/google/native/start", { challenge: random(), state: random() })).statusCode, 503);
    assert.equal((await f.req("POST", "/v1/auth/google/native/exchange", { code: random(), verifier: random() })).statusCode, 503);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
    await f.close();
  }
});

test("official authorization URL requests only openid/email, online access, nonce and S256 with a separate secure Lax cookie", async (t) => {
  const f = await fixture(t, { config: { testing: false } });
  assert.deepEqual((await f.req("GET", "/v1/auth/providers")).json(), { google: true });
  const flow = await f.start("?intent=download&source=app"), p = flow.authorization.searchParams;
  assert.equal(flow.authorization.origin, "https://accounts.google.com");
  assert.equal(p.get("redirect_uri"), BASE + "/v1/auth/google/callback");
  assert.equal(p.get("scope"), "openid email");
  assert.equal(p.get("access_type"), "online");
  assert.equal(p.get("response_type"), "code");
  assert.equal(p.get("code_challenge_method"), "S256");
  assert.equal(p.get("prompt"), null);
  assert.match(flow.state, /^[A-Za-z0-9_-]{43}$/);
  assert.match(flow.nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(flow.state, flow.nonce);
  const row = f.store.get("SELECT * FROM google_oauth_states");
  assert.equal(challenge(row.verifier), p.get("code_challenge"));
  assert.equal(row.hash, digest(flow.state));
  assert.equal(row.nonce_hash, digest(flow.nonce));
  assert.notEqual(row.browser_hash, flow.cookie.split("=")[1]);
  const setCookie = flow.response.headers["set-cookie"];
  assert.match(setCookie, /HttpOnly/);
  assert.match(setCookie, /Secure/);
  assert.match(setCookie, /SameSite=Lax/);
  assert.match(setCookie, /Path=\/account\/v1\/auth\/google/);
  assert.equal(cookieOf(flow.response, "pm_session"), undefined);
  assert.equal(f.google.exchangeCalls.length, 0); // Test injection is ignored in production.
});

test("Gmail reuses exactly the existing owner account and lifetime licence without ending any existing session", async (t) => {
  const f = await fixture(t), old = f.store.consumeMagic(f.store.magic("owner@gmail.com"));
  f.store.redeemOwnerCode(f.store.issueOwnerCode(old.user.email), old.user);
  const entitlement = f.store.entitlement(old.user.id), flow = await f.start("?intent=download&source=app");
  const response = await f.callback(flow, { email: "OWNER@gmail.com", sub: "owner-google-sub" });
  assert.equal(response.statusCode, 303);
  assert.equal(response.headers.location, BASE + "/?auth=google&intent=download&source=app");
  assert.match(response.headers["set-cookie"].join(";"), /SameSite=Strict/);
  const session = cookieOf(response, "pm_session").split("=")[1];
  assert.equal(f.store.authenticate(session).id, old.user.id);
  assert.equal(f.store.authenticate(old.session).id, old.user.id);
  assert.deepEqual(f.store.entitlement(old.user.id), entitlement);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 1);
  assert.equal(f.store.get("SELECT user_id FROM oauth_identities").user_id, old.user.id);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM activity_daily WHERE kind='customer_login'").n, 0);
  assert.equal(f.google.verifyCalls[0].audience, ID);
  assert.equal(challenge(f.google.exchangeCalls[0].codeVerifier), flow.authorization.searchParams.get("code_challenge"));
  assert.equal(f.google.exchangeCalls[0].redirect_uri, BASE + "/v1/auth/google/callback");
  const replay = await f.req("GET", "/v1/auth/google/callback?state=" + flow.state + "&code=ignored", undefined, { cookie: flow.cookie });
  assert.equal(errorOf(replay), "oauth_failed");
  assert.equal(cookieOf(replay, "pm_session"), undefined);
});

test("non-authoritative e-mail cannot create or take over an account; a known subject keeps its original user and e-mail", async (t) => {
  const f = await fixture(t), existing = f.store.consumeMagic(f.store.magic("third-party@example.test"));
  for (const email of [existing.user.email, "new@example.test"]) {
    const flow = await f.start(), response = await f.callback(flow, { email });
    assert.equal(errorOf(response), "account_link_required");
    assert.equal(cookieOf(response, "pm_session"), undefined);
  }
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM oauth_identities").n, 0);
  f.store.run("INSERT INTO oauth_identities VALUES('google',?,?,?)", "known-sub", existing.user.id, NOW);
  const response = await f.callback(await f.start(), { sub: "known-sub", email: "owner@gmail.com", admin: true });
  const me = await f.req("GET", "/v1/me", undefined, { cookie: cookieOf(response, "pm_session") });
  assert.equal(me.json().id, existing.user.id);
  assert.equal(me.json().email, existing.user.email);
  assert.equal(me.json().isAdmin, false);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
});

test("new authoritative Google accounts are marked internal before activity and never gain a paid entitlement", async (t) => {
  const f = await fixture(t);
  const owner = await f.callback(await f.start(), { email: "owner@gmail.com", sub: "owner-sub" });
  assert.ok(cookieOf(owner, "pm_session"));
  assert.equal(f.store.get("SELECT is_internal FROM users").is_internal, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM activity_daily").n, 0);
  const workspace = await f.callback(await f.start(), { email: "member@workspace.test", hd: "workspace.test", sub: "workspace-sub" });
  assert.ok(cookieOf(workspace, "pm_session"));
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 2);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  assert.equal(f.store.get("SELECT count FROM activity_daily WHERE kind='customer_login'").count, 1);
  assert.equal(f.store.get("SELECT count FROM activity_daily WHERE kind='account_created'").count, 1);
});

test("bad nonce, issuer, audience, expiry, subject, verified e-mail or signature never create a session", async (t) => {
  const cases = [
    [{ nonce: random() }], [{ iss: "https://attacker.example" }], [{ aud: "other.apps.googleusercontent.com" }],
    [{ exp: NOW - 1 }], [{ iat: NOW + 1000 }], [{ sub: "" }], [{ sub: "x".repeat(256) }],
    [{ email_verified: false }], [{ email_verified: "true" }], [{ email: "victim@example.test,another@example.test" }],
    [{ azp: "other-client" }], [{}, { signatureError: true }], [{}, { exchangeError: true }], [{}, { missingToken: true }],
  ];
  for (const [claims, flags] of cases) {
    const f = await fixture(t), flow = await f.start(), response = await f.callback(flow, claims, flags);
    assert.equal(errorOf(response), "oauth_failed", JSON.stringify(claims));
    assert.equal(cookieOf(response, "pm_session"), undefined);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM sessions").n, 0);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
    assert.doesNotMatch(response.body + response.headers.location, /secret token|private ID token|refresh_token/);
    await f.close();
  }
});

test("state requires the originating browser cookie, rejects expiry and cannot be consumed by HEAD or foreign Origin", async (t) => {
  const f = await fixture(t), flow = await f.start();
  const callbackPath = "/v1/auth/google/callback?state=" + flow.state + "&code=ignored";
  for (const cookie of [undefined, "pm_google_state=" + random()]) {
    assert.equal(errorOf(await f.req("GET", callbackPath, undefined, cookie ? { cookie } : {})), "oauth_failed");
  }
  assert.equal((await f.req("HEAD", callbackPath, undefined, { cookie: flow.cookie })).statusCode, 405);
  assert.equal((await f.req("GET", callbackPath, undefined, { cookie: flow.cookie, origin: "https://attacker.example" })).statusCode, 403);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 1);
  assert.equal(f.google.exchangeCalls.length, 0);
  f.advance(600);
  assert.equal(errorOf(await f.req("GET", callbackPath, undefined, { cookie: flow.cookie })), "oauth_failed");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
  assert.equal((await f.req("GET", "/v1/auth/google/start", undefined, { origin: "https://attacker.example" })).statusCode, 403);
  assert.equal((await f.req("GET", "/v1/auth/google/start", undefined, { "sec-fetch-site": "cross-site" })).statusCode, 403);
  assert.equal((await f.req("GET", "/v1/auth/google/start?redirect=https://attacker.example")).statusCode, 400);
});

test("native return is a short-lived one-use code bound to PKCE, not a token or automatic device approval", async (t) => {
  const f = await fixture(t), owner = f.store.consumeMagic(f.store.magic("owner@gmail.com"));
  const unrelated = f.store.device("Unapproved peer", digest("unrelated-verifier"));
  const grant = await f.nativeGrant({ email: owner.user.email, sub: "owner-sub" });
  assert.equal(grant.returnedState, grant.state);
  assert.match(grant.code, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(grant.location.origin, ORIGIN);
  assert.equal(grant.location.pathname, PREFIX + "/v1/auth/google/start");
  assert.equal(cookieOf(grant.response, "pm_session"), undefined);
  const row = f.store.get("SELECT * FROM google_native_grants");
  assert.equal(row.hash, digest(grant.code));
  assert.notEqual(row.hash, grant.code);
  assert.equal(row.challenge, challenge(grant.verifier));
  assert.equal(row.expires, NOW + 60);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_native_requests").n, 0);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
  assert.equal((await f.req("GET", "/v1/auth/google/native/status")).statusCode, 404);
  const body = { code: grant.code, verifier: grant.verifier, label: "Mac de recette" };
  assert.equal((await f.req("POST", "/v1/auth/google/native/exchange", body, { origin: "https://attacker.example" })).statusCode, 403);
  const wrongVerifier = await f.req("POST", "/v1/auth/google/native/exchange", { ...body, verifier: random() });
  assert.equal(wrongVerifier.statusCode, 401);
  assert.deepEqual(wrongVerifier.json(), { error: "invalid_grant" });
  const malformed = await f.req("POST", "/v1/auth/google/native/exchange", { ...body, code: "bad" });
  assert.equal(malformed.statusCode, 400);
  assert.deepEqual(malformed.json(), { error: "invalid_request" });
  const results = await Promise.all([f.req("POST", "/v1/auth/google/native/exchange", body), f.req("POST", "/v1/auth/google/native/exchange", body)]);
  assert.deepEqual(results.map((r) => r.statusCode).sort(), [200, 401]);
  assert.deepEqual(results.find((r) => r.statusCode === 401).json(), { error: "invalid_grant" });
  const success = results.find((r) => r.statusCode === 200), device = success.json();
  assert.deepEqual(Object.keys(device).sort(), ["deviceID", "expiresIn", "token"]);
  assert.equal(device.expiresIn, 2592000);
  assert.equal(f.store.authenticate(device.token).id, owner.user.id);
  assert.equal(f.store.authenticate(device.token).device_id, device.deviceID);
  assert.equal((await f.req("GET", "/v1/admin/overview", undefined, { authorization: "Bearer " + device.token })).statusCode, 403);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM devices").n, 1);
  assert.equal(f.store.get("SELECT user_id FROM device_requests WHERE code=?", unrelated.userCode).user_id, null);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  assert.ok(f.store.authenticate(owner.session));
});

test("native cancellation and token errors return only the fixed scheme and the original native state", async (t) => {
  for (const error of ["access_denied", "server_error_with_private_detail"]) {
    const f = await fixture(t), native = await f.nativeStart(), flow = await f.start(native.location.search);
    const response = await f.req("GET", "/v1/auth/google/callback?state=" + flow.state + "&error=" + error, undefined, { cookie: flow.cookie });
    const location = new URL(response.headers.location);
    assert.equal(location.origin, "null");
    assert.equal(location.protocol, "playmelt:");
    assert.equal(location.host + location.pathname, "account/google");
    assert.equal(location.searchParams.get("state"), native.state);
    assert.equal(location.searchParams.get("error"), error === "access_denied" ? "oauth_cancelled" : "oauth_failed");
    assert.equal(location.searchParams.get("code"), null);
    assert.equal(cookieOf(response, "pm_session"), undefined);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_native_grants").n, 0);
    assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
    await f.close();
  }
  const f = await fixture(t), native = await f.nativeStart(), flow = await f.start(native.location.search);
  const response = await f.callback(flow, { nonce: random() }), location = new URL(response.headers.location);
  assert.equal(location.searchParams.get("error"), "oauth_failed");
  assert.equal(location.searchParams.get("state"), native.state);
  assert.equal(location.searchParams.get("code"), null);
});

test("native requests and grants expire, foreign origins and arbitrary redirect fields are refused", async (t) => {
  const f = await fixture(t);
  assert.equal((await f.req("POST", "/v1/auth/google/native/start", { challenge: random(), state: random() }, { origin: "https://attacker.example" })).statusCode, 403);
  for (const payload of [
    { challenge: "bad", state: random() }, { challenge: random(), state: "bad" },
    { challenge: random(), state: random(), redirect: "evil://oauth" },
  ]) assert.equal((await f.req("POST", "/v1/auth/google/native/start", payload)).statusCode, 400);
  assert.equal((await f.req("GET", "/v1/auth/google/start?native=" + random())).statusCode, 400);
  const native = await f.nativeStart();
  f.advance(600);
  assert.equal((await f.req("GET", "/v1/auth/google/start" + native.location.search)).statusCode, 400);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_native_requests").n, 0);
  const once = await f.nativeStart();
  await f.start(once.location.search);
  assert.equal((await f.req("GET", "/v1/auth/google/start" + once.location.search)).statusCode, 400);
  const grant = await f.nativeGrant();
  f.advance(60);
  const exchange = await f.req("POST", "/v1/auth/google/native/exchange", { code: grant.code, verifier: grant.verifier });
  assert.equal(exchange.statusCode, 401);
  assert.deepEqual(exchange.json(), { error: "invalid_grant" });
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM devices").n, 0);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM google_native_grants").n, 0);
});

test("simultaneous callbacks deduplicate the stable Google identity and refuse a different subject claiming the same linked mailbox", async (t) => {
  const f = await fixture(t), a = await f.start(), b = await f.start();
  const responses = await Promise.all([f.callback(a), f.callback(b)]);
  assert.ok(responses.every((r) => cookieOf(r, "pm_session")));
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM oauth_identities").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM sessions").n, 2);
  const conflict = await f.callback(await f.start(), { sub: "different-google-subject" });
  assert.equal(errorOf(conflict), "account_link_required");
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM oauth_identities").n, 1);
});

test("an OAuth state and existing owner session survive a real SQLite close/reopen without retaining Google tokens", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-google-auth-")), path = join(dir, "oauth.sqlite");
  let first, second;
  try {
    first = await fixture(t, { path });
    const owner = first.store.consumeMagic(first.store.magic("owner@gmail.com")), flow = await first.start();
    first.store.redeemOwnerCode(first.store.issueOwnerCode(owner.user.email), owner.user);
    await first.close();
    second = await fixture(t, { path });
    const response = await second.callback(flow, { email: owner.user.email });
    assert.ok(cookieOf(response, "pm_session"));
    assert.equal(second.store.authenticate(owner.session).id, owner.user.id);
    assert.equal(second.store.get("SELECT user_id FROM oauth_identities").user_id, owner.user.id);
    assert.equal(second.store.entitlement(owner.user.id).plan, "lifetime");
    const dump = JSON.stringify([
      second.store.all("SELECT * FROM oauth_identities"), second.store.all("SELECT * FROM google_oauth_states"),
      second.store.all("SELECT * FROM google_native_requests"), second.store.all("SELECT * FROM google_native_grants"),
    ]);
    assert.doesNotMatch(dump, /fixture-access-token|fixture-refresh-token|fixture-code/);
    assert.equal(second.store.get("SELECT COUNT(*) AS n FROM google_oauth_states").n, 0);
  } finally {
    await first?.close();
    await second?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("official getToken and verifyIdToken validate signed fixture ID tokens, rejecting bad signature, issuer and audience", async (t) => {
  const keys = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
  for (const mutation of ["valid", "signature", "issuer", "audience", "expired"]) {
    const google = new OAuth2Client({ clientId: ID, clientSecret: SECRET, redirectUri: BASE + "/v1/auth/google/callback" });
    const f = await fixture(t, { google }), flow = await f.start();
    const payload = f.claims(flow, mutation === "issuer" ? { iss: "https://attacker.example" }
      : mutation === "audience" ? { aud: "wrong-client" }
      : mutation === "expired" ? { iat: NOW - 3600, exp: NOW - 600 } : {});
    const content = Buffer.from(JSON.stringify({ alg: "RS256", kid: "fixture-key" })).toString("base64url") + "." + Buffer.from(JSON.stringify(payload)).toString("base64url");
    const jwt = content + "." + sign("RSA-SHA256", Buffer.from(content), mutation === "signature" ? other.privateKey : keys.privateKey).toString("base64url");
    let exchange;
    google.transporter.request = async (options) => {
      exchange = options;
      return { data: { id_token: jwt, access_token: "fixture-private-access-token", expires_in: 3600 }, headers: new Headers(), config: options };
    };
    google.getFederatedSignonCertsAsync = async () => ({ certs: { "fixture-key": keys.publicKey.export({ type: "spki", format: "pem" }) } });
    const response = await f.req("GET", "/v1/auth/google/callback?state=" + flow.state + "&code=official-code", undefined, { cookie: flow.cookie });
    assert.equal(exchange.url, "https://oauth2.googleapis.com/token");
    assert.equal(challenge(exchange.data.get("code_verifier")), flow.authorization.searchParams.get("code_challenge"));
    if (mutation === "valid") {
      assert.ok(cookieOf(response, "pm_session"));
      assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
    } else {
      assert.equal(errorOf(response), "oauth_failed", mutation);
      assert.equal(cookieOf(response, "pm_session"), undefined);
      assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
    }
    await f.close();
  }
});
