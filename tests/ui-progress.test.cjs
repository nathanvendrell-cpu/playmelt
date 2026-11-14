"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("window.onNativeRuntime =");
const end = html.indexOf("window.onNativeResult =", start);
assert(start > 0 && end > start);
const notices = [];
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
  showToast: (message) => notices.push(message),
  renderLibrary: () => {
    throw Error("Progress must never rebuild covers");
  },
};
const phaseStart = html.indexOf("function jobPhase(job)"), phaseEnd = html.indexOf("function jobRatio(job)", phaseStart);
const jobsStart = html.indexOf("function installationJobs()"), jobsEnd = html.indexOf("function installJobFor(game)", jobsStart);
vm.runInNewContext(html.slice(jobsStart, jobsEnd) + html.slice(phaseStart, phaseEnd) + html.slice(start, end), context);
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
context.window.onNativeInstallJob({...job, status: "files-prepared"});
assert.match(notices.at(-1), /préparation du lancement reste à terminer/);
context.window.onNativeInstallJob({...job, status: "launch-ready"});
assert.doesNotMatch(notices.at(-1), /Tu peux jouer/);
context.window.onNativeInstallJob(null);
game.canLaunch = true; game.launchBlockReason = "Steam indisponible";
context.window.onNativeInstallJob({...job, status: "launch-ready"});
assert.doesNotMatch(notices.at(-1), /Tu peux jouer/);
context.window.onNativeInstallJob(null);
game.launchBlockReason = "";
context.window.onNativeInstallJob({...job, status: "launch-ready"});
assert.match(notices.at(-1), /Tu peux jouer/);
const gog = {id:"gog:1423049311:fixture",gameId:"gog:1423049311",store:"gog",observed:true,status:"installing"};
context.window.onNativeInstallJobs({jobs:[gog]});
assert.equal(context.state.installJobs.length,1);
context.window.onNativeInstallJob(job);
assert.equal(context.state.installJobs.length,2,"legacy managed update preserves an external GOG operation");
context.window.onNativeInstallJob(null);
assert.equal(context.state.installJobs.length,1);assert.equal(context.state.installJobs[0],gog);
context.window.onNativeInstallJobs({jobs:[]});
assert.equal(context.state.installJobs.length,0,"an authoritative empty snapshot clears the list");
console.log(
  "Dedicated progress callbacks passed: state/modal only, no cover-grid rebuild",
);
