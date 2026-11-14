import Fastify from "fastify";
import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import { createHash, randomUUID, sign } from "node:crypto";
import { constants, readFileSync } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";
import { digest } from "./store.mjs";
import { plans, processEvent } from "./billing.mjs";
import { registerSupport } from "./support.mjs";
import { normalizeEmail } from "./email.mjs";
import { registerAdmin } from "./admin.mjs";
import { retainTerms, sendContract } from "./contracts.mjs";
import { registerPasswordAuth } from "./password-auth.mjs";
import { registerGoogleAuth } from "./google-auth.mjs";
import { loadPortalConfiguration, validatePortalConfiguration } from "./portal-config.mjs";
import { registerUpdateDelivery, validateUpdateRelease, validateUpdateTransition } from "./update-delivery.mjs";
import { networkPolicyOptions, registerNetworkPolicy } from "./network-policy.mjs";

const downloadableReleases = Object.freeze({
  "2.1.0": { filename: "Playmelt-2.1.0.dmg", generation: 1 },
  "2.2.0": { filename: "Playmelt-2.2.0.dmg", generation: 2 },
});
const inside = (root, path) => {
  const part = relative(root, path);
  return part !== "" && part !== ".." && !part.startsWith(".." + sep) && !isAbsolute(part);
};
const unchangedFile = (before, after) =>
  ["dev", "ino", "size", "mtimeMs", "ctimeMs", "mode", "uid", "nlink"].every((key) => before[key] === after[key]);

async function privateDownloadPath(source) {
  const inputRoot = resolve(source.privateRoot), inputFile = resolve(source.downloadFile);
  if (!inside(inputRoot, inputFile)) throw Error("Download escapes private storage");
  const [root, web, path] = await Promise.all([
    realpath(inputRoot), realpath(source.documentRoot), realpath(inputFile),
  ]);
  if (!inside(root, path) || root === web || inside(web, root) || inside(root, web))
    throw Error("Download must remain outside the document root");
  // Reject symlinks throughout the configured private tree, including parents.
  // System ancestors such as macOS /var are outside this trusted root boundary.
  let entry = inputRoot;
  const segments = relative(inputRoot, inputFile).split(sep);
  for (let index = -1; index < segments.length; index++) {
    if (index >= 0) entry = join(entry, segments[index]);
    const stat = await lstat(entry), directory = index < segments.length - 1;
    if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) ||
        (stat.mode & 0o077) || (process.getuid && stat.uid !== process.getuid()))
      throw Error("Invalid private download path");
  }
  return { path, root };
}

function downloadPolicyKey(config) {
  // The explicitly isolated test account cannot promote or replace production.
  return config.testAccountEmail
    ? "download_release:isolated-test:" + digest(config.testAccountEmail)
    : "download_release:primary";
}
function pinDownloadRelease(store, config, artifact, inTransaction = false) {
  if (!artifact) return;
  const generation = downloadableReleases[artifact.version].generation;
  if (config.billingEnabled === true && generation < 2)
    throw Error("Commercial billing requires the approved commercial client");
  const key = downloadPolicyKey(config);
  const retain = () => {
    const existing = store.get("SELECT value FROM service_state WHERE key=?", key);
    const previous = existing ? JSON.parse(existing.value) : null;
    if (existing && (!previous || typeof previous !== "object" || Array.isArray(previous) ||
        !Object.hasOwn(downloadableReleases, previous.version) ||
        !Number.isSafeInteger(previous.bytes) || previous.bytes <= 0 || !/^[a-f0-9]{64}$/.test(previous.sha256 || "")))
      throw Error("Invalid retained download approval");
    if (previous) {
      const before = downloadableReleases[previous.version].generation;
      if (generation < before) throw Error("Download release downgrade refused");
      if (generation > before && previous.sha256 === artifact.sha)
        throw Error("A new release cannot relabel the retained legacy artifact");
      if (generation === before && (previous.sha256 !== artifact.sha || previous.bytes !== artifact.stat.size))
        throw Error("Download replacement requires a separately approved release");
    }
    store.run(
      "INSERT INTO service_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      key, JSON.stringify({ version: artifact.version, sha256: artifact.sha, bytes: artifact.stat.size }),
    );
  };
  if (inTransaction) retain(); else store.transaction(retain);
}
function downloadStillApproved(store, config, artifact) {
  if (!artifact || (config.billingEnabled === true && downloadableReleases[artifact.version].generation < 2)) return false;
  const retained = store.get("SELECT value FROM service_state WHERE key=?", downloadPolicyKey(config));
  if (!retained) return false;
  try {
    const approval = JSON.parse(retained.value);
    return approval.version === artifact.version && approval.sha256 === artifact.sha && approval.bytes === artifact.stat.size;
  } catch { return false; }
}
async function openPinnedDownload(artifact) {
  const location = await privateDownloadPath(artifact.source);
  if (location.path !== artifact.path || location.root !== artifact.root) throw Error("Download location changed");
  const file = await open(location.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    if (!unchangedFile(artifact.stat, await file.stat())) throw Error("Download artifact changed");
    const after = await privateDownloadPath(artifact.source);
    if (after.path !== artifact.path || after.root !== artifact.root) throw Error("Download location changed");
    return file;
  } catch (error) { await file.close(); throw error; }
}

// A configured artifact is immutable until restart and must never be web-served.
async function downloadArtifact(config) {
  if (!config.downloadFile) return null;
  if (
    ![config.downloadFile, config.privateRoot, config.documentRoot].every((path) => typeof path === "string" && isAbsolute(path)) ||
    !Object.hasOwn(downloadableReleases, config.downloadVersion) ||
    downloadableReleases[config.downloadVersion].filename !== config.downloadFilename ||
    basename(config.downloadFile) !== config.downloadFilename ||
    !/^[a-f0-9]{64}$/.test(config.downloadSHA256 || "") ||
    !Number.isSafeInteger(config.downloadSize) || config.downloadSize <= 0
  ) throw Error("Invalid private download configuration");
  if (config.billingEnabled === true && downloadableReleases[config.downloadVersion].generation < 2)
    throw Error("Commercial billing requires the approved commercial client");
  return privateArtifact(config, {
    file: config.downloadFile, version: config.downloadVersion,
    filename: config.downloadFilename, sha256: config.downloadSHA256, bytes: config.downloadSize,
  });
}

async function privateArtifact(config, release) {
  if (![release.file, config.privateRoot, config.documentRoot].every((p) => typeof p === "string" && isAbsolute(p)) ||
      basename(release.file) !== release.filename || !/^[a-f0-9]{64}$/.test(release.sha256 || "") ||
      !Number.isSafeInteger(release.bytes) || release.bytes <= 0)
    throw Error("Invalid private artifact configuration");
  const source = Object.freeze({ privateRoot: config.privateRoot, documentRoot: config.documentRoot, downloadFile: release.file });
  const { path, root } = await privateDownloadPath(source);
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.nlink !== 1 || (stat.mode & 0o077) || (process.getuid && stat.uid !== process.getuid()) || stat.size !== release.bytes)
      throw Error("Invalid private download file");
    const hash = createHash("sha256");
    for await (const chunk of file.createReadStream({ autoClose: false })) hash.update(chunk);
    if (hash.digest("hex") !== release.sha256 || !unchangedFile(stat, await file.stat()))
      throw Error("Download does not match its verified manifest");
    const after = await privateDownloadPath(source);
    if (after.path !== path || after.root !== root) throw Error("Download location changed");
    return Object.freeze({ path, root, source, stat, sha: release.sha256, filename: release.filename, version: release.version });
  } finally {
    await file.close();
  }
}

async function updateConfiguration(config) {
  if (!config.updateManifestFile) return null;
  const source = { privateRoot: config.privateRoot, documentRoot: config.documentRoot, downloadFile: config.updateManifestFile };
  const location = await privateDownloadPath(source);
  const file = await open(location.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  let manifest;
  try {
    const before = await file.stat();
    if (!before.isFile() || before.nlink !== 1 || (before.mode & 0o077) ||
        (process.getuid && before.uid !== process.getuid()) || before.size > 16384)
      throw Error("Invalid private update manifest");
    const content = await file.readFile();
    const after = await privateDownloadPath(source);
    if (content.length !== before.size || !unchangedFile(before, await file.stat()) ||
        after.path !== location.path || after.root !== location.root)
      throw Error("Update manifest changed during validation");
    manifest = JSON.parse(content.toString("utf8"));
  } finally { await file.close(); }
  if (!manifest || typeof manifest !== "object" || Array.isArray(manifest) ||
      Object.keys(manifest).sort().join(",") !== "archiveFile,release,sparklePublicKey")
    throw Error("Invalid private update manifest fields");
  const artifact = await privateArtifact(config, { ...manifest.release, file: manifest.archiveFile });
  // The archive's real Sparkle verification is a packaging prerequisite; the
  // server validates the immutable tuple and serves those exact approved bytes.
  validateUpdateRelease(manifest.release, artifact, manifest.sparklePublicKey);
  return { release: manifest.release, sparklePublicKey: manifest.sparklePublicKey, artifact };
}
export async function createApp({ store, stripe, mailer, config }) {
  const networkOptions = networkPolicyOptions(config);
  const isolatedBillingTest = config.live === false &&
    typeof config.testAccountEmail === "string" &&
    normalizeEmail(config.testAccountEmail) === config.testAccountEmail;
  if (config.billingEnabled === true && config.testing !== true &&
      !config.downloadFile && !isolatedBillingTest)
    throw Error("Commercial billing requires a configured private client package");
  store.setInternalEmails(config.internalEmails || []);
  const artifact = await downloadArtifact(config);
  const updates = await updateConfiguration(config);
  retainTerms(store, config);
  const app = Fastify({
    logger: false,
    bodyLimit: 256 * 1024,
    trustProxy: networkOptions.trustProxy,
  });
  let drainPasswordMail = async () => {};
  let networkPolicy;
  const base = new URL(config.publicURL),
    prefix = base.pathname.replace(/\/$/, "");
  if (
    (base.protocol !== "https:" && !config.testing) ||
    base.username ||
    base.password ||
    base.search ||
    base.hash
  )
    throw Error("Invalid public URL");
  const url = (path) => base.origin + prefix + path;
  await app.register(cookie);
  await app.register(rateLimit, { max: 120, timeWindow: 60000 });
  app.removeContentTypeParser("application/json");
  app.addContentTypeParser(
    "application/json",
    { parseAs: "buffer" },
    (request, body, done) => {
      request.rawBody = body;
      try {
        done(null, JSON.parse(body));
      } catch (e) {
        done(e);
      }
    },
  );
  app.addHook("onSend", async (req, reply, payload) => {
    reply
      .header("Cache-Control", "no-store")
      .header("X-Content-Type-Options", "nosniff")
      .header("Referrer-Policy", "no-referrer")
      .header(
        "Content-Security-Policy",
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
      );
    if (!config.testing)
      reply.header("Strict-Transport-Security", "max-age=31536000");
    return payload;
  });
  app.setErrorHandler((error, req, reply) => {
    const code =
      error.statusCode && error.statusCode < 500 ? error.statusCode : 503;
    reply.code(code).send({
      error:
        code === 429
          ? "too_many_requests"
          : code >= 500
            ? "service_unavailable"
            : "invalid_request",
    });
  });
  const fail = (reply, status, error) => reply.code(status).send({ error });
  function auth(req, reply) {
    const bearer = req.headers.authorization?.match(
      /^Bearer ([A-Za-z0-9_-]{43})$/,
    )?.[1];
    const user = store.authenticate(bearer || req.cookies.pm_session);
    if (!user) {
      fail(reply, 401, "sign_in_required");
      return null;
    }
    if (req.method !== "GET" && !bearer && req.headers.origin !== base.origin) {
      fail(reply, 403, "origin_mismatch");
      return null;
    }
    return user;
  }
  const sessionCookie = (reply, value) =>
    reply.setCookie("pm_session", value, {
      httpOnly: true,
      secure: !config.testing,
      sameSite: "strict",
      path: prefix || "/",
      maxAge: 30 * 86400,
    });
  const downloadCookie = { httpOnly: true, secure: !config.testing, sameSite: "strict", path: prefix + "/v1/download", maxAge: 60 };
  function accountBrowser(req, reply) {
    const user = auth(req, reply);
    if (!user) return null;
    if (user.device_id) {
      fail(reply, 403, "browser_required");
      return null;
    }
    return user;
  }
  function browser(req, reply) {
    const user = auth(req, reply);
    if (!user) return null;
    if (user.device_id || req.headers.authorization || !req.cookies.pm_session) {
      fail(reply, 403, "browser_required");
      return null;
    }
    if (req.method !== "GET" && req.headers.origin !== base.origin) {
      fail(reply, 403, "origin_mismatch");
      return null;
    }
    return user;
  }
  function downloadBrowser(req, reply) {
    const user = browser(req, reply);
    if (user && config.testAccountEmail && user.email !== config.testAccountEmail) {
      fail(reply, 403, "test_account_only");
      return null;
    }
    return user;
  }
  async function downloadAvailable() {
    if (!downloadStillApproved(store, config, artifact)) return false;
    let file;
    try { file = await openPinnedDownload(artifact); return downloadStillApproved(store, config, artifact); }
    catch { return false; }
    finally { if (file) await file.close(); }
  }
  async function sendDownload(user, source) {
    if (!(await downloadAvailable())) return { error: "download_unavailable" };
    const recipient = normalizeEmail(user.email);
    if (!recipient || recipient !== user.email) return { error: "invalid_email" };
    if (config.testAccountEmail && recipient !== config.testAccountEmail)
      return { error: "test_account_only" };
    const value = store.downloadLink(user.id, artifact.sha, source);
    if (!value) return { error: "download_rate_limited" };
    try {
      const result = await mailer.sendMail({
        from: config.mailFrom,
        to: { address: recipient },
        subject: "Votre téléchargement de Playmelt",
        text: `Votre compte Playmelt est vérifié. Téléchargez Playmelt ${artifact.version} avec ce lien personnel, valable 15 minutes et utilisable une seule fois :\n\n${url("/")}#download=${value}\n\nOuvrez-le dans le navigateur où vous êtes connecté à votre compte Playmelt. Aucun paiement n’est nécessaire pour télécharger l’application ; son utilisation dépend de votre accès.\n\nSi vous n’avez pas demandé ce lien, ignorez ce message.`,
      });
      const accepted = Array.isArray(result?.accepted) && result.accepted.some((address) => normalizeEmail(address) === recipient);
      store.downloadDelivery(value, accepted);
      return accepted ? { emailAccepted: true } : { error: "download_email_unavailable" };
    } catch {
      store.downloadDelivery(value, false);
      return { error: "download_email_unavailable" };
    }
  }
  await app.register(
    async (api) => {
      registerSupport(api, { store, config, mailer, auth, fail });
      registerAdmin(api, { store, config, auth, fail, base, prefix });
      registerGoogleAuth(api, { store, config, sessionCookie, url, fail, origin: base.origin, prefix });
      api.get("/v1/download/status", async () => {
        const available = await downloadAvailable();
        return { available, ...(available ? { version: artifact.version } : {}) };
      });
      api.post("/v1/download/email", { config: { rateLimit: { max: 10, timeWindow: 3600000 } } }, async (req, reply) => {
        const user = downloadBrowser(req, reply);
        if (!user) return;
        if (Object.keys(req.body || {}).some((key) => key !== "source") || !["site", "app"].includes(req.body?.source || "site"))
          return fail(reply, 400, "invalid_request");
        const result = await sendDownload(user, req.body?.source || "site");
        return result.error ? fail(reply, result.error === "download_rate_limited" ? 429 : 503, result.error) : result;
      });
      api.post("/v1/download/claim", async (req, reply) => {
        const user = downloadBrowser(req, reply);
        if (!user) return;
        if (!(await downloadAvailable())) return fail(reply, 503, "download_unavailable");
        const value = req.body?.token;
        if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value) || Object.keys(req.body).some((key) => key !== "token"))
          return fail(reply, 400, "invalid_link");
        const transfer = store.claimDownload(value, user.id, artifact.sha, req.cookies.pm_session);
        if (!transfer) return fail(reply, 400, "expired_link");
        reply.setCookie("pm_download", transfer, downloadCookie);
        return { ready: true };
      });
      api.get("/v1/download", async (req, reply) => {
        const user = downloadBrowser(req, reply);
        if (!user) return;
        // Fastify generates a HEAD handler for GET: it must never consume a grant.
        if (req.method !== "GET") return fail(reply, 405, "get_required");
        if (!downloadStillApproved(store, config, artifact)) return fail(reply, 503, "download_unavailable");
        const transfer = req.cookies.pm_download;
        if (Object.keys(req.query || {}).length || typeof transfer !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(transfer))
          return fail(reply, 400, "invalid_link");
        let file;
        try {
          file = await openPinnedDownload(artifact);
        } catch {
          if (file) await file.close();
          return fail(reply, 503, "download_unavailable");
        }
        let stream;
        try {
          if (!downloadStillApproved(store, config, artifact)) return fail(reply, 503, "download_unavailable");
          const grant = store.consumeDownload(transfer, user.id, artifact.sha, req.cookies.pm_session);
          if (!grant) return fail(reply, 400, "expired_link");
          reply.clearCookie("pm_download", { path: downloadCookie.path });
          if (!user.is_internal) {
            store.activity("download", grant.source);
            store.activity("customer_download", grant.source);
          }
          stream = file.createReadStream({ autoClose: true });
          const stop = () => stream.destroy();
          req.raw.once("aborted", stop);
          reply.raw.once("close", stop);
          stream.once("close", () => {
            req.raw.off("aborted", stop);
            reply.raw.off("close", stop);
          });
          return reply
            .type("application/x-apple-diskimage")
            .header("Content-Disposition", `attachment; filename="${artifact.filename}"`)
            .header("Content-Length", artifact.stat.size)
            .header("Accept-Ranges", "none")
            .send(stream);
        } catch (error) {
          if (stream) stream.destroy();
          throw error;
        } finally {
          if (!stream) await file.close();
        }
      });
      api.get("/health", async () => ({
        status: "ok",
        release: config.release || "development",
        billingConfigured:
          config.billingEnabled !== false &&
          !!config.webhookSecret &&
          Object.keys(plans).every((p) =>
            /^price_/.test(config.prices[p] || ""),
          ),
        mode: config.live ? "live" : "test",
      }));
      api.get("/v1/billing/status", async () => ({
        enabled: config.billingEnabled !== false,
        mode: config.live ? "live" : "test",
      }));
      drainPasswordMail = registerPasswordAuth(api, { store, config, mailer, browser, sessionCookie, url, fail, origin: base.origin });
      networkPolicy = registerNetworkPolicy(api, { store, options:networkOptions, browser, mailer, config, url, fail });
      api.get("/v1/plans", async () =>
        Object.entries(plans).map(([id, p]) => ({
          id,
          ...p,
          currency: "EUR",
          trialDays: p.months ? 30 : 0,
        })),
      );
      api.get("/v1/legal", async () => ({
        version: config.termsVersion,
        url: config.termsURL,
        privacyURL: config.privacyURL,
        supportEmail: config.supportEmail,
      }));
      api.post(
        "/v1/auth/email",
        { config: { rateLimit: { max: 5, timeWindow: 15 * 60000 } } },
        async (req, reply) => {
          if (req.headers.origin !== base.origin)
            return fail(reply, 403, "origin_mismatch");
          const email = normalizeEmail(req.body?.email);
          if (!email) return fail(reply, 400, "invalid_email");
          if (config.testAccountEmail && email !== config.testAccountEmail)
            return { requested: true };
          const intent = req.body?.intent || "", source = req.body?.source || "site";
          if (!["", "download"].includes(intent) || !["site", "app"].includes(source))
            return fail(reply, 400, "invalid_request");
          const recent = store.get(
            "SELECT COUNT(*) AS n FROM magic_links WHERE email=? AND expires>?",
            email,
            store.now(),
          );
          if (recent.n < 3) {
            const value = store.magic(email, intent, source);
            try {
              const delivered = await mailer.sendMail({
                from: config.mailFrom,
                to: { address: email },
                subject: "Votre connexion à Playmelt",
                text: `Connectez-vous à Playmelt avec ce lien, valable 15 minutes :\n\n${url("/confirm")}${intent ? "?intent=download" + (source === "app" ? "&source=app" : "") : ""}#token=${value}\n\n${intent ? "Après confirmation de votre adresse, vous recevrez votre lien personnel de téléchargement. La création du compte ne nécessite aucun paiement.\n\n" : ""}Si vous n’avez pas demandé ce lien, ignorez ce message.`,
              });
              if (!Array.isArray(delivered?.accepted) ||
                  !delivered.accepted.some((address) => normalizeEmail(address) === email) ||
                  delivered?.rejected?.length)
                throw Error("Authentication email recipient not accepted");
            } catch (error) {
              store.run("UPDATE magic_links SET used=1,expires=? WHERE hash=?", store.now(), digest(value));
              throw error;
            }
          }
          return { requested: true };
        },
      );
      api.post("/v1/auth/confirm", async (req, reply) => {
        if (req.headers.origin !== base.origin)
          return fail(reply, 403, "origin_mismatch");
        const value = req.body?.token;
        if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value))
          return fail(reply, 400, "invalid_link");
        const result = store.consumeMagic(value);
        if (!result) return fail(reply, 400, "expired_link");
        sessionCookie(reply, result.session);
        return {
          signedIn: true,
          ...(result.intent === "download" ? { intent: "download", download: await sendDownload(result.user, result.source) } : {}),
        };
      });
      api.post("/v1/auth/logout", async (req, reply) => {
        const user = auth(req, reply);
        if (!user) return;
        const value =
          req.headers.authorization?.slice(7) || req.cookies.pm_session;
        store.run("UPDATE sessions SET expires=0 WHERE hash=?", digest(value));
        reply.clearCookie("pm_session", { path: prefix || "/" });
        return { signedOut: true };
      });
      api.post(
        "/v1/device/start",
        { config: { rateLimit: { max: 10, timeWindow: 60000 } } },
        async (req, reply) => {
          const challenge = req.body?.challenge;
          if (!/^[a-f0-9]{64}$/.test(challenge || ""))
            return fail(reply, 400, "invalid_challenge");
          const label = String(req.body?.label || "Mac").slice(0, 60);
          return {
            ...store.device(label, challenge),
            verificationURL: url("/device"),
          };
        },
      );
      api.post("/v1/device/approve", async (req, reply) => {
        const user = accountBrowser(req, reply);
        if (!user) return;
        const code = String(req.body?.code || "")
          .toUpperCase()
          .replace(/\s/g, "");
        if (!/^[A-F0-9]{10}$/.test(code))
          return fail(reply, 400, "invalid_code");
        return store.approveDevice(code, user.id)
          ? { approved: true }
          : fail(reply, 400, "expired_or_used_code");
      });
      api.post("/v1/device/token", async (req, reply) => {
        const { deviceCode, verifier } = req.body || {};
        if (
          !/^[A-Za-z0-9_-]{43}$/.test(deviceCode || "") ||
          !/^[A-Za-z0-9_-]{43}$/.test(verifier || "")
        )
          return fail(reply, 400, "invalid_request");
        const result = store.exchangeDevice(deviceCode, verifier);
        return result.error
          ? fail(
              reply,
              result.error === "authorization_pending" ? 428 : 400,
              result.error,
            )
          : result;
      });
      api.get("/v1/me", async (req, reply) => {
        const user = auth(req, reply);
        if (!user) return;
        const entitlement = store.entitlement(user.id);
        return {
          id: user.id,
          email: user.email,
          hasPassword: !!store.get("SELECT user_id FROM password_credentials WHERE user_id=?", user.id),
          isAdmin:
            !user.device_id &&
            (config.adminEmails || []).includes(
              user.email,
            ),
          billingAvailable: !!user.stripe_customer,
          entitlement: entitlement
            ? {
                plan: entitlement.plan,
                until: entitlement.until,
                phase: entitlement.status,
              }
            : null,
          trialUsed: !!store.get(
            "SELECT user_id FROM trials WHERE user_id=?",
            user.id,
          ),
          devices: store.all(
            "SELECT id,label,created,revoked FROM devices WHERE user_id=?",
            user.id,
          ),
        };
      });
      api.post(
        "/v1/redeem",
        { config: { rateLimit: { max: 5, timeWindow: 3600000 } } },
        async (req, reply) => {
          const user = auth(req, reply);
          if (!user) return;
          if (user.device_id) return fail(reply, 403, "browser_required");
          return store.redeemOwnerCode(req.body?.code, user)
            ? { activated: true, plan: "lifetime" }
            : fail(reply, 400, "invalid_or_expired_code");
        },
      );
      api.post("/v1/devices/revoke", async (req, reply) => {
        const user = accountBrowser(req, reply);
        if (!user) return;
        store.run(
          "UPDATE devices SET revoked=1 WHERE id=? AND user_id=?",
          String(req.body?.id || ""),
          user.id,
        );
        return { revoked: true };
      });
      api.post("/v1/launch-ticket", async (req, reply) => {
        const user = auth(req, reply);
        if (!user) return;
        if (!user.device_id) return fail(reply, 403, "device_required");
        const access = store.entitlement(user.id);
        if (!access) return fail(reply, 402, "subscription_required");
        const networkGrant = networkPolicy.authorize(req, reply, user);
        if (!networkGrant) return;
        const issued = store.now(),
          expires = Math.min(issued + 900, access.until ?? issued + 900);
        const payload = Buffer.from(
          JSON.stringify({
            aud: "playmelt-desktop",
            sub: user.id,
            device: user.device_id,
            iat: issued,
            exp: expires,
            plan: access.plan,
            phase: access.status,
            capabilities: ["launch", "runtime.download"],
            ...networkGrant,
          }),
        ).toString("base64url");
        return {
          ticket:
            payload +
            "." +
            sign(null, Buffer.from(payload), config.signingKey).toString(
              "base64url",
            ),
          expiresAt: expires,
        };
      });
      api.post("/v1/checkout", async (req, reply) => {
        const user = accountBrowser(req, reply);
        if (!user) return;
        if (config.billingEnabled === false)
          return fail(reply, 503, "billing_not_ready");
        const plan = req.body?.plan;
        if (!plans[plan] || !/^price_/.test(config.prices[plan] || ""))
          return fail(reply, 400, "invalid_plan");
        if (store.entitlement(user.id))
          return fail(reply, 409, "already_subscribed");
        if (!config.termsVersion || !config.termsSHA256 || !config.termsURL)
          return fail(reply, 503, "legal_configuration_required");
        if (
          req.body?.acceptTerms !== true ||
          req.body?.termsVersion !== config.termsVersion
        )
          return fail(reply, 400, "terms_acceptance_required");
        let existing = store.get(
          "SELECT * FROM checkout_requests WHERE user_id=?",
          user.id,
        );
        if (existing?.expires > store.now()) {
          if (existing.plan !== plan)
            return fail(reply, 409, "checkout_pending");
          if (existing.url) return { url: existing.url };
        } else {
          store.run(
            "INSERT INTO checkout_requests VALUES(?,?,?,NULL,?) ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan,checkout_id=excluded.checkout_id,url=NULL,expires=excluded.expires",
            user.id,
            plan,
            "pending_" + randomUUID(),
            store.now() + 86400,
          );
          existing = store.get(
            "SELECT * FROM checkout_requests WHERE user_id=?",
            user.id,
          );
        }
        store.run(
          "INSERT OR IGNORE INTO checkout_terms VALUES(?,?,?,?,?)",
          existing.checkout_id,
          user.id,
          config.termsVersion,
          config.termsSHA256,
          store.now(),
        );
        try {
          let customer = user.stripe_customer;
          if (!customer) {
            const created = await stripe.customers.create(
              { email: user.email, metadata: { playmelt_user: user.id } },
              { idempotencyKey: "playmelt-customer-" + user.id },
            );
            customer = created.id;
            store.run(
              "UPDATE users SET stripe_customer=? WHERE id=?",
              customer,
              user.id,
            );
          }
          const session = await stripe.checkout.sessions.create(
            {
              customer,
              client_reference_id: user.id,
              mode: plan === "lifetime" ? "payment" : "subscription",
              payment_method_types: ["card"],
              allow_promotion_codes: true,
              ...(plan !== "lifetime"
                ? { payment_method_collection: "always" }
                : {}),
              line_items: [{ price: config.prices[plan], quantity: 1 }],
              success_url: url("/?checkout=complete"),
              cancel_url: url("/?checkout=cancelled"),
              billing_address_collection: "required",
              automatic_tax: { enabled: config.automaticTax === true },
              metadata: {
                playmelt_user: user.id,
                plan,
                terms_version: config.termsVersion,
                terms_sha256: config.termsSHA256,
              },
              ...(plan !== "lifetime"
                ? {
                    subscription_data: {
                      metadata: { playmelt_user: user.id, plan },
                      ...(!store.get(
                        "SELECT user_id FROM trials WHERE user_id=?",
                        user.id,
                      )
                        ? {
                            trial_period_days: 30,
                            trial_settings: {
                              end_behavior: {
                                missing_payment_method: "cancel",
                              },
                            },
                          }
                        : {}),
                    },
                  }
                : {}),
            },
            {
              idempotencyKey:
                "playmelt-checkout-" + user.id + "-" + existing.checkout_id,
            },
          );
          if (!session.url?.startsWith("https://checkout.stripe.com/"))
            throw Error("Invalid checkout URL");
          store.run(
            "UPDATE checkout_requests SET checkout_id=?,url=?,expires=? WHERE user_id=?",
            session.id,
            session.url,
            session.expires_at,
            user.id,
          );
          if (config.termsHTML) {
            const acceptance = store.get(
              "SELECT * FROM checkout_terms WHERE request_id=?",
              existing.checkout_id,
            );
            store.run(
              "INSERT OR IGNORE INTO checkout_contracts(checkout_id,user_id,plan,terms_sha256,accepted,updated) VALUES(?,?,?,?,?,?)",
              session.id,
              user.id,
              plan,
              acceptance.sha256,
              acceptance.accepted,
              store.now(),
            );
          }
          return { url: session.url };
        } catch (e) {
          throw e;
        } // Keep the idempotency key after an uncertain network outcome.
      });
      api.post("/v1/billing/portal", async (req, reply) => {
        const user = browser(req, reply);
        if (!user) return;
        if (!config.portalConfigurationID)
          return fail(reply, 503, "billing_portal_unavailable");
        if (!user.stripe_customer)
          return fail(reply, 400, "no_billing_account");
        let portal;
        try { portal = validatePortalConfiguration(await loadPortalConfiguration(stripe, config), config); }
        catch { return fail(reply, 503, "billing_portal_unavailable"); }
        const session = await stripe.billingPortal.sessions.create({
          customer: user.stripe_customer,
          configuration: portal.id,
          return_url: portal.returnURL,
        });
        if (!session.url?.startsWith("https://billing.stripe.com/"))
          throw Error("Invalid portal URL");
        return { url: session.url };
      });
      api.post(
        "/v1/stripe/webhook",
        { config: { rateLimit: { max: 500, timeWindow: 60000 } } },
        async (req, reply) => {
          if (config.billingEnabled === false)
            return fail(reply, 503, "billing_not_ready");
          let event;
          try {
            event = stripe.webhooks.constructEvent(
              req.rawBody,
              req.headers["stripe-signature"],
              config.webhookSecret,
              300,
            );
          } catch {
            return fail(reply, 400, "invalid_signature");
          }
          await processEvent(store, stripe, event, config);
          if (
            [
              "checkout.session.completed",
              "checkout.session.async_payment_succeeded",
            ].includes(event.type)
          )
            await sendContract(store, mailer, config, event.data.object.id);
          return { received: true };
        },
      );
      for (const route of ["/", "/confirm", "/device"])
        api.get(route, async (req, reply) =>
          reply
            .type("text/html")
            .send(
              readFileSync(
                new URL("../public/index.html", import.meta.url),
                "utf8",
              ).replaceAll("%%BASE%%", prefix).replaceAll("%%ENVIRONMENT_NOTICE%%",
                config.testAccountEmail ? '<p class="fine" role="note"><strong>Recette réservée à Nathan · Stripe en mode test · Aucun débit réel.</strong></p>' : ""),
            ),
        );
      api.get("/account.js", async (req, reply) =>
        reply
          .type("text/javascript")
          .send(readFileSync(new URL("../public/account.js", import.meta.url))),
      );
      api.get("/account.css", async (req, reply) =>
        reply
          .type("text/css")
          .send(
            readFileSync(new URL("../public/account.css", import.meta.url)),
          ),
      );
      if (updates) {
        const updateKey = config.testAccountEmail
          ? "update_release:isolated-test:" + digest(config.testAccountEmail)
          : "update_release:primary:stable";
        let retainedTuple = null;
        const activeDevice = ({ userID, deviceID }) => !!store.get(
          `SELECT 1 AS active FROM users u
           JOIN devices d ON d.user_id=u.id
           JOIN sessions s ON s.user_id=u.id AND s.device_id=d.id
           WHERE u.id=? AND d.id=? AND d.revoked=0 AND s.expires>? LIMIT 1`,
          userID, deviceID, store.now(),
        );
        await registerUpdateDelivery(api, {
          publicURL: config.publicURL,
          signingKey: config.signingKey,
          sparklePublicKey: updates.sparklePublicKey,
          channel: "stable", release: updates.release, artifact: updates.artifact,
          now: () => store.now(), activeDevice,
          authenticateDeviceBearer: (token) => {
            const user = store.authenticate(token);
            if (!user?.device_id || !activeDevice({ userID: user.id, deviceID: user.device_id })) return null;
            // Only a valid server-issued device session is accepted; cookies,
            // request-body identities and an active paid plan are not used here.
            return { userID: user.id, deviceID: user.device_id, verified: true };
          },
          openArtifact: () => openPinnedDownload(updates.artifact),
          artifactStillApproved: () => retainedTuple !== null &&
            store.get("SELECT value FROM service_state WHERE key=?", updateKey)?.value === retainedTuple,
          retainRelease: (tuple) => store.transaction(() => {
            pinDownloadRelease(store, config, artifact, true);
            const row = store.get("SELECT value FROM service_state WHERE key=?", updateKey);
            const previous = row ? JSON.parse(row.value) : null;
            validateUpdateTransition(previous, tuple);
            const value = JSON.stringify(tuple);
            if (!row || row.value !== value) store.run(
              "INSERT INTO service_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
              updateKey, value,
            );
            retainedTuple = value;
          }),
        });
      } else {
        const unavailable = (_req, reply) => fail(reply, 503, "updates_unavailable");
        api.post("/v1/updates/ticket", unavailable);
        api.get("/v1/updates/appcast.xml", unavailable);
        api.get("/v1/updates/archive/:build/:sha256/:filename", unavailable);
      }
    },
    { prefix },
  );
  // A candidate that fails account/legal/plugin initialization must not retire
  // the existing distribution. Pin only after those checks have succeeded.
  try { if (!updates) pinDownloadRelease(store, config, artifact); }
  catch (error) { await drainPasswordMail(); await networkPolicy?.drain(); await app.close(); throw error; }
  app.addHook("onClose", async () => {
    await drainPasswordMail();
    await networkPolicy?.drain();
    store.close();
  });
  return app;
}
