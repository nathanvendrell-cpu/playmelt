"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function imageSources(game)");
const end = html.indexOf("function art(", start);
assert(
  start > 0 && end > start,
  "The production image resolver must be present",
);
const source = html.slice(start, end);
const imageSources = vm.runInNewContext(source + "; imageSources", { URL });
const game = {
  store: "steam",
  appId: "526870",
  localImageURL: "metalmaxart://steam/526870",
  imageURL:
    "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/526870/header.jpg",
};
const values = (value) => Array.from(imageSources(value));
assert.deepEqual(
  values(game),
  [game.localImageURL, game.imageURL],
  "Prefer the verified local cache, retaining HTTPS fallback",
);
for (const bad of [
  "file:///Users/robtech/Library/secret.jpg",
  "metalmaxart://steam/427520",
  "metalmaxart://steam/526870/../../secret",
  "metalmaxart://other/526870",
  "metalmaxart://user:password@steam/526870",
  "metalmaxart://steam:8080/526870",
  "metalmaxart://steam/526870?path=/etc/passwd",
  "metalmaxart://steam/526870#fragment",
])
  assert.deepEqual(
    values({ ...game, localImageURL: bad }),
    [game.imageURL],
    `Reject local artwork URL ${bad}`,
  );
for (const bad of [
  "https://example.com/image.png",
  "https://shared.fastly.steamstatic.com.evil.test/image.png",
  "http://shared.fastly.steamstatic.com/image.png",
  "https://u:p@shared.fastly.steamstatic.com/image.png",
  "https://shared.fastly.steamstatic.com:8080/image.png",
  "javascript:alert(1)",
  "data:image/png;base64,AAAA",
])
  assert.deepEqual(
    values({ ...game, imageURL: bad }),
    [game.localImageURL],
    `Reject remote artwork URL ${bad}`,
  );
assert.deepEqual(
  values({ ...game, store: "epic" }),
  [game.imageURL],
  "The Steam cache cannot be requested for another store",
);
assert.deepEqual(
  values({ ...game, appId: "../526870" }),
  [game.imageURL],
  "Game IDs cannot carry paths",
);
assert.deepEqual(
  values({ ...game, localImageURL: undefined }),
  [game.imageURL],
  "Missing local cache URL retains HTTPS",
);
assert.deepEqual(
  values({ store: "steam", appId: "1" }),
  [],
  "No made-up visual for missing artwork",
);
assert.deepEqual(
  values({
    ...game,
    localPortraitURL: "metalmaxart://steam/526870/portrait",
    portraitImageURL:
      "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/526870/library_600x900.jpg",
  }),
  [
    "metalmaxart://steam/526870/portrait",
    game.localImageURL,
    "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/526870/library_600x900.jpg",
    game.imageURL,
  ],
  "Use the actual portrait cache before header fallbacks",
);
assert.deepEqual(
  values({
    ...game,
    localPortraitURL: "metalmaxart://steam/526870/portrait/../../secret",
  }),
  [game.localImageURL, game.imageURL],
  "Reject traversal in portrait route",
);
console.log("UI artwork security: 22 cases passed");
