"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
// Exercise the real bridge gate, including the former local-game exception.
const bridged = [];
const bridgeContext = {
  state: { games: [{ id: "local:10", installSource: "local" }] },
  window: { webkit: { messageHandlers: { metalmax: { postMessage: (m) => bridged.push(m) } } } },
  protected: true,
  renderProtectionEnabled() { return this.protected; },
  windowsExecutionUnavailable: () => false,
};
bridgeContext.renderProtectionEnabled = () => bridgeContext.protected;
const bridgeStart = html.indexOf("const allowedActions = new Set(");
const bridgeEnd = html.indexOf("function imageSources(", bridgeStart);
const bridgeSend = vm.runInNewContext(html.slice(bridgeStart, bridgeEnd) + "; send", bridgeContext);
assert.equal(bridgeSend("launchGame", { gameId: "local:10" }), false);
assert.equal(bridgeSend("uninstallGame", { gameId: "local:10" }), false);
assert.equal(bridged.length, 0, "Local games must respect render protection at the actual bridge");
bridgeContext.protected = false;
assert.equal(bridgeSend("uninstallGame", { gameId: "local:10" }), true);
assert.equal(bridged[0].action, "uninstallGame", "Uninstall reaches native target preview and confirmation");
const start = html.indexOf("function renderProtectionEnabled()");
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
    dataset: {},
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
    "gameSettingsDialog",
    "gameSettingsBody",
    "gameSettingsSubtitle",
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
  send: (action, payload) => { sent.push({ action, payload }); return true; },
  platforms: (game) => game.platforms || [],
  platformLabel: () => "Mac",
  storeName: () => "Steam",
  state: {
    renderProtectionEnabled: false,
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
  html.slice(start, end) + "; ({openGame,refreshVisibleDialog,openGameSettings,renderGameSettings,settingsMetrics,measuredPerformance})",
  context,
);
const openGame = api.openGame;
const configGame = {id:'local:10',title:'Test',installed:true};
api.openGameSettings(configGame, null);
assert.equal(sent.pop().action, 'getGameSettings');
const snapshot = {gameId:'local:10',status:'ready',revision:3,settings:{launchArgs:'',backend:'auto',display:{screenID:'primary',mode:'fullscreen',width:1280,height:720,refreshRate:60,retina:'auto',vsync:true,hdr:false},graphics:{upscaler:'fsr',quality:'quality',dynamicFPS:60,frameGeneration:true,grain:0,sharpness:.2}},capabilities:{launchArgs:true,backends:[{value:'auto',label:'Auto'}],display:true,graphics:true,displays:[{value:'primary',label:'Principal',width:2560,height:1440,refreshRate:59.94}]},measurements:{}};
api.renderGameSettings(snapshot);
assert.equal(api.settingsMetrics(snapshot.settings, snapshot.capabilities).budget, 1000/60);
assert.equal(api.settingsMetrics(snapshot.settings, {display:false,graphics:false}), null);
assert.equal(api.measuredPerformance({source:'log',timestamp:'2026-11-11T00:00:00Z',fpsSamples:[{timestamp:'00:00:01',fps:42}]}).value, '—', 'Incomplete measurement is not displayed');
assert.equal(api.measuredPerformance({source:'log',timestamp:'2026-11-11T00:00:00Z',fpsSamples:[{timestamp:'00:00:01',fps:42,observedSettings:{Resolution:'2560x1440'}}]}).value, '42 FPS');
assert.equal(context.ui.gameSettings.save.disabled, true);
const sectionNodes = elements.gameSettingsBody.children;
const screenButton = sectionNodes[1].children[1].children.find(n => n.text === 'Utiliser la résolution de l’écran');
assert.equal(context.ui.gameSettings.draft.display.width, 1280, 'Screen choice never changes dimensions silently');
screenButton.handlers.click();
assert.equal(context.ui.gameSettings.draft.display.width, 2560);
assert.equal(context.ui.gameSettings.draft.display.height, 1440);
assert.equal(context.ui.gameSettings.draft.display.refreshRate, 60, 'Fractional refresh rate rounds to a valid integer');
const grain = context.ui.gameSettings.inputs.grain;
grain.value = '37'; grain.handlers.input();
assert.equal(context.ui.gameSettings.draft.graphics.grain, .37, 'Slider percent is converted to backend fraction');
const argsInput = sectionNodes[0].children[1].children[0].children[1];
argsInput.value = '-nolauncher'; argsInput.handlers.input();
assert.equal(context.ui.gameSettings.save.disabled, false);
api.renderGameSettings(snapshot);
assert.equal(context.ui.gameSettings.draft.launchArgs, '-nolauncher', 'A state refresh cannot overwrite the draft');
context.ui.gameSettings.save.handlers.click();
assert.equal(argsInput.disabled, true, 'Controls remain stable while a save is pending');
assert.equal(sent.at(-1).action, 'saveGameSettings');
assert.equal(sent.at(-1).payload.expectedRevision, 3);
assert.deepEqual(Array.from(sent.at(-1).payload.changedFields), ['display.height','display.refreshRate','display.width','graphics.grain','launchArgs']);
api.renderGameSettings({gameId:'local:10',status:'error',error:'Conflit de version'});
assert.equal(context.ui.gameSettings.draft.launchArgs, '-nolauncher');
assert.equal(context.ui.gameSettings.save.disabled, false);
assert.equal(argsInput.disabled, false, 'A failed save returns editing to the user');
assert.match(context.ui.gameSettings.statusNode.textContent, /Conflit de version/);
assert(context.ui.gameSettings.touched.has('launchArgs'), 'Failure preserves explicit changes');
elements.gameSettingsDialog.close();
sent.length = 0;
api.openGameSettings(configGame, null);
sent.length = 0;
api.renderGameSettings(snapshot);
const onlyArgs = context.ui.gameSettings.inputs.launchArgs;
onlyArgs.value = '--test'; onlyArgs.handlers.input();
onlyArgs.value = ''; onlyArgs.handlers.input();
context.ui.gameSettings.save.handlers.click();
assert.deepEqual(Array.from(sent.at(-1).payload.changedFields), ['launchArgs'], 'A reverted edit remains explicit and does not apply default graphics');
api.renderGameSettings({...snapshot, status:'saved', revision:4});
assert.equal(context.ui.gameSettings.touched.size, 0, 'Success clears touched fields');
const frameGen = context.ui.gameSettings.inputs.frameGeneration;
frameGen.checked = false; frameGen.handlers.change();
context.ui.gameSettings.save.handlers.click();
assert.deepEqual(Array.from(sent.at(-1).payload.changedFields), ['graphics.frameGeneration']);
assert.equal(sent.at(-1).payload.settings.graphics.frameGeneration, false, 'An explicit false is preserved');
api.renderGameSettings({...snapshot, status:'saved', revision:5});
const graphicsSection = elements.gameSettingsBody.children.find(n => n.children[0]?.text === 'Graphismes');
graphicsSection.children[1].children.find(n => n.text === 'Utiliser FSR Qualité').handlers.click();
context.ui.gameSettings.save.handlers.click();
assert.deepEqual(Array.from(sent.at(-1).payload.changedFields), ['graphics.quality','graphics.upscaler']);
elements.gameSettingsDialog.close();
sent.length = 0;
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
assert(
  elements.dialogBody.children.some((n) => n.text === "Indisponible"),
  "Unavailable route stays explicit",
);
assert(
  !elements.dialogBody.children.some((n) => n.tag === "button"),
  "No fake configuration button for a missing backend",
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
  (child) => child.text === "Préparer DirectX 11",
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
  (child) => child.text === "Installer Steam pour DirectX 11",
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
context.state.renderProtectionEnabled = true;
context.state.installJob = null;
openGame({
  id: "steam:mac",
  title: "Installed",
  store: "steam",
  canLaunch: true,
  installed: true,
});
assert(
  elements.dialogBody.children.find((n) => n.text === "Jouer").disabled,
  "Protection disables Play in an installed-game sheet",
);
openGame(nativeGame);
assert(
  elements.dialogBody.children.find((n) => n.text === "Installer et jouer")
    .disabled,
  "Protection disables tracked installs",
);
context.state.windowsRuntime = {
  status: "missing",
  readyEngine: false,
  steamInstalled: false,
};
openGame(windowsGame);
assert(
  elements.dialogBody.children.find((n) => n.text === "Préparer DirectX 11")
    .disabled,
  "Protection disables DXMT configuration",
);
context.state.windowsRuntime = {
  status: "ready",
  readyEngine: true,
  steamInstalled: false,
};
openGame(windowsGame);
assert(
  elements.dialogBody.children.find(
    (n) => n.text === "Installer Steam pour DirectX 11",
  ).disabled,
  "Protection disables Steam bootstrap",
);
context.state.windowsRuntime.steamInstalled = true;
openGame(windowsGame);
assert(
  elements.dialogBody.children.find((n) => n.text === "Ouvrir Steam DirectX 11")
    .disabled,
  "Protection disables Steam launches",
);
console.log(
  "UI actions passed: explicit actions only; stable progress/cancel DOM and truthful measurements",
);
