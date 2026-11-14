import { createPublicKey, sign, verify } from "node:crypto";
import { PassThrough } from "node:stream";

const DOMAIN = Buffer.from("playmelt.update.v1\0");
const TTL = 600;
const CHANNEL = "stable";
const ID = /^[A-Za-z0-9_-]{1,128}$/;
const BUILD = /^[1-9][0-9]{0,17}$/;
const VERSION = /^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$/;
const RELEASE_FIELDS = ["version", "build", "filename", "bytes", "sha256", "edSignature", "publishedAt", "minimumSystemVersion"];
const TUPLE_FIELDS = [...RELEASE_FIELDS, "sparklePublicKey", "channel"];
const CLAIM_FIELDS = ["v", "aud", "purpose", "scope", "sub", "device", "channel", "iat", "exp"];
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value, keys) => plain(value) && Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
const base64 = (value, bytes) => typeof value === "string" && value.length === Math.ceil(bytes / 3) * 4 && Buffer.from(value, "base64").length === bytes && Buffer.from(value, "base64").toString("base64") === value;
const canonicalDate = (value) => typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/.test(value) &&
  Number.isFinite(Date.parse(value)) && new Date(value).toISOString().replace(".000Z", "Z") === value.replace(".000Z", "Z");
const xml = (value) => String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[character]);

function releaseShape(value) {
  return RELEASE_FIELDS.filter((key) => key !== "bytes").every((key) => typeof value[key] === "string" && !/[\r\n\0]/.test(value[key])) &&
    typeof value.version === "string" && VERSION.test(value.version) &&
    typeof value.build === "string" && BUILD.test(value.build) &&
    typeof value.filename === "string" && /^Playmelt(?:-(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5}))?\.(?:zip|dmg)$/.test(value.filename) &&
    Number.isSafeInteger(value.bytes) && value.bytes > 0 && value.bytes <= 2 * 1024 * 1024 * 1024 &&
    typeof value.sha256 === "string" && /^[a-f0-9]{64}$/.test(value.sha256) && base64(value.edSignature, 64) &&
    canonicalDate(value.publishedAt) && typeof value.minimumSystemVersion === "string" &&
    /^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})(?:\.(0|[1-9][0-9]{0,2}))?$/.test(value.minimumSystemVersion);
}

/**
 * Format and pinned-file binding only, NOT cryptographic archive verification.
 * Before registering/publishing, packaging MUST verify the real archive with
 * Sparkle's SDK and retain evidence binding archive SHA256/bytes, CFBundleVersion,
 * marketing version, edSignature and the existing SUPublicEDKey. Never pass an
 * unapproved/relabelled archive here. The archive signing private key stays out
 * of this module/server. ZIP and DMG are both supported by Sparkle 2.10.1.
 * https://sparkle-project.org/documentation/publishing/
 */
export function validateUpdateRelease(release, artifact, sparklePublicKey) {
  if (!exactKeys(release, RELEASE_FIELDS) || !releaseShape(release) || !base64(sparklePublicKey, 32) ||
      !plain(artifact) || artifact.version !== release.version || artifact.filename !== release.filename ||
      artifact.sha !== release.sha256 || artifact.stat?.size !== release.bytes)
    throw Error("Invalid update release or pinned artifact binding");
  const namedVersion = release.filename.match(/^Playmelt-(.+)\.(?:zip|dmg)$/)?.[1];
  if (namedVersion && namedVersion !== release.version) throw Error("Update filename/version mismatch");
  return Object.freeze({ ...release, sparklePublicKey, channel: CHANNEL });
}

/** Call inside retainRelease's existing service_state transaction (no new DDL).
 * Retain this exact returned tuple. Use a separate updates:stable policy key,
 * never the initial email-download floor. Old workers must check the retained
 * tuple on EVERY request through artifactStillApproved().
 */
export function validateUpdateTransition(previous, next) {
  const valid = (value) => exactKeys(value, TUPLE_FIELDS) && releaseShape(value) &&
    base64(value.sparklePublicKey, 32) && value.channel === CHANNEL;
  if (!valid(next) || (previous !== null && previous !== undefined && !valid(previous)))
    throw Error("Invalid retained update approval");
  if (previous) {
    const before = BigInt(previous.build), after = BigInt(next.build);
    const oldVersion = previous.version.split(".").map(Number), newVersion = next.version.split(".").map(Number);
    const versionOrder = newVersion.reduce((order, part, index) => order || Math.sign(part - oldVersion[index]), 0);
    if (after < before || versionOrder < 0 || previous.sparklePublicKey !== next.sparklePublicKey)
      throw Error("Update downgrade or signing key replacement refused");
    if (after === before && TUPLE_FIELDS.some((key) => previous[key] !== next[key]))
      throw Error("Update build replacement refused");
    if (after > before && previous.sha256 === next.sha256)
      throw Error("A new update build cannot relabel the old archive");
  }
  return Object.freeze({ ...next });
}

function publicBase(value) {
  if (typeof value !== "string" || /[%\\\r\n\0]/.test(value) || /\/\.{1,2}(?:\/|$)/.test(value)) throw Error("Invalid update public URL");
  const base = new URL(value);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash ||
      (base.port && base.port !== "443") || /%|\\|\/\//.test(base.pathname) ||
      !/^\/(?:[A-Za-z0-9_-]+\/?)*$/.test(base.pathname)) throw Error("Invalid update public URL");
  return base.origin + base.pathname.replace(/\/$/, "");
}

function responseHeaders(reply) {
  const vary = String(reply.getHeader("Vary") || "").split(",").map((part) => part.trim()).filter(Boolean);
  if (!vary.some((part) => part.toLowerCase() === "authorization")) vary.push("Authorization");
  reply.header("Cache-Control", "private, no-store, no-transform").header("Vary", vary.join(", "))
    .header("Referrer-Policy", "no-referrer").header("X-Content-Type-Options", "nosniff");
}

function byteRange(value, size) {
  if (typeof value !== "string" || value.length > 80) return null;
  const match = value.match(/^bytes=([0-9]*)-([0-9]*)$/);
  if (!match || match[0] !== value || (!match[1] && !match[2])) return null;
  const first = match[1] ? Number(match[1]) : null, last = match[2] ? Number(match[2]) : null;
  if ((first !== null && !Number.isSafeInteger(first)) || (last !== null && !Number.isSafeInteger(last))) return null;
  if (first === null) return last > 0 ? { start: Math.max(0, size - last), end: size - 1 } : null;
  if (first >= size || (last !== null && first > last)) return null;
  return { start: first, end: last === null ? size - 1 : Math.min(last, size - 1) };
}

/**
 * Register relative routes on the existing account-prefix Fastify scope.
 * Injected I/O only: no Store import, schema, alternative file guards or secrets.
 *
 * authenticateDeviceBearer(token43) -> {userID, deviceID|null, verified:true}|null
 * verified:true denotes a principal authenticated by the existing SERVER flow,
 * not a new emailVerified database field. activeDevice({userID,deviceID}) -> true
 * only for that existing account, its matching non-revoked device AND an
 * unexpired server-side device session.
 * Neither callback should test subscription/launch/runtime entitlements.
 * openArtifact() -> FileHandle, reusing existing openPinnedDownload guards.
 * artifactStillApproved() -> strict boolean matching the durable update tuple.
 * retainRelease(tuple) -> atomic validateUpdateTransition(previous,tuple)+write
 * using the existing service_state table. Call registration after other startup
 * configuration has been validated, before listening/advertising this release.
 * now() -> integer UNIX seconds (optional).
 */
export async function registerUpdateDelivery(api, options) {
  const { publicURL, signingKey, sparklePublicKey, channel, release, artifact,
    authenticateDeviceBearer, activeDevice, openArtifact, artifactStillApproved, retainRelease,
    now = () => Math.floor(Date.now() / 1000) } = options;
  if (channel !== CHANNEL || signingKey?.type !== "private" || signingKey.asymmetricKeyType !== "ed25519" ||
      ![authenticateDeviceBearer, activeDevice, openArtifact, artifactStillApproved, retainRelease, now].every((value) => typeof value === "function"))
    throw Error("Invalid update delivery dependencies");
  const base = publicBase(publicURL), approved = validateUpdateRelease(release, artifact, sparklePublicKey);
  const grantPublicKey = createPublicKey(signingKey);
  const feedURL = base + "/v1/updates/appcast.xml";
  const archiveURL = base + "/v1/updates/archive/" + approved.build + "/" + approved.sha256 + "/" + approved.filename;
  const mediaType = approved.filename.endsWith(".dmg") ? "application/x-apple-diskimage" : "application/zip";
  const etag = '"sha256-' + approved.sha256 + '"';
  const systemVersion = approved.minimumSystemVersion.split(".").length === 2 ? approved.minimumSystemVersion + ".0" : approved.minimumSystemVersion;
  // stable is Sparkle's DEFAULT channel: do not emit a custom channel named
  // 'stable', which clients would otherwise need to opt into explicitly.
  const feed = Buffer.from(`<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Playmelt</title><item><title>Playmelt ${xml(approved.version)}</title><sparkle:version>${xml(approved.build)}</sparkle:version><sparkle:shortVersionString>${xml(approved.version)}</sparkle:shortVersionString><sparkle:minimumSystemVersion>${xml(systemVersion)}</sparkle:minimumSystemVersion><pubDate>${xml(new Date(approved.publishedAt).toUTCString())}</pubDate><enclosure url="${xml(archiveURL)}" sparkle:edSignature="${xml(approved.edSignature)}" length="${approved.bytes}" type="${mediaType}" /></item></channel></rss>\n`);
  const clock = () => { const value = now(); if (!Number.isSafeInteger(value) || value < 0) throw Error("Invalid update clock"); return value; };
  clock();
  // Existing guards must verify real path/inode/owner/mode/hash before this call.
  const startup = await openArtifact();
  try { if ((await startup.stat()).size !== approved.bytes) throw Error("Update artifact size changed"); }
  finally { await startup.close(); }
  const fail = (reply, status, error) => {
    if (status === 401) reply.header("WWW-Authenticate", 'Bearer realm="playmelt-updates"');
    return reply.code(status).send({ error });
  };
  const bearer = (req) => {
    const value = req.headers.authorization;
    if (typeof value !== "string") return null;
    const match = value.match(/^Bearer ([A-Za-z0-9_.-]{1,2200})$/);
    return match && match[0] === value ? match[1] : null;
  };
  const noQuery = (req) => !Object.keys(req.query || {}).length && !String(req.raw.url || "").includes("?");
  function grant(token) {
    if (typeof token !== "string") return null;
    const parts = token.match(/^([A-Za-z0-9_-]{1,2048})\.([A-Za-z0-9_-]{86})$/);
    if (!parts || parts[0] !== token) return null;
    try {
      const payload = Buffer.from(parts[1], "base64url"), signature = Buffer.from(parts[2], "base64url");
      if (payload.toString("base64url") !== parts[1] || signature.toString("base64url") !== parts[2] ||
          !verify(null, Buffer.concat([DOMAIN, Buffer.from(parts[1])]), grantPublicKey, signature)) return null;
      const claims = JSON.parse(payload.toString("utf8")), issued = clock();
      if (!exactKeys(claims, CLAIM_FIELDS) || claims.v !== 1 || claims.aud !== "playmelt-updates" ||
          claims.purpose !== "playmelt.update.v1" || claims.scope !== "app.update" || claims.channel !== CHANNEL ||
          typeof claims.sub !== "string" || !ID.test(claims.sub) || claims.sub.trim() !== claims.sub ||
          typeof claims.device !== "string" || !ID.test(claims.device) || claims.device.trim() !== claims.device ||
          !Number.isSafeInteger(claims.iat) || claims.iat < 0 || !Number.isSafeInteger(claims.exp) ||
          claims.exp !== claims.iat + TTL || claims.iat > issued + 5 || claims.exp <= issued) return null;
      return { userID: claims.sub, deviceID: claims.device };
    } catch { return null; }
  }
  async function authorize(req, reply) {
    const principal = grant(bearer(req));
    if (!principal) { fail(reply, 401, "invalid_update_grant"); return null; }
    if (!noQuery(req)) { fail(reply, 400, "invalid_update_request"); return null; }
    if (await activeDevice(principal) !== true) { fail(reply, 403, "update_device_unavailable"); return null; }
    return principal;
  }
  async function availableFile(principal) {
    if (await artifactStillApproved() !== true) return null;
    const file = await openArtifact();
    try {
      if ((await file.stat()).size !== approved.bytes || await artifactStillApproved() !== true || await activeDevice(principal) !== true) {
        await file.close(); return null;
      }
      return file;
    } catch (error) { await file.close(); throw error; }
  }
  const onSend = async (_req, reply, payload) => { responseHeaders(reply); return payload; };
  const settings = { onSend, config: { rateLimit: { max: 30, timeWindow: 60000 } } };
  api.post("/v1/updates/ticket", { ...settings, bodyLimit: 1024 }, async (req, reply) => {
    responseHeaders(reply);
    try {
      const token = bearer(req);
      if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) return fail(reply, 401, "sign_in_required");
      const principal = await authenticateDeviceBearer(token);
      if (!principal) return fail(reply, 401, "sign_in_required");
      if (principal.verified !== true || typeof principal.userID !== "string" || !ID.test(principal.userID) || principal.userID.trim() !== principal.userID ||
          typeof principal.deviceID !== "string" || !ID.test(principal.deviceID) || principal.deviceID.trim() !== principal.deviceID) return fail(reply, 403, "device_required");
      if (!noQuery(req) || !exactKeys(req.body, [])) return fail(reply, 400, "invalid_update_request");
      if (await activeDevice({ userID: principal.userID, deviceID: principal.deviceID }) !== true)
        return fail(reply, 403, "update_device_unavailable");
      const file = await availableFile(principal);
      if (!file) return fail(reply, 503, "updates_unavailable");
      await file.close();
      const issued = clock(), expiresAt = issued + TTL;
      const payload = Buffer.from(JSON.stringify({ v: 1, aud: "playmelt-updates", purpose: "playmelt.update.v1", scope: "app.update",
        sub: principal.userID, device: principal.deviceID, channel: CHANNEL, iat: issued, exp: expiresAt })).toString("base64url");
      const signature = sign(null, Buffer.concat([DOMAIN, Buffer.from(payload)]), signingKey).toString("base64url");
      return { token: payload + "." + signature, expiresAt, feedURL };
    } catch { return fail(reply, 503, "updates_unavailable"); }
  });
  api.route({ ...settings, method: ["GET", "HEAD"], url: "/v1/updates/appcast.xml", handler: async (req, reply) => {
    responseHeaders(reply);
    try {
      const principal = await authorize(req, reply); if (!principal) return;
      const file = await availableFile(principal); if (!file) return fail(reply, 503, "updates_unavailable");
      await file.close();
      reply.type("application/rss+xml; charset=utf-8").header("Content-Length", feed.length);
      return reply.send(req.method === "HEAD" ? undefined : feed);
    } catch { return fail(reply, 503, "updates_unavailable"); }
  } });
  api.route({ ...settings, method: ["GET", "HEAD"], url: "/v1/updates/archive/:build/:sha256/:filename", handler: async (req, reply) => {
    responseHeaders(reply);
    let file, stream;
    try {
      const principal = await authorize(req, reply); if (!principal) return;
      if (req.params.build !== approved.build || req.params.sha256 !== approved.sha256 || req.params.filename !== approved.filename)
        return fail(reply, 404, "update_artifact_not_found");
      let range;
      if (req.method === "GET" && req.headers.range !== undefined && (req.headers["if-range"] === undefined || req.headers["if-range"] === etag)) {
        range = byteRange(req.headers.range, approved.bytes);
        if (!range) { reply.header("Content-Range", "bytes */" + approved.bytes); return fail(reply, 416, "invalid_update_range"); }
      }
      file = await availableFile(principal); if (!file) return fail(reply, 503, "updates_unavailable");
      const start = range?.start ?? 0, end = range?.end ?? approved.bytes - 1;
      reply.type(mediaType).header("Content-Length", end - start + 1).header("Accept-Ranges", "bytes")
        .header("ETag", etag).header("X-Content-SHA256", approved.sha256)
        .header("Content-Disposition", `attachment; filename="${approved.filename}"`);
      if (range) reply.code(206).header("Content-Range", `bytes ${start}-${end}/${approved.bytes}`);
      if (req.method === "HEAD") return reply.send();
      const source = file.createReadStream({ start, end, autoClose: true, highWaterMark: 64 * 1024 });
      stream = new PassThrough({ highWaterMark: 64 * 1024 });
      // Never forward filesystem/backend error text (paths or credential context).
      source.once("error", () => stream.destroy(Error("Update stream unavailable")));
      source.pipe(stream);
      const stop = () => { source.destroy(); stream.destroy(); };
      const cleanup = () => { source.destroy(); req.raw.off("aborted", stop); reply.raw.off("close", stop); };
      req.raw.once("aborted", stop); reply.raw.once("close", stop); stream.once("close", cleanup);
      return reply.send(stream);
    } catch {
      if (stream) { stream.destroy(); return reply; }
      return fail(reply, 503, "updates_unavailable");
    } finally { if (file && !stream) await file.close(); }
  } });
  // Route collisions/startup validation must fail BEFORE changing a retained
  // release. The caller places this plugin last and atomically validates both
  // initial-download and update floors inside retainRelease's transaction.
  await retainRelease(approved);
  if (await artifactStillApproved() !== true) throw Error("Update approval was not retained");
  return Object.freeze({ feedURL, archiveURL, release: approved });
}
