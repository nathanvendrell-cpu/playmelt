// Host-only operator command. It does not create a Stripe payment or a universal key.
import { lstatSync } from "node:fs";
import { normalizeEmail } from "../src/email.mjs";
import { validatePrivateStorage } from "../src/private-storage.mjs";
import { Store } from "../src/store.mjs";
const file = "/home/vena7840/playmelt-commerce/shared/commerce.env";
process.umask(0o077);
const stat = lstatSync(file);
if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077)
  throw Error("Private configuration required");
process.loadEnvFile(file);
const email = normalizeEmail(process.env.PLAYMELT_OWNER_EMAIL);
const admins = (process.env.PLAYMELT_ADMINS || "")
  .split(",")
  .map((x) => normalizeEmail(x.trim()))
  .filter(Boolean);
if (!email || !admins.includes(email))
  throw Error("Owner must be an explicitly configured administrator");
validatePrivateStorage({
  root: process.env.PLAYMELT_PRIVATE_ROOT,
  documentRoot: process.env.PLAYMELT_DOCUMENT_ROOT,
  database: process.env.PLAYMELT_DATABASE,
  signingKey: process.env.PLAYMELT_SIGNING_KEY_FILE,
});
const store = new Store(process.env.PLAYMELT_DATABASE);
try {
  const code = store.issueOwnerCode(email);
  console.log(
    JSON.stringify({
      email,
      code,
      expiresInDays: 7,
      oneTime: true,
      plan: "lifetime",
      origin: "owner_grant",
      payment: false,
    }),
  );
} finally {
  store.close();
}
