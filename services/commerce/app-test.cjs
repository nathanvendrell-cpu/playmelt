// Isolated hosted recipe: never reads the production environment or signing key.
const { lstatSync, readFileSync, existsSync } = require("node:fs");
const root = "/home/vena7840/playmelt-commerce/shared/";
function privateText(file) {
  const stat = lstatSync(file);
  if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077)
    throw Error("Private test configuration required");
  return readFileSync(file, "utf8").trim();
}
try {
  const file = root + "commerce.test.env";
  privateText(file);
  process.loadEnvFile(file);
  const expected = {
    STRIPE_MODE: "test",
    PLAYMELT_PUBLIC_URL: "https://7agency.fr/Playmelt/compte-test",
    PLAYMELT_DATABASE: root + "account.test.sqlite",
    PLAYMELT_SIGNING_KEY_FILE: root + "licence-signing.test.pem",
    PLAYMELT_TEST_ACCOUNT_EMAIL: "nathanvendrell@gmail.com",
  };
  for (const [key, value] of Object.entries(expected))
    if (process.env[key] !== value) throw Error("Test isolation mismatch");
  process.env.STRIPE_API_KEY = privateText(root + "stripe.test.key");
  delete process.env.STRIPE_WEBHOOK_SECRET;
  const webhook = root + "webhook.test.key";
  if (existsSync(webhook)) process.env.STRIPE_WEBHOOK_SECRET = privateText(webhook);
  import("./src/main.mjs").catch((error) => {
    console.error("Playmelt test startup failed:", error.code || error.name);
    process.exitCode = 1;
  });
} catch (error) {
  console.error("Playmelt test configuration unavailable:", error.code || error.name);
  process.exitCode = 1;
}
