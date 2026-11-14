import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, renameSync, symlinkSync, linkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Store, digest } from "../src/store.mjs";
import { createApp } from "../src/app.mjs";

const keys = generateKeyPairSync("ed25519");
async function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-release-policy-"));
  const privateRoot = join(dir, "private"), documentRoot = join(dir, "web"), outside = join(dir, "outside");
  for (const path of [privateRoot, documentRoot, outside]) mkdirSync(path, { mode: 0o700 });
  const db = join(privateRoot, "account.sqlite"), active = new Set(), opened = new Set();
  t.after(async () => {
    try {
      for (const app of active) await app.close();
      for (const store of opened) store.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  function config(version, overrides = {}) {
    const bytes = Buffer.from("local test package " + version), filename = "Playmelt-" + version + ".dmg";
    const downloadFile = join(privateRoot, filename);
    writeFileSync(downloadFile, bytes, { mode: 0o600 });
    return {
      testing: true, publicURL: "https://example.test/account", prices: {}, billingEnabled: false,
      privateRoot, documentRoot, downloadFile, downloadVersion: version, downloadFilename: filename,
      downloadSHA256: digest(bytes), downloadSize: bytes.length, signingKey: keys.privateKey,
      mailFrom: "Playmelt <contact@7agency.fr>", ...overrides,
    };
  }
  async function start(config) {
    const store = new Store(db); opened.add(store);
    const mail = [];
    try {
      const app = await createApp({ store, config, stripe: {}, mailer: { sendMail: async (message) => {
        mail.push(message); return { accepted: [message.to.address] };
      } } });
      opened.delete(store); active.add(app);
      const close = async () => { await app.close(); active.delete(app); };
      const user = (email = "buyer@example.test") => store.consumeMagic(store.magic(email));
      const req = (user, method, path, payload, cookie) => app.inject({ method, url: "/account" + path, payload,
        headers: { origin: "https://example.test", ...(user ? { cookie: "pm_session=" + user.session + (cookie ? "; pm_download=" + cookie : "") } : {}) } });
      const link = () => mail.at(-1).text.match(/#download=([\w-]+)/)[1];
      const claim = async (user) => {
        const response = await req(user, "POST", "/v1/download/claim", { token: link() });
        assert.equal(response.statusCode, 200);
        return response.headers["set-cookie"].match(/pm_download=([^;]+)/)[1];
      };
      return { app, store, config, mail, user, req, link, claim, close };
    } catch (error) { opened.delete(store); store.close(); throw error; }
  }
  return { dir, privateRoot, documentRoot, outside, db, config, start };
}

test("commercial 2.2 is streamed privately after verified-account mail, with no entitlement or public fallback", async (t) => {
  const f = await fixture(t), config = f.config("2.2.0", { billingEnabled: true });
  const s = await f.start(config), buyer = s.user(), other = s.user("other@example.test");
  assert.equal((await s.req(null, "GET", "/v1/download")).statusCode, 401);
  assert.deepEqual((await s.req(null, "GET", "/v1/download/status")).json(), { available: true, version: "2.2.0" });
  assert.equal((await s.req(buyer, "POST", "/v1/download/email", { source: "app" })).statusCode, 200);
  assert.equal(s.mail.length, 1);
  assert.deepEqual(s.mail[0].to, { address: buyer.user.email });
  assert.match(s.mail[0].text, /Playmelt 2\.2\.0/);
  assert.doesNotMatch(s.mail[0].text, /https?:\/\/[^\s]+\.dmg/);
  assert.equal(s.store.entitlement(buyer.user.id), null);
  assert.equal((await s.req(other, "POST", "/v1/download/claim", { token: s.link() })).statusCode, 400);
  const ticket = await s.claim(buyer);
  const streamed = await s.req(buyer, "GET", "/v1/download", undefined, ticket);
  assert.equal(streamed.statusCode, 200);
  assert.equal(streamed.headers.location, undefined);
  assert.equal(streamed.headers["cache-control"], "no-store");
  assert.equal(streamed.headers["content-disposition"], 'attachment; filename="Playmelt-2.2.0.dmg"');
  assert.equal(digest(streamed.rawPayload), config.downloadSHA256);
  assert.equal((await s.req(buyer, "GET", "/v1/download", undefined, ticket)).statusCode, 400);
});

test("commercial billing refuses legacy 2.1 even in test mode", async (t) => {
  const f = await fixture(t);
  await assert.rejects(f.start(f.config("2.1.0", { billingEnabled: true })), /Commercial billing requires/);
  const legacy = await f.start(f.config("2.1.0"));
  assert.equal((await legacy.req(null, "GET", "/v1/download/status")).json().available, true);
});

test("non-test commercial services cannot open with no private package, including primary Stripe test mode", async (t) => {
  const f = await fixture(t);
  for (const extra of [
    { live: true }, { live: false }, {},
    { live: true, testAccountEmail: "isolated@example.test" },
    { live: false, testAccountEmail: "not-a-mailbox" },
    { live: false, testAccountEmail: "UPPER@example.test" },
    { live: false, testing: "true" },
  ]) await assert.rejects(f.start(f.config("2.2.0", { billingEnabled: true, testing: false, downloadFile: "", ...extra })), /configured private client package/);
});

test("explicit isolated sandbox and billing-disabled owner access may run without an artifact", async (t) => {
  const f = await fixture(t);
  const sandbox = await f.start(f.config("2.2.0", {
    billingEnabled: true, testing: false, downloadFile: "", live: false,
    testAccountEmail: "isolated@example.test",
  }));
  assert.deepEqual((await sandbox.req(null, "GET", "/v1/download/status")).json(), { available: false });
  assert.equal((await sandbox.req(null, "GET", "/v1/billing/status")).json().enabled, true);
  await sandbox.close();
  const owner = await f.start(f.config("2.2.0", { billingEnabled: false, testing: false, downloadFile: "", live: true }));
  const user = owner.user("owner@example.test");
  assert.equal((await owner.req(user, "GET", "/v1/me")).json().email, user.user.email);
  assert.equal((await owner.req(null, "GET", "/v1/billing/status")).json().enabled, false);
});

test("a production-mode service accepts an exact private 2.2 tuple without a testing bypass", async (t) => {
  const f = await fixture(t), service = await f.start(f.config("2.2.0", { billingEnabled: true, testing: false, live: true }));
  assert.deepEqual((await service.req(null, "GET", "/v1/download/status")).json(), { available: true, version: "2.2.0" });
});

test("a candidate that fails legal or account setup does not retire the working legacy distribution", async (t) => {
  const f = await fixture(t), current = await f.start(f.config("2.1.0"));
  const candidate = f.config("2.2.0");
  await assert.rejects(f.start({ ...candidate, termsHTML: "invalid retained terms", termsSHA256: "0".repeat(64) }), /Terms document/);
  await assert.rejects(f.start({ ...candidate, publicURL: candidate.publicURL + "#invalid" }), /Invalid public URL/);
  assert.deepEqual((await current.req(null, "GET", "/v1/download/status")).json(), { available: true, version: "2.1.0" });
});

test("release floor and exact hash survive SQLite close/reopen; disabling billing cannot silently downgrade", async (t) => {
  const f = await fixture(t), legacy = await f.start(f.config("2.1.0"));
  const buyer = legacy.user();
  const session = buyer.session;
  await legacy.close();
  const commercialConfig = f.config("2.2.0", { billingEnabled: true });
  const commercial = await f.start(commercialConfig);
  assert.equal(commercial.store.authenticate(session).email, buyer.user.email);
  await commercial.close();
  await assert.rejects(f.start(f.config("2.1.0")), /downgrade refused/);
  const same = await f.start({ ...commercialConfig, billingEnabled: false });
  assert.equal((await same.req(null, "GET", "/v1/download/status")).json().version, "2.2.0");
  await same.close();
  const replacement = Buffer.from("different same-version test package");
  writeFileSync(commercialConfig.downloadFile, replacement, { mode: 0o600 });
  await assert.rejects(f.start({ ...commercialConfig, downloadSHA256: digest(replacement), downloadSize: replacement.length }), /replacement requires/);
});

test("promotion invalidates old 2.1 workers, mailed links and already-claimed transfers without touching public files", async (t) => {
  const f = await fixture(t), old = await f.start(f.config("2.1.0"));
  const buyer = old.user();
  await old.req(buyer, "POST", "/v1/download/email", {});
  const oldMail = old.link(), oldTransfer = await old.claim(buyer);
  const commercial = await f.start(f.config("2.2.0", { billingEnabled: true }));
  assert.deepEqual((await old.req(null, "GET", "/v1/download/status")).json(), { available: false });
  assert.equal((await old.req(buyer, "POST", "/v1/download/email", {})).statusCode, 503);
  assert.equal((await old.req(buyer, "POST", "/v1/download/claim", { token: oldMail })).statusCode, 503);
  assert.equal((await old.req(buyer, "GET", "/v1/download", undefined, oldTransfer)).statusCode, 503);
  assert.equal((await commercial.req(buyer, "POST", "/v1/download/claim", { token: oldMail })).statusCode, 400);
  assert.equal(old.mail.length, 1);
});

test("an explicitly isolated test service cannot promote production's pin or mail another account", async (t) => {
  const f = await fixture(t), primary = await f.start(f.config("2.1.0"));
  const buyer = primary.user(), testUser = primary.user("isolated@example.test");
  const isolated = await f.start(f.config("2.2.0", { billingEnabled: true, testAccountEmail: testUser.user.email }));
  assert.equal((await primary.req(null, "GET", "/v1/download/status")).json().version, "2.1.0");
  for (const [method, path, body] of [["POST", "/v1/download/email", {}], ["POST", "/v1/download/claim", { token: "a".repeat(43) }], ["GET", "/v1/download"]])
    assert.equal((await isolated.req(buyer, method, path, body)).statusCode, 403);
  assert.equal(isolated.mail.length, 0);
  assert.equal((await isolated.req(testUser, "POST", "/v1/download/email", {})).statusCode, 200);
  assert.deepEqual(isolated.mail[0].to, { address: testUser.user.email });
  await isolated.close();
  await primary.close();
  const stillLegacy = await f.start(f.config("2.1.0"));
  assert.equal((await stillLegacy.req(null, "GET", "/v1/download/status")).json().version, "2.1.0");
});

test("private artifact rejects outside paths, parent symlinks and hardlinks before any mail is possible", async (t) => {
  const f = await fixture(t), config = f.config("2.2.0");
  const outsideFile = join(f.outside, config.downloadFilename);
  writeFileSync(outsideFile, Buffer.from("outside package"), { mode: 0o600 });
  await assert.rejects(f.start({ ...config, downloadFile: outsideFile }), /escapes private storage/);
  const parent = join(f.privateRoot, "alias"); symlinkSync(f.outside, parent);
  await assert.rejects(f.start({ ...config, downloadFile: join(parent, config.downloadFilename) }), /outside|Invalid private/);
  const linkDirectory = join(f.privateRoot, "hardlinked"); mkdirSync(linkDirectory, { mode: 0o700 });
  const hardlink = join(linkDirectory, config.downloadFilename); linkSync(config.downloadFile, hardlink);
  await assert.rejects(f.start({ ...config, downloadFile: hardlink }), /Invalid private download file/);
});

test("relabeling already-retained legacy bytes as commercial 2.2 is refused", async (t) => {
  const f = await fixture(t), legacyConfig = f.config("2.1.0"), old = await f.start(legacyConfig);
  await old.close();
  const commercial = f.config("2.2.0", { billingEnabled: true });
  const legacyBytes = Buffer.from("local test package 2.1.0");
  writeFileSync(commercial.downloadFile, legacyBytes, { mode: 0o600 });
  await assert.rejects(f.start({ ...commercial, downloadSHA256: digest(legacyBytes), downloadSize: legacyBytes.length }), /cannot relabel/);
});

test("a directory replaced with an escaping symlink after startup disables status, mail and existing tickets", async (t) => {
  const f = await fixture(t), config = f.config("2.2.0");
  const nested = join(f.privateRoot, "packages"); mkdirSync(nested, { mode: 0o700 });
  const nestedFile = join(nested, config.downloadFilename); renameSync(config.downloadFile, nestedFile);
  const s = await f.start({ ...config, downloadFile: nestedFile }), buyer = s.user();
  await s.req(buyer, "POST", "/v1/download/email", {});
  const ticket = await s.claim(buyer);
  const moved = join(f.outside, "packages"); renameSync(nested, moved); symlinkSync(moved, nested);
  assert.deepEqual((await s.req(null, "GET", "/v1/download/status")).json(), { available: false });
  assert.equal((await s.req(buyer, "POST", "/v1/download/email", {})).statusCode, 503);
  assert.equal((await s.req(buyer, "GET", "/v1/download", undefined, ticket)).statusCode, 503);
  assert.equal(s.mail.length, 1);
});

test("byte changes and malformed retained approvals fail closed instead of issuing fresh links", async (t) => {
  const f = await fixture(t), config = f.config("2.2.0"), s = await f.start(config), buyer = s.user();
  writeFileSync(config.downloadFile, Buffer.alloc(config.downloadSize, 1));
  assert.equal((await s.req(buyer, "POST", "/v1/download/email", {})).statusCode, 503);
  assert.equal(s.mail.length, 0);
  await s.close();
  f.config("2.2.0");
  const db = new Store(f.db);
  try { db.run("UPDATE service_state SET value='null' WHERE key='download_release:primary'"); }
  finally { db.close(); }
  await assert.rejects(f.start(config), /Invalid retained download approval/);
});
