import { randomUUID } from "node:crypto";
import { normalizeEmail } from "./email.mjs";
import { digest, token } from "./store.mjs";
import { hashPassword, verifyPassword, validNewPassword, validLoginPassword } from "./passwords.mjs";

export function registerPasswordAuth(api, { store, config, mailer, browser, sessionCookie, url, fail, origin }) {
  const generic = () => ({ requested: true });
  const deliveries = new Set();
  // Do not make the public response depend on whether a mailbox exists or on SMTP latency.
  // Delivery jobs are bounded and drained before the database is closed.
  const send = (message, failed) => {
    const job = Promise.resolve().then(() => mailer.sendMail(message)).then((result) => {
      const accepted = Array.isArray(result?.accepted) && result.accepted.some((address) => normalizeEmail(address) === message.to.address);
      if (!accepted || result?.rejected?.length) failed();
    }, failed).finally(() => deliveries.delete(job));
    deliveries.add(job);
    void job.catch(() => {}); // onClose still observes completion; no unhandled background rejection.
  };
  const mailLimit = (reply) => {
    if (deliveries.size < 8) return false;
    reply.header("Retry-After", "20");
    fail(reply, 429, "too_many_requests");
    return true;
  };
  const credential = (id) => store.get("SELECT * FROM password_credentials WHERE user_id=?", id);
  const sameOrigin = (req, reply) => req.headers.origin === origin || (fail(reply, 403, "origin_mismatch"), false);
  const limited = { config: { rateLimit: { max: 5, timeWindow: 15 * 60000 } } };
  const loginLimit = { config: { rateLimit: { max: 20, timeWindow: 60000 } } };
  const busy = (reply, error) => {
    if (error.code !== "AUTH_BUSY") throw error;
    reply.header("Retry-After", "2");
    return fail(reply, 429, "too_many_requests");
  };
  const recovery = (user, intent = "", source = "site") => {
    if (store.get("SELECT COUNT(*) AS n FROM password_resets WHERE user_id=? AND used=0 AND expires>?", user.id, store.now()).n >= 3) return;
    const value = token();
    store.run("INSERT INTO password_resets VALUES(?,?,?,0)", digest(value), user.id, store.now() + 900);
    const query = intent === "download" ? "?intent=download&source=" + source : "";
    send({ from: config.mailFrom, to: { address: user.email }, subject: "Réinitialiser votre mot de passe Playmelt",
      text: `Pour retrouver votre compte et choisir un nouveau mot de passe Playmelt, ouvrez ce lien valable 15 minutes :\n\n${url("/")}${query}#reset=${value}\n\nSi vous venez de demander une inscription, un compte existe déjà avec cette adresse. Aucun mot de passe ni accès n’a été changé.\n\nLa validation du nouveau mot de passe ferme les sessions Playmelt existantes. Elle ne supprime ni votre licence, ni vos jeux, ni vos connexions Steam, Xbox ou Epic. Si vous n’avez pas demandé ce changement, ignorez ce message.` },
    () => store.run("UPDATE password_resets SET used=1 WHERE hash=?", digest(value)));
  };
  async function login(req, reply, device) {
    if (device ? req.headers.origin && req.headers.origin !== origin : req.headers.origin !== origin)
      return fail(reply, 403, "origin_mismatch");
    const email = normalizeEmail(req.body?.email), password = req.body?.password;
    const label = req.body?.label ?? "Playmelt sur Mac";
    if (!email || !validLoginPassword(password) || (device && (typeof label !== "string" || label.length > 60 || /[\x00-\x1f\x7f]/.test(label))))
      return fail(reply, 400, "invalid_request");
    const user = store.get("SELECT * FROM users WHERE email=?", email);
    const identifier = digest(email);
    // Only short-lived derived counters; never an IP or a plaintext unknown email.
    store.run("DELETE FROM login_throttles WHERE started<=?", store.now() - 900);
    const attempt = store.get("SELECT * FROM login_throttles WHERE identifier=?", identifier);
    if (!attempt && store.get("SELECT COUNT(*) AS n FROM login_throttles").n >= 10000) {
      reply.header("Retry-After", "60");
      return fail(reply, 429, "too_many_requests");
    }
    if (attempt && attempt.started > store.now() - 900 && attempt.failures >= 8) {
      reply.header("Retry-After", String(Math.max(1, attempt.started + 900 - store.now())));
      return fail(reply, 429, "too_many_requests");
    }
    const saved = user && credential(user.id);
    let valid;
    try { valid = await verifyPassword(password, saved?.hash); }
    catch (error) { return busy(reply, error); }
    if (!valid || (config.testAccountEmail && email !== config.testAccountEmail)) {
      store.run(
        "INSERT INTO login_throttles VALUES(?,?,1) ON CONFLICT(identifier) DO UPDATE SET failures=failures+1",
        identifier, store.now(),
      );
      return fail(reply, 401, "invalid_credentials");
    }
    return store.transaction(() => {
      if (credential(user.id)?.hash !== saved.hash) return fail(reply, 401, "invalid_credentials");
      store.run("UPDATE login_throttles SET failures=0,started=? WHERE identifier=?", store.now(), identifier);
      store.recordLogin(user.id);
      if (!device) {
        sessionCookie(reply, store.session(user.id));
        return { signedIn: true };
      }
      const deviceID = randomUUID();
      store.run("INSERT INTO devices(id,user_id,label,created) VALUES(?,?,?,?)", deviceID, user.id, label.trim() || "Playmelt sur Mac", store.now());
      store.run("INSERT INTO user_activity(user_id,last_pair) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_pair=excluded.last_pair", user.id, store.now());
      return { token: store.session(user.id, deviceID), deviceID, expiresIn: 30 * 86400 };
    });
  }
  api.post("/v1/auth/login", loginLimit, (req, reply) => login(req, reply, false));
  api.post("/v1/auth/device-login", loginLimit, (req, reply) => login(req, reply, true));

  api.post("/v1/auth/register", limited, async (req, reply) => {
    if (!sameOrigin(req, reply)) return;
    const email = normalizeEmail(req.body?.email), password = req.body?.password;
    if (!email) return fail(reply, 400, "invalid_email");
    if (!validNewPassword(password)) return fail(reply, 400, "invalid_password");
    if (mailLimit(reply)) return;
    if (config.testAccountEmail && email !== config.testAccountEmail) return generic();
    const intent = req.body?.intent || "", source = req.body?.source || "site";
    if (!["", "download"].includes(intent) || !["site", "app"].includes(source)) return fail(reply, 400, "invalid_request");
    const existing = store.get("SELECT id,email FROM users WHERE email=?", email);
    // Registration can never assign a password to an existing account.
    // Give its owner a verified recovery path instead of silently discarding the request.
    if (existing) {
      try { await verifyPassword(password, null); } catch (e) { return busy(reply, e); }
      recovery(existing, intent, source);
      return generic();
    }
    let hash;
    try { hash = await hashPassword(password); } catch (error) { return busy(reply, error); }
    const value = store.transaction(() => {
      // Only the newest registration password should be confirmed. Old mail must
      // not create a session whose password differs from the latest request.
      store.run("UPDATE password_registrations SET password_hash='' WHERE magic_hash IN (SELECT hash FROM magic_links WHERE email=? AND used=0)", email);
      store.run("UPDATE magic_links SET used=1 WHERE email=? AND used=0 AND hash IN (SELECT magic_hash FROM password_registrations)", email);
      const value = store.magic(email, intent, source);
      store.run("INSERT INTO password_registrations VALUES(?,?)", digest(value), hash);
      return value;
    });
    const query = intent === "download" ? "?intent=download&source=" + source : "";
    send({ from: config.mailFrom, to: { address: email }, subject: "Confirmez la création de votre compte Playmelt",
        text: `Vous avez demandé la création d’un compte Playmelt et choisi un mot de passe. Confirmez votre adresse avec ce lien, valable 15 minutes :\n\n${url("/confirm")}${query}#token=${value}\n\nSi vous n’avez pas vous-même choisi ce mot de passe et demandé ce compte, n’ouvrez pas ce lien et ignorez ce message.`
    }, () => {
      store.run("UPDATE magic_links SET used=1 WHERE hash=?", digest(value));
      store.run("UPDATE password_registrations SET password_hash='' WHERE magic_hash=?", digest(value));
    });
    return generic();
  });
  api.post("/v1/auth/password", limited, async (req, reply) => {
    const user = browser(req, reply);
    if (!user) return;
    const password = req.body?.password;
    if (!validNewPassword(password)) return fail(reply, 400, "invalid_password");
    const previous = credential(user.id);
    try {
      if (previous && !await verifyPassword(req.body?.currentPassword, previous.hash)) return fail(reply, 401, "invalid_credentials");
      const hash = await hashPassword(password);
      return store.transaction(() => {
        const changed = previous
          ? store.run("UPDATE password_credentials SET hash=?,updated=? WHERE user_id=? AND hash=?", hash, store.now(), user.id, previous.hash)
          : store.run("INSERT OR IGNORE INTO password_credentials VALUES(?,?,?)", user.id, hash, store.now());
        if (changed.changes !== 1) return fail(reply, 409, "retry_required");
        store.run("UPDATE password_resets SET used=1 WHERE user_id=?", user.id);
        return { changed: true };
      });
    } catch (error) { return busy(reply, error); }
  });
  api.post("/v1/auth/password/reset", limited, async (req, reply) => {
    if (!sameOrigin(req, reply)) return;
    const email = normalizeEmail(req.body?.email);
    if (!email) return fail(reply, 400, "invalid_email");
    if (mailLimit(reply)) return;
    const intent = req.body?.intent || "", source = req.body?.source || "site";
    if (!["", "download"].includes(intent) || !["site", "app"].includes(source)) return fail(reply, 400, "invalid_request");
    const user = store.get("SELECT id,email FROM users WHERE email=?", email);
    if (!user || (config.testAccountEmail && email !== config.testAccountEmail)) return generic();
    recovery(user, intent, source);
    return generic();
  });
  api.post("/v1/auth/password/reset/confirm", limited, async (req, reply) => {
    if (!sameOrigin(req, reply)) return;
    const value = req.body?.token, password = req.body?.password;
    if (!/^[A-Za-z0-9_-]{43}$/.test(value || "") || !validNewPassword(password)) return fail(reply, 400, "invalid_password");
    const reset = store.get("SELECT * FROM password_resets WHERE hash=? AND used=0 AND expires>?", digest(value), store.now());
    if (!reset) return fail(reply, 400, "expired_link");
    let hash;
    try { hash = await hashPassword(password); } catch (error) { return busy(reply, error); }
    return store.transaction(() => {
      const changed = store.run("UPDATE password_resets SET used=1 WHERE hash=? AND used=0 AND expires>?", digest(value), store.now());
      if (!changed.changes) return fail(reply, 400, "expired_link");
      store.run("UPDATE password_resets SET used=1 WHERE user_id=?", reset.user_id);
      const user = store.get("SELECT email FROM users WHERE id=?", reset.user_id);
      store.run("UPDATE magic_links SET used=1 WHERE email=?", user.email);
      store.run("UPDATE password_registrations SET password_hash='' WHERE magic_hash IN (SELECT hash FROM magic_links WHERE email=?)", user.email);
      store.run("UPDATE device_requests SET used=1 WHERE user_id=?", reset.user_id);
      store.run("DELETE FROM google_native_grants WHERE user_id=?", reset.user_id);
      store.run("INSERT INTO password_credentials VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET hash=excluded.hash,updated=excluded.updated", reset.user_id, hash, store.now());
      store.run("UPDATE sessions SET expires=0 WHERE user_id=?", reset.user_id);
      store.run("UPDATE devices SET revoked=1 WHERE user_id=?", reset.user_id);
      store.run("UPDATE login_throttles SET failures=0,started=? WHERE identifier=?", store.now(), digest(user.email));
      sessionCookie(reply, store.session(reset.user_id));
      return { changed: true };
    });
  });
  return async () => { await Promise.allSettled([...deliveries]); };
}
