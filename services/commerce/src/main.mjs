import Stripe from "stripe";
import nodemailer from "nodemailer";
import { createPrivateKey } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { Store } from "./store.mjs";
import { plans } from "./billing.mjs";
import { validatePrice } from "./catalog.mjs";
import { validatePrivateStorage } from "./private-storage.mjs";
import { createApp } from "./app.mjs";
import { mailTransportOptions } from "./mail-transport.mjs";
import { normalizeEmail } from "./email.mjs";
import { loadGoogleOAuth } from "./google-config.mjs";
import { loadPortalConfiguration } from "./portal-config.mjs";
import { loadNetworkPolicy } from "./network-policy.mjs";
const requireEnv = (name) => {
  const value = process.env[name];
  if (!value) throw Error("Missing configuration: " + name);
  return value;
};
const mode = requireEnv("STRIPE_MODE");
const billingEnabled = process.env.PLAYMELT_BILLING_VERIFIED === "1";
if (!["test", "live"].includes(mode)) throw Error("Invalid Stripe mode");
const key = requireEnv("STRIPE_API_KEY");
if (!new RegExp("^rk_" + mode + "_").test(key))
  throw Error("Mode-matching restricted Stripe key required");
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
  billingEnabled,
  portalConfigurationID: billingEnabled
    ? requireEnv("STRIPE_PORTAL_CONFIGURATION")
    : process.env.STRIPE_PORTAL_CONFIGURATION || "",
  release: process.env.PLAYMELT_RELEASE || "development",
  webhookSecret: billingEnabled
    ? requireEnv("STRIPE_WEBHOOK_SECRET")
    : process.env.STRIPE_WEBHOOK_SECRET || "",
  prices: Object.fromEntries(
    Object.keys(plans).map((id) => [
      id,
      billingEnabled
        ? requireEnv("STRIPE_PRICE_" + id.toUpperCase())
        : process.env["STRIPE_PRICE_" + id.toUpperCase()] || "",
    ]),
  ),
  signingKey: createPrivateKey(readFileSync(signingPath)),
  mailFrom: requireEnv("MAIL_FROM"),
  automaticTax: process.env.STRIPE_AUTOMATIC_TAX === "true",
};
Object.assign(config, loadGoogleOAuth(process.env.PLAYMELT_GOOGLE_OAUTH_FILE, {
  privateRoot: requireEnv("PLAYMELT_PRIVATE_ROOT"), publicURL: config.publicURL,
}));
Object.assign(config, loadNetworkPolicy(process.env, {
  privateRoot: requireEnv("PLAYMELT_PRIVATE_ROOT"), documentRoot: requireEnv("PLAYMELT_DOCUMENT_ROOT"), signingKeyFile: signingPath,
}));
if (process.env.PLAYMELT_TEST_ACCOUNT_EMAIL) {
  config.testAccountEmail = normalizeEmail(process.env.PLAYMELT_TEST_ACCOUNT_EMAIL);
  if (mode !== "test" || !config.testAccountEmail)
    throw Error("Isolated test account requires test mode");
}
config.termsVersion = requireEnv("PLAYMELT_TERMS_VERSION");
config.termsSHA256 = requireEnv("PLAYMELT_TERMS_SHA256");
config.termsHTML = readFileSync(requireEnv("PLAYMELT_TERMS_FILE"), "utf8");
config.termsURL = requireEnv("PLAYMELT_TERMS_URL");
config.privacyURL = requireEnv("PLAYMELT_PRIVACY_URL");
config.supportEmail = requireEnv("PLAYMELT_SUPPORT_EMAIL");
config.internalEmails = (process.env.PLAYMELT_INTERNAL_EMAILS || process.env.PLAYMELT_OWNER_EMAIL || "")
  .split(",").map((value) => normalizeEmail(value)).filter(Boolean);
config.supportAdmins = (process.env.PLAYMELT_SUPPORT_ADMINS || "")
  .split(",")
  .map((x) => x.trim().toLowerCase())
  .filter(Boolean);
config.adminEmails = (process.env.PLAYMELT_ADMINS || "")
  .split(",")
  .map((x) => x.trim().toLowerCase())
  .filter(Boolean);
// Pin the exact approved package, independently of the service release string.
// Commercial billing requires 2.2.0. Legacy 2.1.0 remains available only before
// promotion and with billing disabled. No public/CDN fallback is permitted.
config.downloadFile = process.env.PLAYMELT_DOWNLOAD_FILE || "";
config.updateManifestFile = process.env.PLAYMELT_UPDATE_MANIFEST_FILE || "";
config.privateRoot = process.env.PLAYMELT_PRIVATE_ROOT;
config.documentRoot = process.env.PLAYMELT_DOCUMENT_ROOT;
if (config.downloadFile) {
  config.downloadVersion = requireEnv("PLAYMELT_DOWNLOAD_VERSION");
  config.downloadFilename = requireEnv("PLAYMELT_DOWNLOAD_FILENAME");
  config.downloadSHA256 = requireEnv("PLAYMELT_DOWNLOAD_SHA256");
  config.downloadSize = Number(requireEnv("PLAYMELT_DOWNLOAD_BYTES"));
}
if (billingEnabled && mode === "live" && !config.downloadFile)
  throw Error("Live commercial billing requires a configured private client package");
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
await loadPortalConfiguration(stripe, config);
const mailTransport = nodemailer.createTransport(mailTransportOptions(process.env));
await mailTransport.verify();
const mailer = config.testAccountEmail ? {
  sendMail(message) {
    const recipient = typeof message.to === "string" ? message.to : message.to?.address;
    if (normalizeEmail(recipient) !== config.testAccountEmail)
      throw Error("Recipient is outside the isolated test account");
    return mailTransport.sendMail({ ...message, subject: "[TEST — aucun débit réel] " + message.subject });
  },
} : mailTransport;
if (billingEnabled)
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
// Passenger binds this single HTTP server to its private socket automatically.
// Keeping Fastify's normal listen lifecycle also awaits startup errors.
await app.listen({
  host: "127.0.0.1",
  port: Number(process.env.PORT || 3080),
});
console.log("Playmelt account service ready");
