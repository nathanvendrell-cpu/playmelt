import test from "node:test";
import assert from "node:assert/strict";
import Fastify from "fastify";
import { createHash, generateKeyPairSync, sign, verify, createSecretKey } from "node:crypto";
import { mkdtemp, writeFile, open, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Readable } from "node:stream";
import { EventEmitter } from "node:events";
import { registerUpdateDelivery, validateUpdateRelease, validateUpdateTransition } from "../src/update-delivery.mjs";

const DOMAIN = Buffer.from("playmelt.update.v1\0");
const deviceToken = "d".repeat(43), browserToken = "b".repeat(43);
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const keys = generateKeyPairSync("ed25519");
const archiveKeys = generateKeyPairSync("ed25519");
const publicED = archiveKeys.publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
function claims(token) { return JSON.parse(Buffer.from(token.split(".")[0], "base64url")); }
function issue(value, key = keys.privateKey, domain = DOMAIN) {
  const payload = Buffer.from(JSON.stringify(value)).toString("base64url");
  return payload + "." + sign(null, Buffer.concat([domain, Buffer.from(payload)]), key).toString("base64url");
}
async function fixture(t, changes = {}) {
  const directory = await mkdtemp(join(tmpdir(), "playmelt-updates-")), app = Fastify({ logger: false });
  const bytes = changes.bytes ?? Buffer.from("PK\x03\x04inert update archive fixture, no app or account\0\x01");
  const filePath = join(directory, "fixture.archive");
  await writeFile(filePath, bytes, { mode: 0o600 });
  const stats = { opens: 0, closes: 0, active: 0, retain: 0, streams: [] };
  const state = { now: 1900000000, active: true, sessionActive: true, userPresent: true, verified: true,
    guardError: false, available: true, openHook: null, streamError: false, slowStream: false };
  const durable = changes.durable ?? { current: null };
  const release = { version: "2.2.0", build: "30", filename: "Playmelt.zip", bytes: bytes.length,
    sha256: sha(bytes), edSignature: sign(null, bytes, archiveKeys.privateKey).toString("base64"),
    publishedAt: "2026-11-13T15:00:00Z", minimumSystemVersion: "15.0", ...changes.release };
  // This assertion proves ONLY the fixture's real Ed25519 archive signature.
  // Production archive verification remains the SDK/packaging publication gate.
  if (!changes.release) assert.equal(verify(null, bytes, archiveKeys.publicKey, Buffer.from(release.edSignature, "base64")), true);
  const artifact = { version: release.version, filename: release.filename, sha: release.sha256, stat: { size: release.bytes }, ...changes.artifact };
  let expected;
  const options = { publicURL: "https://example.test/compte", signingKey: keys.privateKey, sparklePublicKey: publicED,
    channel: "stable", release, artifact, now: () => state.now,
    authenticateDeviceBearer: async (token) => {
      if (!state.sessionActive || !state.userPresent) return null;
      if (token === browserToken) return { userID: "user-1", deviceID: null, verified: true, isAdmin: true };
      return token === deviceToken ? { userID: "user-1", deviceID: "device-1", verified: state.verified } : null;
    },
    activeDevice: async ({ userID, deviceID }) => {
      stats.active++;
      return state.active && state.sessionActive && state.userPresent && state.verified && userID === "user-1" && deviceID === "device-1";
    },
    openArtifact: async () => {
      if (state.guardError) throw Error("private-path-or-secret-must-not-escape");
      const file = await open(filePath, "r"); stats.opens++;
      file.once("close", () => stats.closes++);
      const create = file.createReadStream.bind(file);
      file.createReadStream = (options) => {
        stats.streams.push(options);
        if (state.streamError || state.slowStream) {
          const stream = new Readable({ read() {
            if (state.streamError) this.destroy(Error("private-path-or-secret-must-not-escape"));
          }, destroy(error, done) { file.close().then(() => done(error), done); } });
          return stream;
        }
        return create(options);
      };
      await state.openHook?.();
      return file;
    },
    artifactStillApproved: async () => state.available && JSON.stringify(durable.current) === JSON.stringify(expected),
    retainRelease: async (tuple) => { stats.retain++; durable.current = validateUpdateTransition(durable.current, tuple); },
    ...changes.options };
  t.after(async () => { try { await app.close(); } finally { await rm(directory, { recursive: true, force: true }); } });
  expected = validateUpdateRelease(release, artifact, options.sparklePublicKey);
  if (changes.beforeRegister) changes.beforeRegister(app, options);
  const registered = await registerUpdateDelivery(app, options);
  await app.ready();
  const feedPath = new URL(registered.feedURL).pathname.replace(/^\/compte/, "");
  const archivePath = new URL(registered.archiveURL).pathname.replace(/^\/compte/, "");
  const request = (method, path, token, payload, headers = {}) => app.inject({ method, url: path, payload,
    headers: { ...(token ? { authorization: "Bearer " + token } : {}), ...headers } });
  const ticket = async () => {
    const response = await request("POST", "/v1/updates/ticket", deviceToken, {});
    assert.equal(response.statusCode, 200, response.payload); return response.json();
  };
  return { app, options, release, artifact, bytes, filePath, stats, state, durable, registered, request, ticket, feedPath, archivePath };
}
const noLeak = (response) => {
  assert.equal(response.headers.location, undefined);
  assert.match(response.headers["cache-control"], /no-store/);
  assert.match(response.headers.vary, /Authorization/);
  assert.equal(response.headers["referrer-policy"], "no-referrer");
  assert.equal(response.headers["x-content-type-options"], "nosniff");
  assert.doesNotMatch(response.payload, /private-path-or-secret-must-not-escape/);
};
async function filesClosed(fixture) {
  const end = Date.now() + 2000;
  while (fixture.stats.opens !== fixture.stats.closes && Date.now() < end) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(fixture.stats.opens, fixture.stats.closes);
}

test("device ticket is a short Ed25519 grant with a separate cryptographic domain and no entitlement dependency", async (t) => {
  const f = await fixture(t), result = await f.ticket(), data = claims(result.token);
  assert.deepEqual(Object.keys(result).sort(), ["expiresAt", "feedURL", "token"]);
  assert.equal(result.expiresAt, f.state.now + 600);
  assert.equal(result.feedURL, "https://example.test/compte/v1/updates/appcast.xml");
  assert.deepEqual(data, { v: 1, aud: "playmelt-updates", purpose: "playmelt.update.v1", scope: "app.update",
    sub: "user-1", device: "device-1", channel: "stable", iat: f.state.now, exp: f.state.now + 600 });
  const [payload, signature] = result.token.split(".");
  assert.equal(verify(null, Buffer.concat([DOMAIN, Buffer.from(payload)]), keys.publicKey, Buffer.from(signature, "base64url")), true);
  assert.equal(verify(null, Buffer.from(payload), keys.publicKey, Buffer.from(signature, "base64url")), false, "cannot reuse as existing launch ticket");
  assert.equal(data.capabilities, undefined);
  assert.equal(f.stats.retain, 1);
  assert.equal(f.stats.opens, f.stats.closes);
});

test("same signed grant works on another worker without a RAM grant map or new schema", async (t) => {
  const durable = { current: null }, a = await fixture(t, { durable }), b = await fixture(t, { durable });
  const ticket = await a.ticket(), feed = await b.request("GET", b.feedPath, ticket.token);
  assert.equal(feed.statusCode, 200); noLeak(feed);
  assert.equal((await b.request("GET", b.archivePath, ticket.token)).statusCode, 200);
});

test("cookies, browser/admin bearer and unverified/expired device principals cannot mint an update grant", async (t) => {
  const f = await fixture(t);
  for (const token of [undefined, "invalid", "x".repeat(42), "x".repeat(44)]) {
    const response = await f.request("POST", "/v1/updates/ticket", token, {}, { cookie: "pm_session=" + deviceToken });
    assert.equal(response.statusCode, 401); noLeak(response);
  }
  assert.equal((await f.request("POST", "/v1/updates/ticket", browserToken, {})).statusCode, 403);
  f.state.verified = false;
  assert.equal((await f.request("POST", "/v1/updates/ticket", deviceToken, {})).statusCode, 403);
  f.state.verified = true; f.state.sessionActive = false;
  assert.equal((await f.request("POST", "/v1/updates/ticket", deviceToken, {})).statusCode, 401);
});

test("ticket accepts only empty JSON; query credentials, extra claims and alternate purposes are refused", async (t) => {
  const f = await fixture(t);
  for (const body of [[], null, { channel: "stable" }, { token: "fixture" }, { purpose: "launch" }])
    assert.equal((await f.request("POST", "/v1/updates/ticket", deviceToken, body)).statusCode, 400);
  assert.equal((await f.request("POST", "/v1/updates/ticket?token=fixture", deviceToken, {})).statusCode, 400);
  const { token } = await f.ticket();
  for (const path of [f.feedPath + "?token=fixture", f.archivePath + "?token=fixture"]) {
    const response = await f.request("GET", path, token); assert.equal(response.statusCode, 400); noLeak(response);
  }
});

test("grant validity is strict: tampering, expiry, future issue, wrong key/domain/audience/scope/channel and extra rights fail", async (t) => {
  const f = await fixture(t), ticket = await f.ticket(), valid = claims(ticket.token);
  const forged = [ticket.token.slice(0, -1) + (ticket.token.endsWith("A") ? "B" : "A"),
    issue(valid, generateKeyPairSync("ed25519").privateKey), issue(valid, keys.privateKey, Buffer.from("different-domain\0")),
    issue({ ...valid, purpose: "launch" }), issue({ ...valid, aud: "playmelt-desktop" }), issue({ ...valid, scope: "runtime.download" }),
    issue({ ...valid, channel: "beta" }), issue({ ...valid, capabilities: ["launch"] }), issue({ ...valid, v: "1" }),
    issue({ ...valid, iat: f.state.now + 6, exp: f.state.now + 606 }), issue({ ...valid, exp: valid.exp + 1 }),
    issue({ ...valid, sub: 1 }), issue({ ...valid, device: "device-1\n" }), deviceToken, "x".repeat(2300)];
  for (const token of forged) {
    const response = await f.request("GET", f.feedPath, token); assert.equal(response.statusCode, 401); noLeak(response);
  }
  f.state.now += 600;
  for (const path of [f.feedPath, f.archivePath]) assert.equal((await f.request("GET", path, ticket.token)).statusCode, 401);
});

test("account/device revocation or logout is rechecked for both feed and artifact, including HEAD", async (t) => {
  const f = await fixture(t), { token } = await f.ticket();
  for (const flag of ["active", "sessionActive", "userPresent", "verified"]) {
    f.state[flag] = false;
    for (const method of ["GET", "HEAD"]) for (const path of [f.feedPath, f.archivePath]) {
      const response = await f.request(method, path, token); assert.equal(response.statusCode, 403); noLeak(response);
    }
    f.state[flag] = true;
  }
  const other = issue({ ...claims(token), device: "device-other" });
  assert.equal((await f.request("GET", f.feedPath, other)).statusCode, 403);
});

test("feed is signed-enclosure RSS with canonical same-base immutable URLs and no notes/token/custom stable channel", async (t) => {
  const f = await fixture(t), { token } = await f.ticket(), response = await f.request("GET", f.feedPath, token);
  assert.equal(response.statusCode, 200); noLeak(response);
  assert.match(response.headers["content-type"], /^application\/rss\+xml/);
  assert.equal(Number(response.headers["content-length"]), response.rawPayload.length);
  assert.match(response.payload, /<sparkle:version>30<\/sparkle:version>/);
  assert.match(response.payload, /<sparkle:shortVersionString>2\.2\.0<\/sparkle:shortVersionString>/);
  assert.match(response.payload, /<sparkle:minimumSystemVersion>15\.0\.0<\/sparkle:minimumSystemVersion>/);
  assert.ok(response.payload.includes('url="' + f.registered.archiveURL + '"'));
  assert.ok(response.payload.includes('sparkle:edSignature="' + f.release.edSignature + '"'));
  assert.ok(response.payload.includes('length="' + f.bytes.length + '"'));
  assert.doesNotMatch(response.payload, /releaseNotes|<description|<link>|sparkle:channel|Bearer|token=/);
  assert.equal(new URL(f.registered.archiveURL).origin, new URL(f.registered.feedURL).origin);
  assert.equal(new URL(f.registered.archiveURL).search, "");
  const head = await f.request("HEAD", f.feedPath, token);
  assert.equal(head.statusCode, 200); assert.equal(head.payload, "");
  assert.equal(head.headers["content-length"], response.headers["content-length"]);
});

test("ZIP bytes, size and SHA are immutable; full and single-range streams are bounded and all file handles close", async (t) => {
  const f = await fixture(t), { token } = await f.ticket(), full = await f.request("GET", f.archivePath, token);
  assert.equal(full.statusCode, 200); assert.deepEqual(full.rawPayload, f.bytes); noLeak(full);
  assert.equal(full.headers["content-type"], "application/zip");
  assert.equal(Number(full.headers["content-length"]), f.bytes.length);
  assert.equal(full.headers["x-content-sha256"], sha(f.bytes));
  for (const [range, start, end] of [["bytes=0-3", 0, 3], ["bytes=4-", 4, f.bytes.length - 1], ["bytes=-4", f.bytes.length - 4, f.bytes.length - 1], ["bytes=0-9999", 0, f.bytes.length - 1]]) {
    const response = await f.request("GET", f.archivePath, token, undefined, { range });
    assert.equal(response.statusCode, 206); assert.deepEqual(response.rawPayload, f.bytes.subarray(start, end + 1));
    assert.equal(response.headers["content-range"], `bytes ${start}-${end}/${f.bytes.length}`);
    assert.equal(Number(response.headers["content-length"]), end - start + 1);
  }
  const head = await f.request("HEAD", f.archivePath, token, undefined, { range: "bytes=0-3" });
  assert.equal(head.statusCode, 200); assert.equal(head.payload, ""); assert.equal(Number(head.headers["content-length"]), f.bytes.length);
  const staleRange = await f.request("GET", f.archivePath, token, undefined, { range: "bytes=0-3", "if-range": '"old"' });
  assert.equal(staleRange.statusCode, 200); assert.deepEqual(staleRange.rawPayload, f.bytes);
  assert.ok(f.stats.streams.every((options) => options.highWaterMark === 65536 && options.autoClose && options.end < f.bytes.length));
  await filesClosed(f);
});

test("malformed/overlarge/multipart/unsatisfiable ranges and altered archive tuples never open a stream", async (t) => {
  const f = await fixture(t), { token } = await f.ticket(), before = f.stats.streams.length;
  for (const range of ["bytes=", "bytes=-0", "bytes=9-2", "bytes=9999-", "bytes=0-1,2-3", "bytes=9007199254740992-", "items=0-3", "bytes=" + "1".repeat(81) + "-"]) {
    const response = await f.request("GET", f.archivePath, token, undefined, { range });
    assert.equal(response.statusCode, 416); assert.equal(response.headers["content-range"], "bytes */" + f.bytes.length); noLeak(response);
  }
  for (const path of [f.archivePath.replace("/30/", "/29/"), f.archivePath.replace(f.release.sha256, "a".repeat(64)), f.archivePath.replace("Playmelt.zip", "Other.zip"), f.archivePath.replace("Playmelt.zip", "..%2Fsecret")])
    assert.equal((await f.request("GET", path, token)).statusCode, 404);
  assert.equal(f.stats.streams.length, before);
});

test("missing/changed/unapproved artifact blocks feed and bytes without path or backend error exposure", async (t) => {
  const f = await fixture(t), { token } = await f.ticket();
  for (const flag of ["guardError", "available"]) {
    f.state[flag] = flag === "guardError";
    for (const path of [f.feedPath, f.archivePath]) { const r = await f.request("GET", path, token); assert.equal(r.statusCode, 503); noLeak(r); }
    f.state[flag] = flag !== "guardError";
  }
  await writeFile(f.filePath, Buffer.from("different size"));
  assert.equal((await f.request("GET", f.feedPath, token)).statusCode, 503);
  assert.equal((await f.request("GET", f.archivePath, token)).statusCode, 503);
  assert.equal(f.stats.opens, f.stats.closes);
});

test("stream failures are sanitized and close the owned file", async (t) => {
  const f = await fixture(t), { token } = await f.ticket(); f.state.streamError = true;
  const result = await f.request("GET", f.archivePath, token);
  assert.equal(result.statusCode, 500); noLeak(result);
  assert.match(result.payload, /Update stream unavailable/);
  await filesClosed(f);
});

test("an aborted HTTP response destroys its bounded stream and file without a server process", async (t) => {
  const f = await fixture(t), { token } = await f.ticket(); f.state.slowStream = true;
  // Invoke the registered handler with exact route context and EventEmitters;
  // no TCP listener or test server is created to test the close boundary.
  let route;
  const collector = { post() {}, route(value) { if (value.url.includes("archive/")) route = value; } };
  await registerUpdateDelivery(collector, f.options);
  const rawRequest = new EventEmitter(), rawReply = new EventEmitter(); rawRequest.url = f.archivePath;
  const headers = {}, reply = { raw: rawReply, getHeader(name) { return headers[name]; }, header(name, value) { headers[name] = value; return this; },
    type() { return this; }, code() { return this; }, send(value) { this.value = value; return this; } };
  await route.handler({ method: "GET", headers: { authorization: "Bearer " + token }, query: {}, params: { build: f.release.build, sha256: f.release.sha256, filename: f.release.filename }, raw: rawRequest }, reply);
  rawReply.emit("close");
  await new Promise((resolve) => reply.value.once("close", resolve));
  await filesClosed(f);
  assert.equal(reply.value.destroyed, true);
  assert.equal(rawRequest.listenerCount("aborted"), 0); assert.equal(rawReply.listenerCount("close"), 0);
});

test("format/binding validation refuses unapproved version/build/path/header/signature/size inputs", () => {
  const release = { version: "2.2.0", build: "30", filename: "Playmelt.zip", bytes: 10, sha256: "a".repeat(64), edSignature: Buffer.alloc(64, 1).toString("base64"), publishedAt: "2026-11-13T15:00:00Z", minimumSystemVersion: "15.0" };
  const artifact = { version: release.version, filename: release.filename, sha: release.sha256, stat: { size: 10 } };
  for (const patch of [{ version: "2.2.0-beta" }, { version: "02.2.0" }, { version: "2.2.0\n" }, { build: 30 }, { build: "030" }, { build: "0" }, { build: "3.0" }, { build: "1".repeat(19) },
    { filename: "../Playmelt.zip" }, { filename: "Playmelt.zip\r\nX: bad" }, { bytes: 0 }, { bytes: 2 ** 31 + 1 }, { sha256: "bad" }, { edSignature: "x" }, { publishedAt: "2026-02-30T00:00:00Z" }, { minimumSystemVersion: "15.0<xml>" }, { url: "https://external.test/archive" }])
    assert.throws(() => validateUpdateRelease({ ...release, ...patch }, artifact, publicED));
  for (const patch of [{ sha: "b".repeat(64) }, { stat: { size: 9 } }, { filename: "Other.zip" }, { version: "2.1.0" }])
    assert.throws(() => validateUpdateRelease(release, { ...artifact, ...patch }, publicED));
  assert.throws(() => validateUpdateRelease(release, artifact, "invalid"));
  assert.equal(validateUpdateRelease(release, artifact, publicED).edSignature, release.edSignature, "format validation does not pretend to cryptographically verify an archive");
});

test("monotone update approval is independent of initial download policy and refuses replacement/relabel/key rotation", () => {
  const artifact = { version: "2.2.0", filename: "Playmelt.zip", sha: "a".repeat(64), stat: { size: 10 } };
  const first = validateUpdateRelease({ version: "2.2.0", build: "30", filename: "Playmelt.zip", bytes: 10, sha256: artifact.sha, edSignature: Buffer.alloc(64, 1).toString("base64"), publishedAt: "2026-11-13T15:00:00Z", minimumSystemVersion: "15.0" }, artifact, publicED);
  assert.deepEqual(validateUpdateTransition(null, first), first);
  assert.deepEqual(validateUpdateTransition(first, first), first);
  for (const patch of [{ build: "29" }, { sha256: "b".repeat(64) }, { edSignature: Buffer.alloc(64, 2).toString("base64") }, { build: "31" }, { version: "2.1.9", build: "31", sha256: "b".repeat(64) }, { sparklePublicKey: Buffer.alloc(32, 2).toString("base64") }])
    assert.throws(() => validateUpdateTransition(first, { ...first, ...patch }));
  assert.equal(validateUpdateTransition(first, { ...first, build: "31", sha256: "b".repeat(64) }).build, "31");
  assert.throws(() => validateUpdateTransition({ build: "bad" }, first));
});

test("invalid public URL/key/dependencies or route collisions fail before promoting the durable floor", async (t) => {
  for (const publicURL of ["http://example.test/compte", "https://u:p@example.test/compte", "https://example.test/compte?token=x", "https://example.test/compte#x", "https://example.test:444/compte", "https://example.test/compte/../other", "https://example.test/%2e%2e/other", "https://example.test/compte\\other"]) {
    const durable = { current: null };
    await assert.rejects(fixture(t, { durable, options: { publicURL } })); assert.equal(durable.current, null);
  }
  const durable = { current: null };
  await assert.rejects(fixture(t, { durable, beforeRegister(app) { app.get("/v1/updates/appcast.xml", () => "collision"); } }));
  assert.equal(durable.current, null);
  await assert.rejects(fixture(t, { options: { signingKey: createSecretKey(Buffer.alloc(32, 1)) } }));
});

test("DMG variant uses the same authorization and immutable delivery contract", async (t) => {
  const f = await fixture(t, { release: { filename: "Playmelt-2.2.0.dmg" } }), { token } = await f.ticket();
  const response = await f.request("GET", f.archivePath, token);
  assert.equal(response.statusCode, 200); assert.equal(response.headers["content-type"], "application/x-apple-diskimage");
  assert.deepEqual(response.rawPayload, f.bytes);
});
