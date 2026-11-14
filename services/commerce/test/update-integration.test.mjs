import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

const keys = generateKeyPairSync("ed25519");
const sparklePublicKey = Buffer.alloc(32, 17).toString("base64");
// These small files exercise delivery and persistence, not Sparkle archive
// authenticity. Real SDK archive verification is a separate packaging gate.
async function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), "playmelt-update-integration-"));
  const privateRoot = join(directory, "private"), documentRoot = join(directory, "web");
  for (const path of [privateRoot, documentRoot]) mkdirSync(path, { mode: 0o700 });
  const database = join(privateRoot, "account.sqlite"), apps = new Set();
  t.after(async () => {
    try { for (const app of apps) await app.close(); }
    finally { rmSync(directory, { recursive: true, force: true }); }
  });
  const initial = Buffer.from("immutable initial email-download fixture");
  const downloadFile = join(privateRoot, "Playmelt-2.2.0.dmg");
  writeFileSync(downloadFile, initial, { mode: 0o600 });
  const config = {
    testing: true, publicURL: "https://example.test/account", billingEnabled: false,
    prices: {}, privateRoot, documentRoot, downloadFile, downloadVersion: "2.2.0",
    downloadFilename: "Playmelt-2.2.0.dmg", downloadSHA256: digest(initial),
    downloadSize: initial.length, signingKey: keys.privateKey, mailFrom: "Playmelt <contact@7agency.fr>",
  };
  function update(build = "29", extra = {}) {
    const data = Buffer.from("update fixture build " + build);
    const filename = "Playmelt-2.2.0.zip", archiveDirectory = join(privateRoot, "build-" + build);
    mkdirSync(archiveDirectory, { mode: 0o700, recursive: true });
    const archiveFile = join(archiveDirectory, filename);
    writeFileSync(archiveFile, data, { mode: 0o600 });
    const release = {
      version: "2.2.0", build, filename, bytes: data.length, sha256: digest(data),
      edSignature: Buffer.alloc(64, 19).toString("base64"),
      publishedAt: "2026-11-13T12:00:00Z", minimumSystemVersion: "15.0", ...extra,
    };
    const updateManifestFile = join(privateRoot, "updates-" + build + ".json");
    writeFileSync(updateManifestFile, JSON.stringify({ release, sparklePublicKey, archiveFile }), { mode: 0o600 });
    return { config: { ...config, updateManifestFile }, release, data, archiveFile, updateManifestFile };
  }
  async function start(settings = config) {
    const store = new Store(database);
    try {
      const app = await createApp({ store, config: settings, stripe: {}, mailer: { sendMail: async () => ({ accepted: [] }) } });
      apps.add(app);
      return { app, store, close: async () => { await app.close(); apps.delete(app); } };
    } catch (error) { try { store.close(); } catch {} throw error; }
  }
  function pair(store) {
    const login = store.consumeMagic(store.magic("client@example.test"));
    const verifier = "v".repeat(43), request = store.device("Fixture Mac", digest(verifier));
    assert.equal(store.approveDevice(request.userCode, login.user.id), true);
    return { ...store.exchangeDevice(request.deviceCode, verifier), user: login.user, browserToken: login.session };
  }
  const req = (app, token, method, path, payload) => app.inject({ method, url: "/account" + path,
    headers: { ...(token ? { authorization: "Bearer " + token } : {}) }, ...(payload === undefined ? {} : { payload }) });
  return { privateRoot, config, start, update, pair, req };
}

test("updates are unavailable without a manifest and do not open a public archive", async (t) => {
  const f = await fixture(t), s = await f.start();
  assert.equal((await f.req(s.app, null, "POST", "/v1/updates/ticket", {})).statusCode, 503);
  assert.equal((await f.req(s.app, null, "GET", "/v1/updates/appcast.xml")).statusCode, 503);
  assert.equal(s.store.get("SELECT key FROM service_state WHERE key=?", "update_release:primary:stable"), undefined);
});

test("real device sessions can update without gaining a launch entitlement; logout invalidates the grant", async (t) => {
  const f = await fixture(t), u = f.update(), s = await f.start(u.config), device = f.pair(s.store);
  assert.equal(s.store.entitlement(device.user.id), null);
  assert.equal((await f.req(s.app, device.browserToken, "POST", "/v1/updates/ticket", {})).statusCode, 401);
  const response = await f.req(s.app, device.token, "POST", "/v1/updates/ticket", {});
  assert.equal(response.statusCode, 200);
  const grant = response.json();
  assert.equal(grant.feedURL, "https://example.test/account/v1/updates/appcast.xml");
  assert.ok(grant.expiresAt > s.store.now() && grant.expiresAt <= s.store.now() + 600);
  const feed = await f.req(s.app, grant.token, "GET", "/v1/updates/appcast.xml");
  assert.equal(feed.statusCode, 200);
  assert.doesNotMatch(feed.body, /<sparkle:channel>|client@example|access_token|Bearer/);
  const archive = "/v1/updates/archive/29/" + u.release.sha256 + "/" + u.release.filename;
  assert.equal((await f.req(s.app, null, "GET", archive)).statusCode, 401);
  const bytes = await f.req(s.app, grant.token, "GET", archive);
  assert.equal(bytes.statusCode, 200);
  assert.deepEqual(bytes.rawPayload, u.data);
  assert.equal((await f.req(s.app, grant.token, "POST", "/v1/launch-ticket", {})).statusCode, 401);
  assert.equal((await f.req(s.app, device.token, "POST", "/v1/launch-ticket", {})).statusCode, 402);
  assert.equal((await f.req(s.app, device.token, "POST", "/v1/auth/logout", {})).statusCode, 200);
  assert.equal((await f.req(s.app, grant.token, "GET", "/v1/updates/appcast.xml")).statusCode, 403);
});

test("update pin survives SQLite reopen and retires old workers without replacing the initial download", async (t) => {
  const f = await fixture(t), u29 = f.update(), s29 = await f.start(u29.config), d = f.pair(s29.store);
  const originalDownload = s29.store.get("SELECT value FROM service_state WHERE key=?", "download_release:primary").value;
  const grant29 = (await f.req(s29.app, d.token, "POST", "/v1/updates/ticket", {})).json().token;
  const u30 = f.update("30"), s30 = await f.start(u30.config);
  assert.equal(s30.store.get("SELECT value FROM service_state WHERE key=?", "download_release:primary").value, originalDownload);
  assert.equal(JSON.parse(s30.store.get("SELECT value FROM service_state WHERE key=?", "update_release:primary:stable").value).build, "30");
  assert.equal((await f.req(s29.app, grant29, "GET", "/v1/updates/appcast.xml")).statusCode, 503);
  await s29.close(); await s30.close();
  await assert.rejects(f.start(u29.config), /downgrade/);
  const reopened = await f.start(u30.config);
  assert.equal((await f.req(reopened.app, d.token, "POST", "/v1/updates/ticket", {})).statusCode, 200);
});

test("bad manifests and initial-download floor failures cannot advance the update floor", async (t) => {
  const f = await fixture(t), u29 = f.update(), s = await f.start(u29.config);
  const before = s.store.get("SELECT value FROM service_state WHERE key=?", "update_release:primary:stable").value;
  await s.close();
  const bad = f.update("30");
  await assert.rejects(f.start({ ...bad.config, downloadSHA256: "f".repeat(64) }), /verified manifest/);
  const changedInitial = Buffer.from("different initial download, same unapproved version");
  writeFileSync(bad.config.downloadFile, changedInitial, { mode: 0o600 });
  await assert.rejects(f.start({ ...bad.config, downloadSHA256: digest(changedInitial), downloadSize: changedInitial.length }), /separately approved release/);
  const reader = new Store(join(f.privateRoot, "account.sqlite"));
  try { assert.equal(reader.get("SELECT value FROM service_state WHERE key=?", "update_release:primary:stable").value, before); }
  finally { reader.close(); }
  const linked = join(f.privateRoot, "linked-manifest.json");
  symlinkSync(bad.updateManifestFile, linked);
  await assert.rejects(f.start({ ...bad.config, downloadSHA256: digest(changedInitial),
    downloadSize: changedInitial.length, updateManifestFile: linked }), /private download path/);
});
