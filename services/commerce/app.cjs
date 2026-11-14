// Passenger startup. Configuration and data stay outside the public document root.
const { lstatSync, readFileSync, existsSync } = require("node:fs");
const configFile = "/home/vena7840/playmelt-commerce/shared/commerce.env";
function privateText(file) {
  const stat = lstatSync(file);
  if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077)
    throw Error("Private configuration required");
  return readFileSync(file, "utf8").trim();
}
try {
  privateText(configFile);
  process.loadEnvFile(configFile);
  const mode = process.env.STRIPE_MODE;
  if (!["live", "test"].includes(mode)) throw Error("Invalid Stripe mode");
  process.env.STRIPE_API_KEY = privateText(
    "/home/vena7840/playmelt-commerce/shared/stripe." + mode + ".key",
  );
  const webhookFile =
    "/home/vena7840/playmelt-commerce/shared/webhook." + mode + ".key";
  if (existsSync(webhookFile))
    process.env.STRIPE_WEBHOOK_SECRET = privateText(webhookFile);
  import("./src/main.mjs").catch((error) => {
    console.error(
      "Playmelt commerce startup failed:",
      error.code || error.name,
    );
    process.exitCode = 1;
  });
} catch (error) {
  console.error(
    "Playmelt commerce configuration unavailable:",
    error.code || error.name,
  );
  process.exitCode = 1;
}
