"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("window.onNativeRuntime =");
const end = html.indexOf("window.onNativeResult =", start);
assert(start > 0 && end > start);
let modalUpdates = 0,
  indicators = 0;
const game = { id: "steam:526870" };
const context = {
  window: {},
  state: { games: [game] },
  ui: { dialogGameId: game.id },
  $: () => ({ open: true }),
  refreshVisibleDialog: () => modalUpdates++,
  updateJobIndicator: () => indicators++,
  renderLibrary: () => {
    throw Error("Progress must never rebuild covers");
  },
};
vm.runInNewContext(html.slice(start, end), context);
const runtime = { status: "downloading", bytesDownloaded: 42, bytesTotal: 100 };
context.window.onNativeRuntime(runtime);
assert.equal(context.state.windowsRuntime, runtime);
assert.equal(modalUpdates, 1);
assert.equal(indicators, 0);
const job = { id: "job-1", gameId: game.id, status: "downloading" };
context.window.onNativeInstallJob(job);
assert.equal(context.state.installJob, job);
assert.equal(modalUpdates, 2);
assert.equal(indicators, 1);
context.window.onNativeInstallJob(null);
assert.equal(context.state.installJob, null);
assert.equal(modalUpdates, 3);
assert.equal(indicators, 2);
console.log(
  "Dedicated progress callbacks passed: state/modal only, no cover-grid rebuild",
);
