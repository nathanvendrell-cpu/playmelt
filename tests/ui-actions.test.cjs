"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function openGame(game)");
const end = html.indexOf("function renderLibrary()", start);
assert(start > 0 && end > start);
function node(tag, cls, text) {
  return {
    tag,
    cls,
    get text() {
      return this.textContent;
    },
    children: [],
    handlers: {},
    value: "",
    textContent: text ?? "",
    append(...items) {
      this.children.push(...items);
    },
    replaceChildren(...items) {
      this.children = items;
    },
    addEventListener(name, action) {
      this.handlers[name] = action;
    },
    setAttribute(name, value) {
      this[name] = value;
    },
    hasAttribute(name) {
      return name === "value" ? this.value !== "" : this[name] !== undefined;
    },
    removeAttribute(name) {
      if (name === "value") this.value = "";
      else delete this[name];
    },
    showModal() {
      this.shown = true;
      this.open = true;
    },
    close() {
      this.shown = false;
      this.open = false;
    },
  };
}
const elements = Object.fromEntries(
  [
    "dialogTitle",
    "dialogStore",
    "dialogBody",
    "gameDialog",
    "installJobButton",
  ].map((id) => [id, node("div")]),
);
const sent = [];
const context = {
  ui: { dialogGameId: null },
  document: {
    getElementById: (id) => elements[id] || null,
    querySelectorAll: () => [],
  },
  $: (id) => elements[id],
  el: node,
  send: (action, payload) => sent.push({ action, payload }),
  platforms: (game) => game.platforms || [],
  platformLabel: () => "Mac",
  storeName: () => "Steam",
  state: {
    runtimes: [
      {
        id: "steam-mac",
        name: "Steam macOS",
        platform: "mac",
        available: true,
      },
    ],
  },
  Option: function (text, value) {
    this.text = text;
    this.value = value;
  },
};
const api = vm.runInNewContext(
  html.slice(start, end) + "; ({openGame,refreshVisibleDialog})",
  context,
);
const openGame = api.openGame;
openGame({
  id: "steam:427520",
  title: "Factorio",
  store: "steam",
  canLaunch: true,
  installed: true,
});
assert.equal(sent.length, 0, "Opening a game sheet must never launch a game");
assert.equal(elements.gameDialog.shown, true);
const play = elements.dialogBody.children.find(
  (child) => child.text === "Jouer",
);
assert(play, "Launching requires a visible explicit Play button");
play.handlers.click();
assert.equal(sent.length, 1);
assert.equal(sent[0].action, "launchGame");
assert.equal(sent[0].payload.gameId, "steam:427520");
assert.equal(elements.gameDialog.shown, false);
sent.length = 0;
openGame({
  id: "steam:10",
  title: "Test",
  store: "steam",
  canLaunch: false,
  canInstall: true,
  installed: false,
  platforms: ["mac"],
  runtimeId: "steam-mac",
});
assert.equal(
  sent.length,
  0,
  "Opening an installation sheet must never start an installation",
);
const install = elements.dialogBody.children.find(
  (child) => child.text === "Installer",
);
assert(install, "Installation requires a visible explicit Install button");
install.handlers.click();
assert.equal(sent.length, 1);
assert.equal(sent[0].action, "installGame");
assert.equal(sent[0].payload.runtimeId, "steam-mac");
sent.length = 0;
openGame({
  id: "steam:526870",
  title: "Satisfactory",
  store: "steam",
  canLaunch: false,
  canInstall: false,
  installed: false,
  platforms: ["windows"],
  runtimeId: "",
});
assert.equal(
  sent.length,
  0,
  "An unavailable Windows engine cannot start anything",
);
const setup = elements.dialogBody.children.find(
  (child) => child.text === "Moteur Windows à configurer",
);
assert(
  setup && setup.disabled,
  "Unavailable Windows route is visibly disabled",
);
assert.equal(
  setup.handlers.click,
  undefined,
  "No pretend configuration or native Steam fallback",
);
context.state.windowsRuntime = {
  status: "missing",
  readyEngine: false,
  steamInstalled: false,
  cancellable: false,
};
const windowsGame = {
  id: "steam:526870",
  title: "Satisfactory",
  store: "steam",
  canLaunch: false,
  canInstall: false,
  installed: false,
  platforms: ["windows"],
};
openGame(windowsGame);
assert.equal(
  sent.length,
  0,
  "Opening the setup sheet must not download or configure anything",
);
const configure = elements.dialogBody.children.find(
  (child) => child.text === "Configurer le moteur",
);
assert(
  configure && !configure.disabled,
  "A real backend setup capability enables its explicit button",
);
configure.handlers.click();
assert.equal(sent.length, 1);
assert.equal(sent[0].action, "setupWindowsRuntime");
sent.length = 0;
context.state.windowsRuntime = {
  status: "downloading",
  bytesDownloaded: 25,
  bytesTotal: 100,
  cancellable: true,
};
openGame(windowsGame);
assert.equal(sent.length, 0, "Progress rendering cannot dispatch setup");
assert.equal(
  elements.dialogBody.children.find((child) => child.tag === "progress").value,
  0.25,
);
assert(
  elements.dialogBody.children.some((child) =>
    child.children.some((n) => n.text === "25 %"),
  ),
  "Only a measured ratio is shown",
);
context.state.windowsRuntime = {
  status: "verifying",
  bytesDownloaded: 100,
  bytesTotal: 100,
  cancellable: false,
};
openGame(windowsGame);
assert.equal(
  elements.dialogBody.children.find((child) => child.tag === "progress").value,
  "",
  "Verification is indeterminate despite completed download bytes",
);
context.state.windowsRuntime = {
  status: "downloading",
  bytesDownloaded: 25,
  bytesTotal: 0,
  cancellable: true,
};
openGame(windowsGame);
assert.equal(
  elements.dialogBody.children.find((child) => child.tag === "progress").value,
  "",
  "Unknown total cannot produce a percentage",
);
const cancel = elements.dialogBody.children.find(
  (child) => child.text === "Annuler",
);
cancel.handlers.click();
assert.equal(sent[0].action, "cancelWindowsRuntime");
sent.length = 0;
context.state.windowsRuntime = {
  status: "ready",
  readyEngine: true,
  steamInstalled: false,
  steamBusy: false,
};
openGame(windowsGame);
assert.equal(sent.length, 0, "A ready engine must not auto-install Steam");
const steam = elements.dialogBody.children.find(
  (child) => child.text === "Installer Steam Windows",
);
assert(steam && !steam.disabled);
steam.handlers.click();
assert.equal(sent[0].action, "installSteamWindows");
sent.length = 0;
context.state.windowsRuntime.steamBusy = true;
openGame(windowsGame);
assert(
  elements.dialogBody.children.some((child) =>
    child.children.some((n) => n.text === "Installation de Steam"),
  ),
);
assert.equal(
  elements.dialogBody.children.find((child) => child.tag === "progress").value,
  "",
  "Steam bootstrap has no invented percentage",
);
assert.equal(sent.length, 0);
const nativeGame = {
  id: "steam:10",
  title: "Test",
  store: "steam",
  installed: false,
  canInstall: true,
  canInstallAndPlay: true,
  platforms: ["mac"],
  runtimeId: "steam-mac",
};
openGame(nativeGame);
const installPlay = elements.dialogBody.children.find(
  (child) => child.text === "Installer et jouer",
);
assert(installPlay);
assert.equal(sent.length, 0, "Installer et jouer remains an explicit choice");
installPlay.handlers.click();
assert.equal(sent[0].action, "installAndPlay");
assert.equal(sent[0].payload.runtimeId, "steam-mac");
assert.equal(
  elements.gameDialog.open,
  true,
  "Tracked installation keeps progress sheet available",
);
sent.length = 0;
context.state.installJob = {
  id: "job-1",
  gameId: nativeGame.id,
  title: "Test",
  status: "downloading",
  bytesDownloaded: 50,
  bytesTotal: 100,
  cancellable: true,
  autoLaunch: true,
};
openGame(nativeGame);
assert.equal(sent.length, 0);
assert.equal(
  elements.dialogBody.children.find((child) => child.tag === "progress").value,
  0.5,
);
const stop = elements.dialogBody.children.find(
  (child) => child.text === "Arrêter le suivi",
);
assert(stop);
stop.handlers.click();
assert.equal(sent[0].action, "cancelInstallAndPlay");
sent.length = 0;
context.state.installJob.status = "launch-requested";
context.state.installJob.cancellable = false;
openGame(nativeGame);
assert.equal(
  sent.length,
  0,
  "A launch-requested status must not cause duplicate launches",
);
assert(
  elements.dialogBody.children.some((child) =>
    child.children.some((n) => n.text === "Lancement demandé"),
  ),
);
assert(
  !elements.dialogBody.children.some((child) => child.tag === "progress"),
  "No fake ongoing install after launch request",
);
sent.length = 0;
context.state.installJob = null;
context.state.games = [windowsGame];
context.state.windowsRuntime = {
  status: "downloading",
  bytesDownloaded: 25,
  bytesTotal: 100,
  cancellable: true,
};
openGame(windowsGame);
const runtimeProgress = elements.dialogBody.children.find(
  (n) => n.tag === "progress",
);
const runtimeCancel = elements.dialogBody.children.find(
  (n) => n.text === "Annuler",
);
runtimeCancel.handlers.click();
assert.equal(runtimeCancel.disabled, true);
context.state.windowsRuntime.bytesDownloaded = 50;
api.refreshVisibleDialog();
assert.equal(
  elements.dialogBody.children.find((n) => n.tag === "progress"),
  runtimeProgress,
  "Runtime progress reuses the same DOM node",
);
assert.equal(
  elements.dialogBody.children.find((n) => n.text === "Annuler"),
  runtimeCancel,
  "The focused cancellation control is not replaced",
);
assert.equal(
  runtimeCancel.disabled,
  true,
  "Pending cancellation stays disabled on progress callbacks",
);
assert.equal(runtimeProgress.value, 0.5);
context.state.windowsRuntime.status = "verifying";
api.refreshVisibleDialog();
assert.equal(
  elements.dialogBody.children.find((n) => n.tag === "progress"),
  runtimeProgress,
  "Phase changes reuse progress DOM",
);
assert.equal(
  runtimeProgress.value,
  "",
  "Verification clears the download value",
);
context.state.games = [nativeGame];
context.state.installJob = {
  id: "job-2",
  gameId: nativeGame.id,
  status: "downloading",
  bytesDownloaded: 10,
  bytesTotal: 100,
  cancellable: true,
};
openGame(nativeGame);
const jobProgress = elements.dialogBody.children.find(
  (n) => n.tag === "progress",
);
const jobCancel = elements.dialogBody.children.find(
  (n) => n.text === "Arrêter le suivi",
);
context.state.installJob.bytesDownloaded = 75;
api.refreshVisibleDialog();
assert.equal(
  elements.dialogBody.children.find((n) => n.tag === "progress"),
  jobProgress,
  "Game downloads reuse progress DOM",
);
assert.equal(
  elements.dialogBody.children.find((n) => n.text === "Arrêter le suivi"),
  jobCancel,
  "Game cancellation control stays stable",
);
assert.equal(jobProgress.value, 0.75);
console.log(
  "UI actions passed: explicit actions only; stable progress/cancel DOM and truthful measurements",
);
