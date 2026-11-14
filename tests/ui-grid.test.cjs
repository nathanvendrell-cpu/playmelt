"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function resolveCardAction(game)");
const end = html.indexOf("function fact(", start);
assert(start > 0 && end > start);
class Node {
  constructor(tag, cls, text) {
    this.tag = tag;
    this.className = cls;
    this.textContent = text || "";
    this.children = [];
    this.dataset = {};
    this.handlers = {};
    this.parent = null;
  }
  append(...nodes) {
    nodes.forEach((n) => this.insertBefore(n, null));
  }
  insertBefore(node, before) {
    if (node.parent) node.remove();
    const index = before ? this.children.indexOf(before) : this.children.length;
    assert(index >= 0);
    this.children.splice(index, 0, node);
    node.parent = this;
  }
  remove() {
    if (this.parent) {
      const list = this.parent.children;
      list.splice(list.indexOf(this), 1);
      this.parent = null;
    }
  }
  get lastElementChild() {
    return this.children.at(-1);
  }
  setAttribute(k, v) {
    this[k] = v;
  }
  addEventListener(k, v) {
    assert(
      !this.handlers[k],
      "A reused node must not accumulate event handlers",
    );
    this.handlers[k] = v;
  }
}
let imagesCreated = 0;
const disposedArtwork = [];
const elements = Object.fromEntries(
  ["gameGrid", "empty", "emptyTitle", "loadMore"].map((id) => [
    id,
    new Node("div"),
  ]),
);
const games = Array.from({ length: 4 }, (_, i) => ({
  id: "steam:" + i,
  title: "Game " + i,
  store: "steam",
  platforms: ["mac"],
  canInstall: true,
  imageURL: "https://example.invalid/" + i,
}));
let filtered = games;
const cache = new Map();
const context = {
  el: (...args) => new Node(...args),
  $: (id) => elements[id],
  art: (game) => {
    imagesCreated++;
    const node = new Node("img");
    node.disposeArtwork = () => disposedArtwork.push(game.id);
    return node;
  },
  platforms: (g) => g.platforms,
  platformLabel: () => "Mac",
  storeName: () => "Steam",
  state: { games, renderProtectionEnabled: false },
  ui: { limit: 2, install: "all", platform: "all", view: "library" },
  received: true,
  filteredGames: () => filtered,
  gameCardCache: cache,
  renderSpotlight: () => {},
  renderRows: () => {},
  updateJobIndicator: () => {},
  openGame: () => {},
  installJobFor: () => null,
  gamePresentationJob: () => null,
  send: () => {
    throw Error("Rendering must not dispatch actions");
  },
};
const render = vm.runInNewContext(
  html.slice(
    html.indexOf("function renderProtectionEnabled()"),
    html.indexOf("function createRenderProtectionControl()"),
  ) +
    html.slice(html.indexOf("function isSteamWindowsGame(game)"), html.indexOf("function renderSteamWindowsInstallation")) +
    html.slice(html.indexOf("function installationJobGame(job)"), html.indexOf("function steamCompletionSignature(game)")) +
    html.slice(start, end) +
    "; renderLibrary",
  context,
);
render();
const first = elements.gameGrid.children.slice();
assert.equal(imagesCreated, 2);
context.ui.limit = 4;
render();
assert.equal(
  imagesCreated,
  4,
  "Pagination creates only newly added cover nodes",
);
assert.equal(elements.gameGrid.children[0], first[0]);
assert.equal(elements.gameGrid.children[1], first[1]);
const selected = [elements.gameGrid.children[1], elements.gameGrid.children[3]];
filtered = [games[1], games[3]];
render();
assert.deepEqual(
  elements.gameGrid.children,
  selected,
  "Filtering keeps existing cover elements",
);
assert.equal(imagesCreated, 4);
assert.equal(
  cache.size,
  2,
  "Invisible covers are released, not retained in an unbounded cache",
);
assert.deepEqual(
  disposedArtwork.slice().sort(),
  [games[0].id, games[2].id].sort(),
  "Only evicted cards dispose their artwork",
);
render();
assert.equal(
  imagesCreated,
  4,
  "Unchanged renders do not recreate images or listeners",
);
games[1].title = "Renamed";
render();
assert.notEqual(
  elements.gameGrid.children[0],
  selected[0],
  "A real content change updates the affected card",
);
assert.equal(elements.gameGrid.children[1], selected[1]);
assert.equal(imagesCreated, 5);
assert.equal(
  disposedArtwork.filter((id) => id === games[1].id).length,
  1,
  "Replacing a changed card disposes its old artwork once",
);
context.ui.artworkGeneration = 1;
render();
assert.equal(
  imagesCreated,
  7,
  "Explicit refresh regenerates visible artwork when new native state arrives",
);
assert.equal(cache.size, 2);
games[1].requiredRenderer = "d3dmetal";
games[1].platform = "windows";
games[1].platforms = ["windows"];
games[1].requiredGraphicsAPI = "DirectX12";
games[1].canLaunch = true;
filtered = [games[1]];
render();
const walk = (node) => [node, ...node.children.flatMap(walk)];
const configure = walk(elements.gameGrid.children[0]).find(
  (node) => node.className === "game-action",
);
assert.equal(
  configure.textContent,
  "Jouer",
  "Native readiness controls the label; an optional DX12 component UI cannot replace Play",
);
let opened = null;
context.openGame = (game) => {
  opened = game.id;
};
let launched = null;
context.send = (action, payload) => { assert.equal(action, "launchGame"); launched = payload.gameId; };
configure.handlers.click();
assert.equal(
  launched,
  games[1].id,
  "A native-confirmed ready Windows game plays directly without another setup prompt",
);
delete games[1].requiredRenderer;
context.state.renderProtectionEnabled = true;
render();
opened = null;
walk(elements.gameGrid.children[0])
  .find((n) => n.className === "game-action")
  .handlers.click();
assert.equal(
  opened,
  games[1].id,
  "Protected quick actions open the sheet, never launch a game",
);
console.log(
  "Grid reuse passed; artwork disposal preserved; DX12 card routes only to configuration",
);
