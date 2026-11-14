import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, symlinkSync, linkSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadGoogleOAuth } from "../src/google-config.mjs";

test("Google configuration stays optional and never accepts a public, linked or mismatched credential file", () => {
  const root = mkdtempSync(join(tmpdir(), "playmelt-google-config-"));
  const privateRoot = join(root, "private"), publicRoot = join(root, "public");
  mkdirSync(privateRoot); mkdirSync(publicRoot);
  const config = { privateRoot, publicURL: "https://example.test/account/" };
  const file = join(privateRoot, "google.json");
  const doc = { web: { client_id: "fixture-client.apps.googleusercontent.com", client_secret: "fixture_secret_not_a_real_credential", redirect_uris: ["https://example.test/account/v1/auth/google/callback"] } };
  const write = () => writeFileSync(file, JSON.stringify(doc), { mode: 0o600 });
  try {
    assert.deepEqual(loadGoogleOAuth(undefined, config), {});
    assert.throws(() => loadGoogleOAuth("relative.json", config));
    write();
    assert.deepEqual(loadGoogleOAuth(file, config), { googleClientID: doc.web.client_id, googleClientSecret: doc.web.client_secret });
    chmodSync(file, 0o644); assert.throws(() => loadGoogleOAuth(file, config)); chmodSync(file, 0o600);
    const outside = join(publicRoot, "config.json"); writeFileSync(outside, JSON.stringify(doc), { mode: 0o600 });
    assert.throws(() => loadGoogleOAuth(outside, config));
    const symlink = join(privateRoot, "symbolic.json"); symlinkSync(file, symlink); assert.throws(() => loadGoogleOAuth(symlink, config));
    const hardlink = join(privateRoot, "hard.json"); linkSync(file, hardlink); assert.throws(() => loadGoogleOAuth(hardlink, config)); rmSync(hardlink);
    assert.throws(() => loadGoogleOAuth(file, { ...config, publicURL: "https://example.test/other" }));
    doc.web.client_secret = "bad"; write(); assert.throws(() => loadGoogleOAuth(file, config));
    writeFileSync(file, "invalid JSON"); assert.throws(() => loadGoogleOAuth(file, config));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
