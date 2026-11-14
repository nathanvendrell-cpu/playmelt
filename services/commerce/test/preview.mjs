// Local-only QA fixture. Never part of the deployment manifest.
import { readFileSync, statSync } from "node:fs";
import { resolve, extname, sep } from "node:path";
import { generateKeyPairSync } from "node:crypto";
import { createApp } from "../src/app.mjs";
import { Store } from "../src/store.mjs";
import { plans } from "../src/billing.mjs";

const origin = "http://127.0.0.1:3097",
  site = resolve(process.env.PLAYMELT_QA_SITE);
let lastLink = null;
const config = {
  testing: true,
  publicURL: origin + "/Playmelt/compte",
  live: false,
  prices: Object.fromEntries(Object.keys(plans).map((p) => [p, "price_" + p])),
  signingKey: generateKeyPairSync("ed25519").privateKey,
  mailFrom: "fixture@example.test",
  supportEmail: "fixture@example.test",
  termsVersion: "2026-11-12",
  termsSHA256: "0".repeat(64),
  termsURL: origin + "/Playmelt/legal/conditions-de-vente/",
  privacyURL: origin + "/Playmelt/legal/confidentialite/",
};
const store = new Store(":memory:");
const stripe = {
  customers: { create: async () => ({ id: "cus_fixture" }) },
  checkout: {
    sessions: {
      create: async () => ({
        id: "cs_fixture",
        url: "https://checkout.stripe.com/c/pay/cs_fixture",
        expires_at: Math.floor(Date.now() / 1000) + 3600,
      }),
    },
  },
  billingPortal: {
    sessions: {
      create: async () => ({
        url: "https://billing.stripe.com/p/session/fixture",
      }),
    },
  },
};
const app = await createApp({
  store,
  stripe,
  config,
  mailer: {
    sendMail: async (mail) => {
      lastLink = mail.text.match(/http:\/\/[^\s]+/)?.[0];
      return { accepted: [mail.to] };
    },
  },
});
app.get("/__fixture__/mail", async () => ({ url: lastLink }));
app.get("/Playmelt/*", async (req, reply) => {
  const name = decodeURIComponent(
    req.url.split("?")[0].slice("/Playmelt/".length),
  );
  let path = resolve(site, name || ".");
  if (path !== site && !path.startsWith(site + sep))
    return reply.code(403).send("Forbidden");
  try {
    if (statSync(path).isDirectory()) path = resolve(path, "index.html");
    const type =
      {
        ".html": "text/html",
        ".css": "text/css",
        ".js": "text/javascript",
        ".json": "application/json",
        ".png": "image/png",
      }[extname(path)] || "application/octet-stream";
    return reply.type(type).send(readFileSync(path));
  } catch {
    return reply.code(404).send("Not found");
  }
});
for (const signal of ["SIGINT", "SIGTERM"])
  process.once(signal, async () => {
    await app.close();
    process.exit(0);
  });
await app.listen({ host: "127.0.0.1", port: 3097 });
console.log("Loopback-only fixture ready on 3097");
