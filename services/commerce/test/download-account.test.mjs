import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import { Store, digest, token } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

const keys = generateKeyPairSync("ed25519");
async function fixture(t, change = () => {}) {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-private-download-"));
  const privateRoot = join(dir, "private"), documentRoot = join(dir, "public");
  mkdirSync(privateRoot, { mode: 0o700 });
  mkdirSync(documentRoot, { mode: 0o700 });
  const bytes = Buffer.from("private DMG fixture\0\x01streamed intact");
  const file = join(privateRoot, "Playmelt-2.1.0.dmg");
  writeFileSync(file, bytes, { mode: 0o600 });
  let now = 1900000000, delivery = "accepted", app;
  const store = new Store(":memory:", () => now), mail = [];
  t.after(async () => {
    try { if (app) await app.close(); else store.close(); }
    finally { rmSync(dir, { recursive: true, force: true }); }
  });
  const config = {
    testing: true, publicURL: "https://example.test/account", prices: {},
    signingKey: keys.privateKey, mailFrom: "Playmelt <contact@7agency.fr>",
    privateRoot, documentRoot, downloadFile: file, downloadVersion: "2.1.0",
    downloadFilename: "Playmelt-2.1.0.dmg", downloadSHA256: digest(bytes), downloadSize: bytes.length,
  };
  change(config, { dir, file, bytes });
  app = await createApp({ store, stripe: {}, config, mailer: {
    sendMail: async (value) => {
      mail.push(value);
      if (delivery === "throw") throw Error("fixture SMTP unavailable");
      return { accepted: delivery === "accepted" ? [value.to.address] : [], rejected: delivery === "rejected" ? [value.to.address] : [] };
    },
  } });
  const user = (email = "buyer@example.test") => store.consumeMagic(store.magic(email));
  const req = (u, method, path, payload, extra = {}) => app.inject({
    method, url: "/account" + path, payload,
    headers: Object.fromEntries(Object.entries({ origin: "https://example.test", ...(u ? { cookie: "pm_session=" + u.session } : {}), ...extra }).filter(([, value]) => value !== undefined)),
  });
  const mailToken = () => mail.at(-1).text.match(/#download=([\w-]+)/)[1];
  const transferCookie = (response) => response.headers["set-cookie"].match(/pm_download=([^;]+)/)[1];
  const download = (u, transfer, method = "GET", path = "/v1/download") => req(u, method, path, undefined, { cookie: `pm_session=${u.session}; pm_download=${transfer}` });
  return { app, store, config, mail, req, user, mailToken, transferCookie, download, file, bytes,
    advance: (seconds) => (now += seconds), delivery: (value) => (delivery = value) };
}

test("anonymous and device callers cannot request download mail, claim tokens or download", async (t) => {
  const f = await fixture(t), u = f.user(), proof = token();
  for (const [method, path, payload] of [["POST", "/v1/download/email", {}], ["POST", "/v1/download/claim", { token: token() }], ["GET", "/v1/download"], ["HEAD", "/v1/download"]]) {
    const r = await f.req(null, method, path, payload);
    assert.equal(r.statusCode, 401);
    assert.equal(r.headers.location, undefined);
    assert.equal(r.headers["cache-control"], "no-store");
  }
  const device = f.store.device("fixture Mac", digest(proof));
  f.store.approveDevice(device.userCode, u.user.id);
  const paired = f.store.exchangeDevice(device.deviceCode, proof);
  assert.equal((await f.req(null, "POST", "/v1/download/email", {}, { authorization: "Bearer " + paired.token })).statusCode, 403);
  assert.equal((await f.req(null, "POST", "/v1/download/email", {}, { cookie: "pm_session=" + paired.token })).statusCode, 403);
  assert.equal((await f.req(null, "POST", "/v1/download/email", {}, { authorization: "Bearer " + u.session })).statusCode, 403);
  assert.equal(f.mail.length, 0);
});

test("download intent survives verification, creates a free account then sends one single-recipient download mail", async (t) => {
  const f = await fixture(t);
  const request = await f.req(null, "POST", "/v1/auth/email", { email: " Buyer+tag@Example.test ", intent: "download", source: "app", returnTo: "https://evil.test/" });
  assert.equal(request.statusCode, 200);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
  assert.equal(f.mail.length, 1);
  assert.match(f.mail[0].text, /\/confirm\?intent=download&source=app#token=/);
  assert.doesNotMatch(f.mail[0].text, /evil\.test/);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM download_links").n, 0);
  const magic = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  const confirm = await f.req(null, "POST", "/v1/auth/confirm", { token: magic, intent: "https://evil.test/" });
  assert.equal(confirm.statusCode, 200);
  assert.deepEqual(confirm.json(), { signedIn: true, intent: "download", download: { emailAccepted: true } });
  assert.match(confirm.headers["set-cookie"], /HttpOnly/);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 1);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM entitlements").n, 0);
  assert.equal(f.mail.length, 2);
  assert.deepEqual(f.mail[1].to, { address: "buyer+tag@example.test" });
  assert.equal(f.mail[1].from, "Playmelt <contact@7agency.fr>");
  assert.equal(f.mail[1].cc, undefined);
  assert.equal(f.mail[1].bcc, undefined);
  assert.match(f.mail[1].text, /https:\/\/example\.test\/account\/#download=/);
  assert.doesNotMatch(f.mail[1].text, /https:\/\/[^\s]+\.dmg/);
  const row = f.store.get("SELECT * FROM download_links");
  assert.equal(row.hash, digest(f.mailToken()));
  assert.equal(row.artifact, f.config.downloadSHA256);
  assert.equal(row.source, "app");
  assert.equal(row.delivery, "smtp_accepted");
  assert.equal((await f.req(null, "POST", "/v1/auth/confirm", { token: magic })).statusCode, 400);
  assert.equal(f.mail.length, 2);
  assert.equal(f.store.get("SELECT SUM(count) AS n FROM activity_daily WHERE kind='download'").n, null);
});

test("ordinary sign-in never triggers a download mail and arbitrary intent is rejected", async (t) => {
  const f = await fixture(t);
  assert.equal((await f.req(null, "POST", "/v1/auth/email", { email: "buyer@example.test", intent: "https://evil.test" })).statusCode, 400);
  await f.req(null, "POST", "/v1/auth/email", { email: "buyer@example.test" });
  const magic = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  assert.deepEqual((await f.req(null, "POST", "/v1/auth/confirm", { token: magic })).json(), { signedIn: true });
  assert.equal(f.mail.length, 1);
});

test("a verified account streams exactly the private artifact once, without a public redirect; only the GET counts", async (t) => {
  const f = await fixture(t), u = f.user();
  assert.equal((await f.req(u, "POST", "/v1/download/email", { source: "site" })).statusCode, 200);
  const claim = await f.req(u, "POST", "/v1/download/claim", { token: f.mailToken() });
  assert.deepEqual(claim.json(), { ready: true });
  assert.match(claim.headers["set-cookie"], /HttpOnly/);
  assert.match(claim.headers["set-cookie"], /SameSite=Strict/i);
  assert.match(claim.headers["set-cookie"], /Max-Age=60/);
  assert.match(claim.headers["set-cookie"], /Path=\/account\/v1\/download/);
  const transfer = f.transferCookie(claim);
  assert.equal((await f.download(u, transfer, "HEAD")).statusCode, 405);
  assert.equal(f.store.get("SELECT SUM(count) AS n FROM activity_daily WHERE kind='download'").n, null);
  const r = await f.download(u, transfer);
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.rawPayload, f.bytes);
  assert.equal(r.headers.location, undefined);
  assert.equal(r.headers["content-type"], "application/x-apple-diskimage");
  assert.equal(r.headers["content-disposition"], 'attachment; filename="Playmelt-2.1.0.dmg"');
  assert.equal(r.headers["cache-control"], "no-store");
  assert.equal(r.headers["referrer-policy"], "no-referrer");
  assert.equal(Number(r.headers["content-length"]), f.bytes.length);
  assert.equal(f.store.get("SELECT count FROM activity_daily WHERE kind='download' AND source='site'").count, 1);
  assert.equal((await f.download(u, transfer)).statusCode, 400);
  assert.equal((await f.req(u, "POST", "/v1/download/claim", { token: f.mailToken() })).statusCode, 400);
});

test("a mail link, transfer cookie and session cannot cross accounts or sessions", async (t) => {
  const f = await fixture(t), one = f.user(), other = f.user("other@example.test");
  await f.req(one, "POST", "/v1/download/email", {});
  const value = f.mailToken();
  assert.equal((await f.req(other, "POST", "/v1/download/claim", { token: value })).statusCode, 400);
  const claim = await f.req(one, "POST", "/v1/download/claim", { token: value });
  const transfer = f.transferCookie(claim);
  assert.equal((await f.download(other, transfer)).statusCode, 400);
  const otherSession = { ...one, session: f.store.session(one.user.id) };
  assert.equal((await f.download(otherSession, transfer)).statusCode, 400);
  assert.equal((await f.download(one, transfer)).statusCode, 200);
});

test("both mailed links and transfer grants expire", async (t) => {
  const f = await fixture(t), one = f.user(), other = f.user("other@example.test");
  await f.req(one, "POST", "/v1/download/email", {});
  const expired = f.mailToken();
  f.advance(901);
  assert.equal((await f.req(one, "POST", "/v1/download/claim", { token: expired })).statusCode, 400);
  await f.req(other, "POST", "/v1/download/email", {});
  const claim = await f.req(other, "POST", "/v1/download/claim", { token: f.mailToken() });
  f.advance(61);
  assert.equal((await f.download(other, f.transferCookie(claim))).statusCode, 400);
});

test("mail and claim POSTs require same-origin cookies; recipients and paths cannot be supplied", async (t) => {
  const f = await fixture(t), u = f.user();
  for (const origin of ["https://evil.test", undefined]) {
    assert.equal((await f.req(u, "POST", "/v1/download/email", {}, { origin })).statusCode, 403);
    assert.equal((await f.req(u, "POST", "/v1/download/claim", { token: token() }, { origin })).statusCode, 403);
  }
  for (const payload of [{ email: "other@example.test" }, { source: "../secret" }, { path: "/etc/passwd" }, { url: "https://evil.test/a.dmg" }])
    assert.equal((await f.req(u, "POST", "/v1/download/email", payload)).statusCode, 400);
  await f.req(u, "POST", "/v1/download/email", {});
  const value = f.mailToken();
  assert.equal((await f.req(u, "POST", "/v1/download/claim", { token: value, filename: "../../secret" })).statusCode, 400);
  const claim = await f.req(u, "POST", "/v1/download/claim", { token: value });
  const transfer = f.transferCookie(claim);
  assert.equal((await f.download(u, transfer, "GET", "/v1/download?path=../../etc/passwd")).statusCode, 400);
  assert.equal((await f.download(u, transfer)).statusCode, 200);
});

test("SMTP failures invalidate tokens, allow explicit bounded retry and never claim delivery", async (t) => {
  const f = await fixture(t), u = f.user();
  f.delivery("throw");
  const failed = await f.req(u, "POST", "/v1/download/email", {});
  assert.equal(failed.statusCode, 503);
  assert.deepEqual(failed.json(), { error: "download_email_unavailable" });
  const invalid = f.mailToken();
  assert.equal((await f.req(u, "POST", "/v1/download/claim", { token: invalid })).statusCode, 400);
  f.delivery("rejected");
  assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 503);
  f.delivery("accepted");
  assert.deepEqual((await f.req(u, "POST", "/v1/download/email", {})).json(), { emailAccepted: true });
  assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 429);
  assert.equal(f.mail.length, 3);
  assert.deepEqual(f.store.all("SELECT delivery FROM download_links").map((r) => r.delivery), ["failed", "failed", "smtp_accepted"]);
});

test("a failed download mail after verification preserves the account and offers an explicit retry", async (t) => {
  const f = await fixture(t);
  await f.req(null, "POST", "/v1/auth/email", { email: "buyer@example.test", intent: "download" });
  const magic = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  f.delivery("throw");
  const confirm = await f.req(null, "POST", "/v1/auth/confirm", { token: magic });
  assert.equal(confirm.statusCode, 200);
  assert.deepEqual(confirm.json(), { signedIn: true, intent: "download", download: { error: "download_email_unavailable" } });
  const session = confirm.headers["set-cookie"].match(/pm_session=([^;]+)/)[1];
  const u = { session };
  assert.equal((await f.req(u, "GET", "/v1/me")).json().email, "buyer@example.test");
  f.delivery("accepted");
  assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 200);
});

test("failed authentication sends invalidate their token and a subsequent explicit request can retry", async (t) => {
  const f = await fixture(t);
  f.delivery("throw");
  assert.equal((await f.req(null, "POST", "/v1/auth/email", { email: "buyer@example.test", intent: "download" })).statusCode, 503);
  const failed = f.mail[0].text.match(/#token=([\w-]+)/)[1];
  assert.equal((await f.req(null, "POST", "/v1/auth/confirm", { token: failed })).statusCode, 400);
  assert.equal(f.store.get("SELECT COUNT(*) AS n FROM users").n, 0);
  f.delivery("accepted");
  const retry = await f.req(null, "POST", "/v1/auth/email", { email: "buyer@example.test", intent: "download" });
  assert.equal(retry.statusCode, 200);
  assert.deepEqual(retry.json(), { requested: true });
  const good = f.mail.at(-1).text.match(/#token=([\w-]+)/)[1];
  assert.equal((await f.req(null, "POST", "/v1/auth/confirm", { token: good })).json().download.emailAccepted, true);
});

test("mail cooldown prevents accidental duplicate requests, with a bounded hourly cap", async (t) => {
  const f = await fixture(t), u = f.user();
  for (let i = 0; i < 3; i++) {
    assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 200);
    assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 429);
    f.advance(61);
  }
  assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 429);
  assert.equal(f.mail.length, 3);
});

test("missing artifact config disables downloading without breaking account or device APIs", async (t) => {
  const f = await fixture(t, (config) => { config.downloadFile = ""; }), u = f.user();
  assert.deepEqual((await f.req(null, "GET", "/v1/download/status")).json(), { available: false });
  assert.equal((await f.req(u, "GET", "/v1/me")).statusCode, 200);
  assert.equal((await f.req(u, "POST", "/v1/download/email", {})).statusCode, 503);
  assert.equal(f.mail.length, 0);
});

test("startup rejects wrong SHA, size, public paths, symbolic links and unapproved releases", async (t) => {
  const cases = [
    (c) => { c.downloadSHA256 = "0".repeat(64); },
    (c) => { c.downloadSize++; },
    (c) => { c.downloadVersion = "2.3.0"; c.downloadFilename = "Playmelt-2.3.0.dmg"; },
    (c) => { c.downloadFilename = "../../secret.dmg"; },
    (c) => { chmodSync(c.downloadFile, 0o644); },
    (c) => { const target = join(c.documentRoot, c.downloadFilename); writeFileSync(target, "public", { mode: 0o600 }); c.downloadFile = target; },
    (c) => { const target = join(c.privateRoot, "link.dmg"); symlinkSync(c.downloadFile, target); c.downloadFile = target; },
  ];
  for (const change of cases) await t.test(async (child) => { await assert.rejects(fixture(child, change)); });
});

test("replacement or mutation after startup cannot stream bytes from a different artifact", async (t) => {
  const f = await fixture(t), u = f.user();
  await f.req(u, "POST", "/v1/download/email", {});
  const claim = await f.req(u, "POST", "/v1/download/claim", { token: f.mailToken() });
  writeFileSync(f.file, Buffer.alloc(f.bytes.length, 1));
  const result = await f.download(u, f.transferCookie(claim));
  assert.equal(result.statusCode, 503);
  assert.equal(result.json().error, "download_unavailable");
  assert.equal(f.store.get("SELECT used FROM download_links").used, null);
  assert.equal(f.store.get("SELECT SUM(count) AS n FROM activity_daily WHERE kind='download'").n, null);
});

test("additive migration preserves a pre-existing magic link and intent is not inferred from confirmation input", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-magic-migration-")), path = join(dir, "account.sqlite"), value = token();
  let store;
  try {
    const old = new DatabaseSync(path);
    old.exec("CREATE TABLE magic_links(hash TEXT PRIMARY KEY,email TEXT NOT NULL,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0)");
    old.prepare("INSERT INTO magic_links(hash,email,expires) VALUES(?,?,?)").run(digest(value), "existing@example.test", 2000000000);
    old.close();
    store = new Store(path, () => 1900000000);
    const result = store.consumeMagic(value);
    assert.equal(result.user.email, "existing@example.test");
    assert.equal(result.intent, "");
    assert.equal(result.source, "site");
    assert.equal(store.consumeMagic(value), null);
  } finally {
    if (store) store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("download link hashes, session binding and one-use consumption persist across real SQLite reopen", () => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-download-persistence-")), path = join(dir, "account.sqlite");
  let store;
  try {
    store = new Store(path, () => 1900000000);
    const u = store.consumeMagic(store.magic("persistent@example.test"));
    const artifact = digest("approved artifact"), value = store.downloadLink(u.user.id, artifact, "app");
    store.downloadDelivery(value, true);
    store.close();
    store = null;
    store = new Store(path, () => 1900000010);
    const transfer = store.claimDownload(value, u.user.id, artifact, u.session);
    assert.equal(typeof transfer, "string");
    assert.equal(store.get("SELECT hash FROM download_links").hash, digest(value));
    assert.equal(store.get("SELECT transfer_hash FROM download_links").transfer_hash, digest(transfer));
    assert.equal(store.claimDownload(value, u.user.id, artifact, u.session), null);
    store.close();
    store = null;
    store = new Store(path, () => 1900000020);
    assert.equal(store.consumeDownload(transfer, u.user.id, artifact, u.session).source, "app");
    store.close();
    store = null;
    store = new Store(path, () => 1900000030);
    assert.equal(store.consumeDownload(transfer, u.user.id, artifact, u.session), null);
  } finally {
    if (store) store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
