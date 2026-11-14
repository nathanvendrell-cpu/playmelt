"use strict";
const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const section = (a, b) => {
  const start = html.indexOf(a),
    end = html.indexOf(b, start);
  assert(start > 0 && end > start);
  return html.slice(start, end);
};
function node(tag, cls, text) {
  return {
    tag,
    cls,
    textContent: text || "",
    children: [],
    dataset: {},
    handlers: {},
    append(...values) {
      this.children.push(...values);
    },
    replaceChildren(...values) {
      this.children = values;
    },
    addEventListener(name, handler) {
      this.handlers[name] = handler;
    },
    setAttribute(name, value) {
      this[name] = value;
    },
    showModal() {
      this.open = true;
    },
    close() {
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
    "d3dMetalSettings",
    "installJobButton",
    "subscriptionDialog",
  ].map((id) => [id, node("div")]),
);
const all = (root) => [root, ...root.children.flatMap(all)];
const button = (root, label) =>
  all(root).find((n) => n.tag === "button" && n.textContent === label);
const sent = [];
const component = {
  status: "not-prepared",
  message: "Composant importé",
  imported: false,
  version: "3.0",
  prepared: false,
  steamInstalled: false,
  canPrepare: true,
  canLaunch: false,
  busy: false,
  cancellable: false,
};
const state = {
  games: [],
  runtimes: [],
  windowsRuntime: {
    status: "ready",
    readyEngine: true,
    steamInstalled: true,
    d3dMetal: component,
  },
};
const context = {
  state,
  ui: { dialogGameId: null, pendingRenderProtection: null },
  $: (id) => elements[id],
  el: node,
  document: {
    getElementById: (id) => elements[id] || null,
    querySelectorAll: (selector) =>
      selector === "[data-pending-d3d-action]"
        ? Object.values(elements)
            .flatMap(all)
            .filter((n) => n.dataset.pendingD3dAction)
        : [],
  },
  window: {
    webkit: {
      messageHandlers: {
        metalmax: { postMessage: (message) => sent.push(message) },
      },
    },
  },
  notify: () => {},
  platforms: (g) => g.platforms || [],
  platformLabel: () => "Windows",
  storeName: () => "Steam",
  updateToolbar: () => {},
  updateJobIndicator: () => {},
  renderDiagnostics: () => {},
};
const api = vm.runInNewContext(
  section("const allowedActions =", "function el(") +
    section("function send(", "function imageSources(") +
    section("function renderProtectionEnabled()", "function renderLibrary()") +
    ";({openGame,renderGameDialog,createD3DMetalControls,updateD3DMetalSettings,restoreD3DMetalImportControls,createRenderProtectionControl,renderProtectionEnabled,send})",
  context,
);
const game = {
  id: "steam:dx12", title: "Windows DX12 fixture", store: "steam", platform: "windows", platforms: ["windows"],
  requiredRenderer: "d3dmetal", runtimeId: "playmelt-d3dmetal", canLaunch: false, installed: false,
};
state.games = [game];
const body = elements.dialogBody;
api.openGame(game);
assert.equal(sent.length, 0, "Opening a sheet dispatches nothing");
assert.equal(api.renderProtectionEnabled(), true, "Absent protection field defaults to enabled");
assert(button(body, "Installer").disabled);
assert(!button(body, "Importer le composant Apple"), "Manual engine import stays in Settings");
for (const action of ["launchGame", "installGame", "installAndPlay", "openSteam", "openEpic", "setupWindowsRuntime", "installSteamWindows", "openWindowsSteam", "setupD3DMetalRuntime", "installSteamD3DMetal", "openD3DMetalSteam"])
  assert.equal(api.send(action, {gameId:game.id}), false, "Bridge protection: " + action);
for (const action of ["refresh", "syncLibrary", "syncEpic", "openSteamLogin", "cancelWindowsRuntime", "cancelInstallAndPlay", "cancelD3DMetalRuntime"]) {
  api.send(action); assert.equal(sent.pop().action, action, "Read/auth/cancel remains available");
}
const holder = elements.d3dMetalSettings;
api.updateD3DMetalSettings(holder);
assert(!button(holder, "Importer le composant Apple").disabled);
button(holder, "Importer le composant Apple").handlers.click();
assert.equal(sent.pop().action, "importD3DMetal");
api.restoreD3DMetalImportControls();
assert(!button(holder, "Importer le composant Apple").disabled, "Failed advanced import remains retryable");
button(holder, "Obtenir auprès d’Apple").handlers.click();
assert.equal(sent.pop().action, "openD3DMetalDownload");
state.renderProtectionEnabled = false;
api.renderGameDialog(game);
const primary = button(body, "Installer");primary.handlers.click();primary.handlers.click();
assert.equal(sent.length, 1, "A pending common install cannot dispatch twice");
assert.equal(sent.pop().action, "installAndPlay");
component.imported = true;
for (const status of ["checking", "initializing", "stopping"]) {
  Object.assign(component, {status,busy:true,cancellable:true});
  api.renderGameDialog(game);api.updateD3DMetalSettings(holder);
  assert(!button(body,"Installer"), "Busy preparation has no second install request");
  assert(button(holder,"Annuler"));
  assert(!all(body).some(n=>n.tag==='progress'), "DX12 setup has no fabricated percent");
}
button(holder,"Annuler").handlers.click();assert.equal(sent.pop().action,"cancelD3DMetalRuntime");
Object.assign(component,{status:'ready',busy:false,cancellable:false,prepared:true,steamInstalled:true,nvidiaBridge:'absent'});
api.updateD3DMetalSettings(holder);
assert(button(holder,"Ouvrir Steam DirectX 12"));
assert(button(holder,"Installer le pont DLSS → MetalFX"));
const original=holder.children[0];api.updateD3DMetalSettings(holder);assert.equal(holder.children[0],original,"Unchanged advanced controls retain their DOM");
Object.assign(game,{installed:true,canLaunch:false,launchBlockReason:'Steam doit être vérifié.'});api.renderGameDialog(game);
assert(button(body,"Terminer l’installation"));assert(!button(body,"Jouer"));assert(!button(body,"Ouvrir Steam DirectX 12"));
Object.assign(game,{canLaunch:true,launchBlockReason:''});api.renderGameDialog(game);
assert(button(body,"Jouer"),"An optional missing DLSS bridge cannot remove native-confirmed Play");
assert(!button(body,"Installer le pont DLSS → MetalFX"));
Object.assign(component,{status:'blocked',prepared:false,canPrepare:false});api.updateD3DMetalSettings(holder);
assert(button(holder,"Préparer DirectX 12").disabled,"Advanced setup respects authoritative canPrepare=false");
delete state.windowsRuntime.d3dMetal;api.updateD3DMetalSettings(holder);
assert(!button(holder,"Importer le composant Apple"),"No native capability means no fake advanced import");
state.windowsRuntime.d3dMetal = component;
state.renderProtectionEnabled = true;
const control = api.createRenderProtectionControl(),
  checkbox = control.children[0];
assert.equal(checkbox.checked, true);
checkbox.checked = false;
checkbox.handlers.change();
assert.equal(sent.at(-1).action, "setRenderProtection");
assert.equal(sent.at(-1).enabled, false);
assert(checkbox.disabled);
assert.equal(
  api.renderProtectionEnabled(),
  true,
  "Unchecking cannot release work before native acknowledgement",
);
context.ui.pendingRenderProtection = null;
state.renderProtectionEnabled = false;
const enabledControl = api.createRenderProtectionControl().children[0];
enabledControl.checked = true;
enabledControl.handlers.change();
assert.equal(
  api.renderProtectionEnabled(),
  true,
  "Enabling protection locks immediately while acknowledgement is pending",
);

// Native acknowledgements alone release protected actions; unrelated progress never does.
context.ui.view = "library";
context.ui.pendingRenderProtection = false;
context.state.renderProtectionEnabled = true;
context.received = true;
context.lastGamesSignature = JSON.stringify(context.state.games);
context.normalizedGame = (g) => g;
let experienceSyncs = 0;
context.appIntro = { after(callback) { callback(); } };
context.onboarding = { suggest() {} };
context.accountLogin = { sync() {} };
context.experience = { sync: () => { experienceSyncs++; } };
context.updateSidebar = () => {};
context.renderLibrary = () => {
  throw Error("Protection changes must not rebuild covers");
};
vm.runInNewContext(
  section("window.onNativeState =", "window.onNativeRuntime ="),
  context,
);
context.window.onNativeState({ renderProtectionEnabled: false });
assert.equal(context.ui.pendingRenderProtection, null);
assert.equal(api.renderProtectionEnabled(), false);
assert.equal(api.createRenderProtectionControl().children[0].checked, false);
context.state.renderProtectionEnabled = true;
context.ui.pendingRenderProtection = false;
vm.runInNewContext(
  section(
    "window.onNativeResult =",
    'document.querySelectorAll("[data-view]")',
  ),
  context,
);
context.window.onNativeResult({ ok: false, message: "Refusé" });
assert.equal(
  context.ui.pendingRenderProtection,
  null,
  "Rejected change restores a usable checkbox",
);
assert.equal(api.createRenderProtectionControl().children[0].checked, true);
assert.equal(
  api.renderProtectionEnabled(),
  true,
  "Rejected disable never releases actions",
);
context.state.executionPolicy = { mode: "no-wine", windowsExecutionAvailable: false };
context.state.renderProtectionEnabled = false;
context.ui.pendingRenderProtection = null;
const beforeNoWine = sent.length;
for (const action of ["setupWindowsRuntime", "installSteamWindows", "openWindowsSteam", "setupD3DMetalRuntime", "installSteamD3DMetal", "openD3DMetalSteam"])
  assert.equal(api.send(action), false, "No-Wine policy survives render protection being switched off: " + action);
assert.equal(sent.length, beforeNoWine, "No legacy execution request crossed the bridge");
assert.equal(api.send("cancelD3DMetalRuntime"), true, "Cancellation remains available");
assert.equal(sent.pop().action, "cancelD3DMetalRuntime");
console.log(
  "DX12/protection UI passed: explicit setup/cancel/Steam/install, no Play, guarded dispatch, safe default and acknowledgement gate",
);

assert(experienceSyncs > 0, "Big Picture receives native state acknowledgements");
