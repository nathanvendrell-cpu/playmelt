import Fastify from "fastify";
import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import { randomUUID, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { digest } from "./store.mjs";
import { plans, processEvent } from "./billing.mjs";
import { registerSupport } from "./support.mjs";
import { normalizeEmail } from "./email.mjs";
export async function createApp({ store, stripe, mailer, config }) {
  const app = Fastify({
    logger: false,
    bodyLimit: 256 * 1024,
    trustProxy: config.trustProxy || false,
  });
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
    reply
      .code(code)
      .send({
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
  await app.register(
    async (api) => {
      registerSupport(api, { store, config, mailer, auth, fail });
      api.get("/health", async () => ({
        status: "ok",
        billingConfigured:
          !!config.webhookSecret &&
          Object.keys(plans).every((p) =>
            /^price_/.test(config.prices[p] || ""),
          ),
        mode: config.live ? "live" : "test",
      }));
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
          const recent = store.get(
            "SELECT COUNT(*) AS n FROM magic_links WHERE email=? AND expires>?",
            email,
            store.now(),
          );
          if (recent.n < 3) {
            const value = store.magic(email);
            await mailer.sendMail({
              from: config.mailFrom,
              to: { address: email },
              subject: "Votre connexion à Playmelt",
              text: `Connectez-vous à Playmelt avec ce lien, valable 15 minutes :\n\n${url("/confirm")}#token=${value}\n\nSi vous n’avez pas demandé ce lien, ignorez ce message.`,
            });
          }
          return { sent: true };
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
        return { signedIn: true };
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
        const user = auth(req, reply);
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
      api.post("/v1/devices/revoke", async (req, reply) => {
        const user = auth(req, reply);
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
        const user = auth(req, reply);
        if (!user) return;
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
          return { url: session.url };
        } catch (e) {
          throw e;
        } // Keep the idempotency key after an uncertain network outcome.
      });
      api.post("/v1/billing/portal", async (req, reply) => {
        const user = auth(req, reply);
        if (!user) return;
        if (!user.stripe_customer)
          return fail(reply, 400, "no_billing_account");
        const session = await stripe.billingPortal.sessions.create({
          customer: user.stripe_customer,
          return_url: url("/"),
        });
        if (!session.url?.startsWith("https://billing.stripe.com/"))
          throw Error("Invalid portal URL");
        return { url: session.url };
      });
      api.post(
        "/v1/stripe/webhook",
        { config: { rateLimit: { max: 500, timeWindow: 60000 } } },
        async (req, reply) => {
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
              ).replaceAll("%%BASE%%", prefix),
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
    },
    { prefix },
  );
  app.addHook("onClose", async () => store.close());
  return app;
}
