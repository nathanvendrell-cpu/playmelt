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
  id: "steam:dx12",
  title: "Mortal Shell II",
  store: "steam",
  platforms: ["windows"],
  requiredRenderer: "d3dmetal",
  requiredGraphicsAPI: "DirectX12",
  runtimeId: "playmelt-d3dmetal",
  canLaunch: false,
  canInstall: false,
  canInstallAndPlay: false,
};
const body = elements.dialogBody;
api.openGame(game);
assert.equal(sent.length, 0, "Opening a DX12 sheet dispatches nothing");
assert.equal(
  api.renderProtectionEnabled(),
  true,
  "Absent protection field defaults to enabled",
);
assert(!button(body, "Préparer DirectX 12"), "Import precedes preparation");
assert(
  !button(body, "Importer le composant Apple").disabled,
  "Import is allowed during renders",
);
button(body, "Importer le composant Apple").handlers.click();
assert.equal(sent.pop().action, "importD3DMetal");
api.restoreD3DMetalImportControls();
assert(
  !button(body, "Importer le composant Apple").disabled,
  "Rejected import is retryable",
);
button(body, "Obtenir auprès d’Apple").handlers.click();
assert.equal(sent.pop().action, "openD3DMetalDownload");
component.imported = true;
api.renderGameDialog(game);
assert(button(body, "Préparer DirectX 12").disabled);
assert(
  !button(body, "Importer le composant Apple") &&
    !button(body, "Obtenir auprès d’Apple"),
  "Completed import removes obsolete actions",
);
for (const action of [
  "launchGame",
  "installGame",
  "installAndPlay",
  "openSteam",
  "openEpic",
  "setupWindowsRuntime",
  "installSteamWindows",
  "openWindowsSteam",
  "setupD3DMetalRuntime",
  "installSteamD3DMetal",
  "openD3DMetalSteam",
]) {
  assert.equal(
    api.send(action, { gameId: game.id }),
    false,
    action + " is blocked at dispatch even if an old handler survives",
  );
}
assert.equal(sent.length, 0);
for (const action of [
  "refresh",
  "syncLibrary",
  "syncEpic",
  "openSteamLogin",
  "cancelWindowsRuntime",
  "cancelInstallAndPlay",
  "cancelD3DMetalRuntime",
]) {
  api.send(action);
  assert.equal(sent.pop().action, action, "Read/auth/cancel remains available");
}
context.state.renderProtectionEnabled = false;
api.renderGameDialog(game);
const prepare = button(body, "Préparer DirectX 12");
assert(!prepare.disabled);
prepare.handlers.click();
prepare.handlers.click();
assert.equal(sent.length, 1, "Pending preparation cannot dispatch twice");
assert.equal(sent.pop().action, "setupD3DMetalRuntime");
for (const status of ["checking", "initializing", "stopping"]) {
  Object.assign(component, { status, busy: true, cancellable: true });
  api.renderGameDialog(game);
  assert(button(body, "Annuler") && !button(body, "Annuler").disabled);
  assert(!button(body, "Importer le composant Apple"));
  assert(!button(body, "Préparer DirectX 12"));
  assert(
    !all(body).some((n) => n.tag === "progress"),
    "No fabricated percent during DX12 setup",
  );
}
button(body, "Annuler").handlers.click();
assert.equal(sent.pop().action, "cancelD3DMetalRuntime");
Object.assign(component, {
  status: "ready",
  busy: false,
  cancellable: false,
  prepared: true,
  steamInstalled: false,
});
api.renderGameDialog(game);
assert.equal(sent.length, 0);
const steamInstaller = button(body, "Installer Steam pour DirectX 12");
steamInstaller.handlers.click();
assert.equal(sent.pop().action, "installSteamD3DMetal");
Object.assign(component, {
  steamBusy: true,
  steamPhase: "downloading",
  steamMessage: "Téléchargement de l’installateur officiel Steam…",
});
api.renderGameDialog(game);
const steamDownload = button(body, "Installer Steam pour DirectX 12");
assert(
  !steamDownload && steamInstaller.disabled,
  "DX12 Steam bootstrap blocks another install even when component.busy=false",
);
assert(!button(body, "Importer le composant Apple"));
steamInstaller.handlers.click();
assert.equal(
  sent.length,
  0,
  "A disabled DX12 Steam install cannot dispatch twice",
);
assert(all(body).some((n) => n.textContent === "Téléchargement de Steam…"));
assert(all(body).some((n) => n.title === component.steamMessage));
const downloadingControls = body.children[0];
component.steamPhase = "installer";
component.steamMessage =
  "Terminez l’installation dans la fenêtre officielle Steam.";
api.renderGameDialog(game);
assert.notEqual(
  body.children[0],
  downloadingControls,
  "A changed native Steam phase updates the compact status",
);
assert(all(body).some((n) => n.textContent === "Installation de Steam…"));
assert(all(body).some((n) => n.title === component.steamMessage));
assert(!button(body, "Installer Steam pour DirectX 12"));
assert(
  !button(body, "Annuler"),
  "Steam bootstrap does not advertise a runtime-only cancellation command",
);
component.steamBusy = false;
component.steamPhase = "failed";
component.steamMessage = "Installation Steam non terminée.";
api.renderGameDialog(game);
assert(all(body).some((n) => n.textContent === "Installation Steam échouée"));
assert(
  !button(body, "Installer Steam pour DirectX 12").disabled,
  "Failed Steam bootstrap can be retried explicitly",
);
component.steamPhase = "ready";
component.steamMessage = "Steam Windows est installé.";
component.steamInstalled = true;
game.canInstall = true;
api.renderGameDialog(game);
assert(
  !button(body, "Ouvrir Steam DirectX 12"),
  "Game installation is the single useful next action",
);
button(body, "Installer").handlers.click();
const installation = sent.pop();
assert.equal(installation.action, "installGame");
assert.equal(installation.runtimeId, "playmelt-d3dmetal");
assert.equal(installation.gameId, game.id);
assert(
  !button(body, "Jouer") && !button(body, "Installer et jouer"),
  "Installed Steam does not prove the game can run",
);
context.state.renderProtectionEnabled = true;
api.renderGameDialog(game);
assert(button(body, "Installer").disabled);
const holder = elements.d3dMetalSettings;
api.updateD3DMetalSettings(holder);
assert(button(holder, "Ouvrir Steam DirectX 12"));
assert(
  !button(holder, "Installer"),
  "Settings never installs an arbitrary game",
);
const original = holder.children[0];
api.updateD3DMetalSettings(holder);
assert.equal(holder.children[0], original, "Unchanged state retains controls");
for (const status of ["blocked", "failed", "cancelled"]) {
  Object.assign(component, {
    status,
    prepared: false,
    canPrepare: status === "cancelled",
  });
  api.renderGameDialog(game);
  assert.equal(
    button(body, "Préparer DirectX 12").disabled,
    true,
    "Protection blocks retries too",
  );
}
context.state.renderProtectionEnabled = false;
component.canPrepare = false;
api.renderGameDialog(game);
assert(
  button(body, "Préparer DirectX 12").disabled,
  "Native canPrepare=false is authoritative",
);
delete state.windowsRuntime.d3dMetal;
api.updateD3DMetalSettings(holder);
assert(
  !button(holder, "Importer le composant Apple"),
  "No native feature means no fake import",
);
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
console.log(
  "DX12/protection UI passed: explicit setup/cancel/Steam/install, no Play, guarded dispatch, safe default and acknowledgement gate",
);
