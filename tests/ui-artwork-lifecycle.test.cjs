"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function art(game)"),
  end = html.indexOf("function platforms(", start);
assert(start > 0 && end > start);
const nodes = [];
function el(tag) {
  const node = {
    tag,
    children: [],
    listeners: new Map(),
    assigned: [],
    cleared: [],
    removed: false,
    append(child) {
      this.children.push(child);
    },
    addEventListener(name, handler) {
      this.listeners.set(name, handler);
    },
    removeEventListener(name, handler) {
      if (this.listeners.get(name) === handler) this.listeners.delete(name);
    },
    removeAttribute(name) {
      this.cleared.push(name);
    },
    remove() {
      this.removed = true;
    },
    set src(value) {
      this.assigned.push(value);
    },
  };
  nodes.push(node);
  return node;
}
let sources = [
  "cache://portrait",
  "cache://header",
  "https://cdn.example/portrait",
];
const art = vm.runInNewContext(html.slice(start, end) + ";art", {
  el,
  imageSources: () => sources,
});
const visible = art({});
const image = visible.children[0];
assert.equal(image.loading, "lazy");
assert.equal(image.decoding, "async");
const error = image.listeners.get("error");
error();
assert.deepEqual(
  image.assigned,
  sources.slice(0, 2),
  "A retained card can use its real fallback",
);
visible.disposeArtwork();
assert.equal(
  image.listeners.size,
  0,
  "Retired artwork detaches its error handler",
);
assert.deepEqual(
  image.cleared,
  ["src"],
  "The current image source is released",
);
assert.equal(image.removed, true);
error();
error();
assert.deepEqual(
  image.assigned,
  sources.slice(0, 2),
  "Already queued error callbacks cannot start another fallback after eviction",
);
visible.disposeArtwork();
assert.deepEqual(image.cleared, ["src"], "Disposal is idempotent");
sources = ["cache://only"];
const failed = art({}),
  failedImage = failed.children[0];
failedImage.listeners.get("error")();
assert.equal(
  failedImage.listeners.size,
  0,
  "Exhausted fallbacks also detach handlers",
);
assert.equal(failedImage.removed, true);
sources = [];
const empty = art({});
empty.disposeArtwork();
assert.equal(empty.children.length, 0);
console.log(
  "Artwork lifecycle passed: retained fallback works; eviction blocks late fallbacks and releases handlers/source",
);
