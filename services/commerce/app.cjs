// Passenger startup. Configuration and data stay outside the public document root.
const { statSync } = require("node:fs");
const configFile = "/home/vena7840/playmelt-commerce/shared/commerce.env";
try {
  if ((statSync(configFile).mode & 0o077) !== 0)
    throw Error("Configuration must be private");
  process.loadEnvFile(configFile);
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
