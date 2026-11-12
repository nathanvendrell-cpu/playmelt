import test from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  symlinkSync,
  chmodSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validatePrivateStorage } from "../src/private-storage.mjs";
test("persistent data and signing keys cannot be published or read through broad permissions or symlinks", () => {
  const dir = mkdtempSync(join(tmpdir(), "playmelt-private-"));
  try {
    const root = join(dir, "private"),
      web = join(dir, "public");
    mkdirSync(root, { mode: 0o700 });
    mkdirSync(web, { mode: 0o755 });
    const key = join(root, "signing.pem");
    writeFileSync(key, "fixture only", { mode: 0o600 });
    const config = {
      root,
      documentRoot: web,
      database: join(root, "account.sqlite"),
      signingKey: key,
    };
    validatePrivateStorage(config);
    assert.throws(
      () =>
        validatePrivateStorage({
          ...config,
          database: join(web, "account.sqlite"),
        }),
      /inside/,
    );
    chmodSync(key, 0o644);
    assert.throws(() => validatePrivateStorage(config), /permissions/);
    chmodSync(key, 0o600);
    const link = join(root, "linked");
    symlinkSync(web, link);
    assert.throws(
      () =>
        validatePrivateStorage({
          ...config,
          database: join(link, "exposed.sqlite"),
        }),
      /permissions/,
    );
    const publicPrivate = join(web, "private");
    mkdirSync(publicPrivate, { mode: 0o700 });
    writeFileSync(join(publicPrivate, "key"), "fixture only", { mode: 0o600 });
    assert.throws(
      () =>
        validatePrivateStorage({
          root: publicPrivate,
          documentRoot: web,
          database: join(publicPrivate, "data.sqlite"),
          signingKey: join(publicPrivate, "key"),
        }),
      /overlaps/,
    );
  } finally {
    rmSync(dir, { recursive: true });
  }
});
