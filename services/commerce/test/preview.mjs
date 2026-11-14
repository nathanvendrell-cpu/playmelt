// Local-only QA fixture. Never part of the deployment manifest.
import { readFileSync, statSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { resolve, extname, sep } from "node:path";
import { generateKeyPairSync, createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { createApp } from "../src/app.mjs";
import { Store } from "../src/store.mjs";
import { plans } from "../src/billing.mjs";

const port = Number(process.env.PLAYMELT_QA_PORT || 3097);
if (!Number.isSafeInteger(port) || port < 1024 || port > 65535)
  throw Error("Invalid QA port");
const origin = "http://127.0.0.1:" + port,
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
  supportAdmins: ["owner@example.test"],
  adminEmails: ["owner@example.test"],
  githubFetch: async () => ({
    ok: true,
    headers: new Headers(),
    text: async () =>
      JSON.stringify([
        {
          tag_name: "v2.1.0",
          assets: [{ id: 1, name: "Playmelt-2.1.0.dmg", download_count: 53 }],
        },
        {
          tag_name: "v2.0.0",
          assets: [{ id: 2, name: "Playmelt-2.0.0.dmg", download_count: 22 }],
        },
      ]),
  }),
};
const store = new Store(":memory:");
let downloadDirectory;
if (process.env.PLAYMELT_QA_DOWNLOAD === "1") {
  downloadDirectory = mkdtempSync(resolve(tmpdir(), "playmelt-browser-download-"));
  const bytes = Buffer.from("Playmelt local browser download fixture\n");
  config.privateRoot = downloadDirectory;
  config.documentRoot = site;
  config.downloadFile = resolve(downloadDirectory, "Playmelt-2.1.0.dmg");
  config.downloadVersion = "2.1.0";
  config.downloadFilename = "Playmelt-2.1.0.dmg";
  config.downloadSHA256 = createHash("sha256").update(bytes).digest("hex");
  config.downloadSize = bytes.length;
  writeFileSync(config.downloadFile, bytes, { mode: 0o600 });
  process.once("exit", () => rmSync(downloadDirectory, { recursive: true, force: true }));
}
if (process.env.PLAYMELT_QA_ADMIN === "1") {
  const realNow = store.now,
    now = realNow(),
    day = 86400,
    start = now - 17 * day;
  store.run(
    "UPDATE service_state SET value=? WHERE key='collection_started'",
    String(start),
  );
  const users = [];
  for (let i = 0; i < 62; i++) {
    store.now = () => start + Math.floor(i / 4) * day;
    const u = store.consumeMagic(
      store.magic(
        "fixture-" + String(i + 1).padStart(2, "0") + "@example.test",
      ),
    ).user;
    users.push(u);
    if (i % 3 !== 0)
      store.run(
        "INSERT INTO entitlements VALUES(?,?,?,'active',?,NULL,NULL,?)",
        "sub_fixture_" + i,
        u.id,
        "monthly",
        now + 8 * day,
        store.now(),
      );
  }
  for (let i = 0; i < 18; i++) {
    store.now = () => start + i * day;
    for (let n = 0; n < 18 + i * 2 + (i % 4) * 3; n++)
      store.activity("page_view", n % 3 ? "site.direct" : "site.google.com");
    for (let n = 0; n < 3 + (i % 5); n++) store.activity("download", "site");
    if (i % 3 === 0)
      store.run(
        "INSERT INTO payment_reserves VALUES(?,?,?,?,?,?,?)",
        "in_fixture_" + i,
        users[i].id,
        "pi_fixture_" + i,
        1999,
        "eur",
        store.now(),
        store.now() + 14 * day,
      );
  }
  store.now = realNow;
  store.run(
    "INSERT INTO support_tickets(id,user_id,category,message,created) VALUES(?,?,?,?,?)",
    "fixture-ticket",
    users[0].id,
    "compatibilite",
    "Le jeu se lance correctement, mais la fenêtre reste sur le Mac. <img src=x onerror=alert(1)>",
    now - 7200,
  );
}
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
      return {
        accepted: [typeof mail.to === "string" ? mail.to : mail.to.address],
      };
    },
  },
});
app.addHook("onSend", async (req, reply, payload) => {
  if (
    req.url.split("?")[0].startsWith("/Playmelt/legal/conditions-de-vente/")
  ) {
    const policy = readFileSync(
      resolve(site, "legal/conditions-de-vente/.htaccess"),
      "utf8",
    ).match(/Header always set Content-Security-Policy "([^"]+)"/)[1];
    reply.header("Content-Security-Policy", policy);
  }
  return payload;
});
app.get("/__fixture__/mail", async () => ({ url: lastLink }));
app.get("/__fixture__/owner-code", async () => ({
  code: store.issueOwnerCode("owner@example.test"),
}));
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
await app.listen({ host: "127.0.0.1", port });
console.log("Loopback-only fixture ready on " + port);
