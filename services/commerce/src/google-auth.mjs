import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { OAuth2Client } from "google-auth-library";
import { normalizeEmail } from "./email.mjs";
import { digest, token } from "./store.mjs";

const opaque = (value) => typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
const verifierOK = (value) => typeof value === "string" && /^[A-Za-z0-9._~-]{43,128}$/.test(value);
const challengeOf = (value) => createHash("sha256").update(value).digest("base64url");
const sameHash = (a, b) => typeof a === "string" && typeof b === "string" &&
  a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const object = (body) => body !== null && typeof body === "object" && !Array.isArray(body);
const keysOnly = (body, keys) => object(body) && Object.keys(body).every((key) => keys.includes(key));
const issuers = new Set(["accounts.google.com", "https://accounts.google.com"]);

export function googleConfigured(config) {
  return typeof config.googleClientID === "string" &&
    /^[A-Za-z0-9_-]{6,200}\.apps\.googleusercontent\.com$/.test(config.googleClientID) &&
    typeof config.googleClientSecret === "string" && /^[A-Za-z0-9_-]{16,256}$/.test(config.googleClientSecret);
}

// verifyIdToken performs signature verification with Google's keys. These checks
// bind that verified token to this request, including strict expiry and nonce.
export function validateGoogleClaims(payload, { audience, nonceHash, now }) {
  if (!object(payload) || !issuers.has(payload.iss) || payload.aud !== audience ||
      !Number.isSafeInteger(payload.exp) || payload.exp <= now ||
      !Number.isSafeInteger(payload.iat) || payload.iat > now + 300 || payload.exp <= payload.iat ||
      typeof payload.sub !== "string" || !/^[\x21-\x7e]{1,255}$/.test(payload.sub) ||
      payload.email_verified !== true || typeof payload.nonce !== "string" ||
      !sameHash(digest(payload.nonce), nonceHash) ||
      (payload.azp !== undefined && payload.azp !== audience)) throw Error("Invalid Google identity");
  const email = normalizeEmail(payload.email);
  if (!email) throw Error("Invalid Google identity");
  const hostedDomain = typeof payload.hd === "string" && payload.hd.length <= 253 &&
    normalizeEmail("member@" + payload.hd)?.split("@")[1];
  return { subject: payload.sub, email, authoritative: email.endsWith("@gmail.com") || !!hostedDomain };
}

function identify(store, identity, config) {
  let user = store.get("SELECT u.* FROM oauth_identities i JOIN users u ON u.id=i.user_id WHERE i.provider='google' AND i.subject=?", identity.subject);
  if (user) {
    if (config.testAccountEmail && user.email !== config.testAccountEmail) return null;
    return user; // Stable subject wins; never rename or promote from new claims.
  }
  if (!identity.authoritative) return null;
  if (config.testAccountEmail && identity.email !== config.testAccountEmail) return null;
  user = store.get("SELECT * FROM users WHERE email=?", identity.email);
  if (user && store.get("SELECT subject FROM oauth_identities WHERE provider='google' AND user_id=?", user.id)) return null;
  if (!user) {
    const id = randomUUID(), internal = store.internalEmails.has(identity.email) ? 1 : 0;
    store.run("INSERT INTO users(id,email,created,is_internal) VALUES(?,?,?,?)", id, identity.email, store.now(), internal);
    if (!internal) store.activity("account_created", "account");
    user = store.get("SELECT * FROM users WHERE id=?", id);
  }
  store.run("INSERT INTO oauth_identities VALUES('google',?,?,?)", identity.subject, user.id, store.now());
  return user;
}

export function registerGoogleAuth(api, { store, config, sessionCookie, url, fail, origin, prefix }) {
  const callbackURL = url("/v1/auth/google/callback");
  const cookiePath = prefix + "/v1/auth/google";
  const cookie = { httpOnly: true, secure: !config.testing, sameSite: "lax", path: cookiePath, maxAge: 600 };
  const enabled = googleConfigured(config);
  // Test injection cannot replace the official client in a production process.
  const client = enabled ? config.testing && config.googleOAuthClient
    ? config.googleOAuthClient
    : new OAuth2Client({ clientId: config.googleClientID, clientSecret: config.googleClientSecret,
        redirectUri: callbackURL, transporterOptions: { timeout: 10000, retry: false } }) : null;
  const prune = () => store.transaction(() => {
    store.run("DELETE FROM google_oauth_states WHERE expires<=?", store.now());
    store.run("DELETE FROM google_native_requests WHERE expires<=? AND NOT EXISTS(SELECT 1 FROM google_oauth_states s WHERE s.native_hash=google_native_requests.hash)", store.now());
    store.run("DELETE FROM google_native_grants WHERE expires<=?", store.now());
  });
  prune();
  const allowedOrigin = (req, reply) => !req.headers.origin || req.headers.origin === origin ||
    (fail(reply, 403, "origin_mismatch"), false);
  const ready = (reply) => enabled || (fail(reply, 503, "oauth_unavailable"), false);
  const webLocation = (state, error) => {
    const result = new URL(url("/"));
    result.searchParams.set(error ? "authError" : "auth", error || "google");
    if (state?.intent === "download") {
      result.searchParams.set("intent", "download");
      result.searchParams.set("source", state.source);
    }
    return result.href;
  };
  const nativeLocation = (native, error, code) => {
    const result = new URL("playmelt://account/google");
    result.searchParams.set(error ? "error" : "code", error || code);
    result.searchParams.set("state", native.state);
    return result.href;
  };
  const redirectError = (reply, state, native, error) => reply.code(303)
    .header("Location", native ? nativeLocation(native, error) : webLocation(state, error)).send();
  const limited = { config: { rateLimit: { max: 15, timeWindow: 60000 } } };

  api.get("/v1/auth/providers", async () => { prune(); return { google: enabled }; });
  api.post("/v1/auth/google/native/start", limited, async (req, reply) => {
    if (!allowedOrigin(req, reply) || !ready(reply)) return;
    prune();
    if (!keysOnly(req.body, ["challenge", "state"]) || !opaque(req.body.challenge) || !opaque(req.body.state))
      return fail(reply, 400, "invalid_request");
    const request = token();
    store.run("INSERT INTO google_native_requests VALUES(?,?,?,?,NULL)", digest(request), req.body.challenge, req.body.state, store.now() + 600);
    return { url: url("/v1/auth/google/start") + "?native=" + request };
  });
  api.get("/v1/auth/google/start", limited, async (req, reply) => {
    if (!allowedOrigin(req, reply) || !ready(reply)) return;
    if (req.method !== "GET") return fail(reply, 405, "get_required");
    prune();
    const query = req.query || {};
    if (!keysOnly(query, ["intent", "source", "native"]) ||
        !["", "download"].includes(query.intent ?? "") || !["site", "app"].includes(query.source ?? "site") ||
        (query.native !== undefined && (!opaque(query.native) || query.intent !== undefined || query.source !== undefined)))
      return fail(reply, 400, "invalid_request");
    if (!query.native && req.headers["sec-fetch-site"] === "cross-site") return fail(reply, 403, "origin_mismatch");
    let native = null;
    if (query.native) {
      native = store.get("SELECT * FROM google_native_requests WHERE hash=? AND expires>? AND started IS NULL", digest(query.native), store.now());
      if (!native) return fail(reply, 400, "invalid_request");
    }
    const state = token(), binding = token(), nonce = token();
    const { codeVerifier, codeChallenge } = await client.generateCodeVerifierAsync();
    if (!verifierOK(codeVerifier) || !opaque(codeChallenge) || !sameHash(challengeOf(codeVerifier), codeChallenge))
      throw Error("Invalid PKCE challenge");
    const location = client.generateAuthUrl({
      redirect_uri: callbackURL, response_type: "code", scope: ["openid", "email"],
      access_type: "online", state, nonce, code_challenge: codeChallenge, code_challenge_method: "S256",
    });
    if (new URL(location).origin !== "https://accounts.google.com") throw Error("Invalid OAuth endpoint");
    const saved = store.transaction(() => {
      if (native && !store.run("UPDATE google_native_requests SET started=? WHERE hash=? AND started IS NULL AND expires>?", store.now(), native.hash, store.now()).changes) return false;
      store.run("INSERT INTO google_oauth_states VALUES(?,?,?,?,?,?,?,?)", digest(state), digest(binding), digest(nonce), codeVerifier,
        native ? Math.min(native.expires, store.now() + 600) : store.now() + 600,
        query.intent || "", query.source || "site", native?.hash || null);
      return true;
    });
    if (!saved) return fail(reply, 400, "invalid_request");
    reply.setCookie("pm_google_state", binding, cookie);
    return reply.code(303).header("Location", location).send();
  });
  api.get("/v1/auth/google/callback", limited, async (req, reply) => {
    if (!allowedOrigin(req, reply)) return;
    if (req.method !== "GET") return fail(reply, 405, "get_required");
    prune();
    const query = req.query || {}, binding = req.cookies.pm_google_state;
    if (!opaque(query.state) || !opaque(binding)) return redirectError(reply, null, null, "oauth_failed");
    const claimed = store.transaction(() => {
      const state = store.get("SELECT * FROM google_oauth_states WHERE hash=? AND browser_hash=? AND expires>?", digest(query.state), digest(binding), store.now());
      if (!state) return null;
      const native = state.native_hash ? store.get("SELECT * FROM google_native_requests WHERE hash=? AND expires>?", state.native_hash, store.now()) : null;
      store.run("DELETE FROM google_oauth_states WHERE hash=?", state.hash);
      if (state.native_hash) store.run("DELETE FROM google_native_requests WHERE hash=?", state.native_hash);
      return { state, native };
    });
    if (!claimed) return redirectError(reply, null, null, "oauth_failed");
    reply.clearCookie("pm_google_state", { ...cookie, maxAge: 0 });
    const { state, native } = claimed;
    if (state.native_hash && !native) return redirectError(reply, state, null, "oauth_failed");
    if (!enabled) return redirectError(reply, state, native, "oauth_unavailable");
    if (query.error !== undefined) return redirectError(reply, state, native, query.error === "access_denied" ? "oauth_cancelled" : "oauth_failed");
    if (typeof query.code !== "string" || query.code.length < 1 || query.code.length > 4096 || /[\x00-\x20\x7f]/.test(query.code))
      return redirectError(reply, state, native, "oauth_failed");
    try {
      const exchanged = await client.getToken({ code: query.code, codeVerifier: state.verifier, redirect_uri: callbackURL });
      const idToken = exchanged.tokens?.id_token;
      if (typeof idToken !== "string" || idToken.length > 16384) throw Error("Missing ID token");
      const ticket = await client.verifyIdToken({ idToken, audience: config.googleClientID });
      const identity = validateGoogleClaims(ticket.getPayload(), { audience: config.googleClientID, nonceHash: state.nonce_hash, now: store.now() });
      const result = store.transaction(() => {
        const user = identify(store, identity, config);
        if (!user) return null;
        if (native) {
          const code = token();
          store.run("INSERT INTO google_native_grants VALUES(?,?,?,?)", digest(code), user.id, native.challenge, store.now() + 60);
          return { code };
        }
        store.recordLogin(user.id);
        return { session: store.session(user.id) };
      });
      if (!result) return redirectError(reply, state, native, "account_link_required");
      if (native) return reply.code(303).header("Location", nativeLocation(native, null, result.code)).send();
      sessionCookie(reply, result.session);
      return reply.code(303).header("Location", webLocation(state)).send();
    } catch {
      // Official library errors can include token bodies or client credentials.
      // Never log, persist, echo or interpolate them into a redirect.
      return redirectError(reply, state, native, "oauth_failed");
    }
  });
  api.post("/v1/auth/google/native/exchange", limited, async (req, reply) => {
    if (!allowedOrigin(req, reply) || !ready(reply)) return;
    prune();
    const body = req.body, label = body?.label ?? "Playmelt sur Mac";
    if (!keysOnly(body, ["code", "verifier", "label"]) || !opaque(body.code) || !verifierOK(body.verifier) ||
        typeof label !== "string" || label.length > 60 || /[\x00-\x1f\x7f]/.test(label)) return fail(reply, 400, "invalid_request");
    const result = store.transaction(() => {
      const grant = store.get("SELECT * FROM google_native_grants WHERE hash=? AND expires>?", digest(body.code), store.now());
      if (!grant || !sameHash(grant.challenge, challengeOf(body.verifier))) return null;
      store.run("DELETE FROM google_native_grants WHERE hash=?", grant.hash);
      const deviceID = randomUUID();
      store.run("INSERT INTO devices(id,user_id,label,created) VALUES(?,?,?,?)", deviceID, grant.user_id, label.trim() || "Playmelt sur Mac", store.now());
      store.run("INSERT INTO user_activity(user_id,last_pair) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_pair=excluded.last_pair", grant.user_id, store.now());
      store.activity("device_paired", "app");
      store.recordLogin(grant.user_id);
      return { token: store.session(grant.user_id, deviceID), deviceID, expiresIn: 30 * 86400 };
    });
    return result || fail(reply, 401, "invalid_grant");
  });
}
