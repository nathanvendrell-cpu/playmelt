import Stripe from "stripe";
import nodemailer from "nodemailer";
import { createPrivateKey } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { Store } from "./store.mjs";
import { plans } from "./billing.mjs";
import { validatePrice } from "./catalog.mjs";
import { validatePrivateStorage } from "./private-storage.mjs";
import { createApp } from "./app.mjs";
const requireEnv = (name) => {
  const value = process.env[name];
  if (!value) throw Error("Missing configuration: " + name);
  return value;
};
const mode = requireEnv("STRIPE_MODE");
if (!["test", "live"].includes(mode)) throw Error("Invalid Stripe mode");
const key = requireEnv("STRIPE_API_KEY");
if (!new RegExp("^(sk|rk)_" + mode + "_").test(key))
  throw Error("Stripe key/mode mismatch");
const db = requireEnv("PLAYMELT_DATABASE");
if (!db.startsWith("/"))
  throw Error("Database must use a private absolute path");
process.umask(0o077);
const signingPath = requireEnv("PLAYMELT_SIGNING_KEY_FILE");
validatePrivateStorage({
  root: requireEnv("PLAYMELT_PRIVATE_ROOT"),
  documentRoot: requireEnv("PLAYMELT_DOCUMENT_ROOT"),
  database: db,
  signingKey: signingPath,
});
if (!signingPath.startsWith("/") || (statSync(signingPath).mode & 0o077) !== 0)
  throw Error("Signing key must be a private absolute file");
const config = {
  publicURL: requireEnv("PLAYMELT_PUBLIC_URL"),
  live: mode === "live",
  webhookSecret: requireEnv("STRIPE_WEBHOOK_SECRET"),
  prices: Object.fromEntries(
    Object.keys(plans).map((id) => [
      id,
      requireEnv("STRIPE_PRICE_" + id.toUpperCase()),
    ]),
  ),
  signingKey: createPrivateKey(readFileSync(signingPath)),
  mailFrom: requireEnv("MAIL_FROM"),
  automaticTax: process.env.STRIPE_AUTOMATIC_TAX === "true",
};
config.termsVersion = requireEnv("PLAYMELT_TERMS_VERSION");
config.termsSHA256 = requireEnv("PLAYMELT_TERMS_SHA256");
config.termsURL = requireEnv("PLAYMELT_TERMS_URL");
config.privacyURL = requireEnv("PLAYMELT_PRIVACY_URL");
config.supportEmail = requireEnv("PLAYMELT_SUPPORT_EMAIL");
config.supportAdmins = (process.env.PLAYMELT_SUPPORT_ADMINS || "")
  .split(",")
  .map((x) => x.trim().toLowerCase())
  .filter(Boolean);
if (
  !/^[a-f0-9]{64}$/.test(config.termsSHA256) ||
  ![config.termsURL, config.privacyURL].every((value) => {
    const u = new URL(value);
    return (
      u.protocol === "https:" &&
      u.origin === new URL(config.publicURL).origin &&
      !u.username &&
      !u.password &&
      !u.hash
    );
  })
)
  throw Error("Invalid legal configuration");
if (config.signingKey.asymmetricKeyType !== "ed25519")
  throw Error("Ed25519 signing key required");
const stripe = new Stripe(key, {
  apiVersion: "2024-06-20",
  timeout: 15000,
  maxNetworkRetries: 2,
});
const mailer = nodemailer.createTransport({
  host: requireEnv("SMTP_HOST"),
  port: Number(process.env.SMTP_PORT || 465),
  secure: process.env.SMTP_PORT !== "587",
  requireTLS: true,
  disableFileAccess: true,
  disableUrlAccess: true,
  connectionTimeout: 10000,
  greetingTimeout: 10000,
  socketTimeout: 20000,
  auth: { user: requireEnv("SMTP_USER"), pass: requireEnv("SMTP_PASSWORD") },
});
await mailer.verify();
for (const [id, priceID] of Object.entries(config.prices))
  validatePrice(id, await stripe.prices.retrieve(priceID), config.live);
const app = await createApp({ store: new Store(db), stripe, mailer, config });
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    await app.close();
    process.exit(0);
  });
if (globalThis.PhusionPassenger) {
  globalThis.PhusionPassenger.configure({ autoInstall: false });
  await app.ready();
  app.server.listen("passenger");
} else
  await app.listen({
    host: "127.0.0.1",
    port: Number(process.env.PORT || 3080),
  });
console.log("Playmelt account service ready");
