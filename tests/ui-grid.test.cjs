"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function createGameCard(game)");
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
  art: () => {
    imagesCreated++;
    return new Node("img");
  },
  platforms: (g) => g.platforms,
  platformLabel: () => "Mac",
  storeName: () => "Steam",
  state: { games },
  ui: { limit: 2, install: "all", platform: "all", view: "library" },
  received: true,
  filteredGames: () => filtered,
  gameCardCache: cache,
  updateJobIndicator: () => {},
  openGame: () => {},
  installJobFor: () => null,
  send: () => {
    throw Error("Rendering must not dispatch actions");
  },
};
const render = vm.runInNewContext(
  html.slice(start, end) + "; renderLibrary",
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
console.log(
  "Grid reuse passed: pagination appends, filters preserve nodes, hidden cache released, changed card replaced",
);
