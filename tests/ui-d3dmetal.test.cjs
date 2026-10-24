"use strict";
const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const start = html.indexOf("function openGame(game)"),
  end = html.indexOf("function renderLibrary()", start);
assert(start > 0 && end > start);
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
    showModal() {
      this.open = true;
    },
    close() {
      this.open = false;
    },
  };
}
const elements = Object.fromEntries(
  ["dialogTitle", "dialogStore", "dialogBody", "gameDialog"].map((id) => [
    id,
    node("div"),
  ]),
);
const sent = [];
const component = {
  status: "missing",
  message: "Composant absent",
  imported: false,
  abiStatus: "unknown",
  loadTested: false,
  gameTested: false,
  busy: false,
};
const state = {
  games: [],
  runtimes: [{ id: "wine", platform: "windows", available: true }],
  windowsRuntime: {
    status: "ready",
    readyEngine: true,
    steamInstalled: true,
    d3dMetal: component,
  },
};
const context = {
  state,
  ui: { dialogGameId: null },
  $: (id) => elements[id],
  document: {
    getElementById: (id) => elements[id] || null,
    querySelectorAll: () =>
      all(elements.dialogBody).filter((n) => n.dataset.pendingD3dImport),
  },
  el: node,
  send: (action, payload) => sent.push({ action, payload }),
  platforms: (g) => g.platforms || [],
  platformLabel: () => "Windows",
  storeName: () => "Steam",
};
const api = vm.runInNewContext(
  html.slice(start, end) +
    ";({openGame,renderGameDialog,createD3DMetalControls,updateD3DMetalSettings,refreshVisibleDialog,restoreD3DMetalImportControls})",
  context,
);
const game = {
  id: "steam:dx12",
  title: "Mortal Shell II",
  store: "steam",
  platforms: ["windows"],
  requiredRenderer: "d3dmetal",
  requiredGraphicsAPI: "DirectX12",
  canLaunch: true,
  canInstall: true,
  canInstallAndPlay: true,
};
function all(root) {
  return [root, ...root.children.flatMap(all)];
}
function button(root, label) {
  return all(root).find((n) => n.tag === "button" && n.textContent === label);
}
api.openGame(game);
assert.equal(
  sent.length,
  0,
  "Opening DX12 configuration never starts a game, runtime or import",
);
assert(all(elements.dialogBody).some((n) => n.textContent === "DirectX 12"));
const importer = button(elements.dialogBody, "Importer le composant Apple");
assert(importer && !importer.disabled);
assert(
  !button(elements.dialogBody, "Jouer") &&
    !button(elements.dialogBody, "Configurer le moteur") &&
    !button(elements.dialogBody, "Installer et jouer"),
  "DX12 takes precedence even if another engine reports launch/install capabilities",
);
const download = button(elements.dialogBody, "Obtenir auprès d’Apple");
download.handlers.click();
assert.equal(sent[0].action, "openD3DMetalDownload");
importer.handlers.click();
assert.equal(sent[1].action, "importD3DMetal");
assert.equal(importer.disabled, true);
api.restoreD3DMetalImportControls();
assert.equal(
  importer.disabled,
  false,
  "Rejected native import can be retried without reopening the app",
);
component.busy = true;
api.renderGameDialog(game);
assert(button(elements.dialogBody, "Importer le composant Apple").disabled);
assert(button(elements.dialogBody, "Obtenir auprès d’Apple").disabled);
component.busy = false;
component.imported = true;
component.abiStatus = "pending";
api.renderGameDialog(game);
assert(
  all(elements.dialogBody).some(
    (n) => n.textContent === "Importé — validation restante",
  ),
);
assert(
  !all(elements.dialogBody).some(
    (n) => n.textContent === "Prêt" || n.textContent === "Jouer",
  ),
);
const holder = node("div");
api.updateD3DMetalSettings(holder);
assert(
  button(holder, "Importer le composant Apple") &&
    !button(holder, "Importer le composant Apple").disabled,
  "Settings configuration does not require owning a game",
);
const original = holder.children[0];
api.updateD3DMetalSettings(holder);
assert.equal(
  holder.children[0],
  original,
  "Unchanged settings retain their controls",
);
state.windowsRuntime.status = "downloading";
api.updateD3DMetalSettings(holder);
assert(
  button(holder, "Importer le composant Apple").disabled,
  "Import is unavailable during engine setup",
);
state.windowsRuntime.status = "ready";
delete state.windowsRuntime.d3dMetal;
api.updateD3DMetalSettings(holder);
assert(
  button(holder, "Importer le composant Apple").disabled,
  "No native capability means no enabled fake import",
);
console.log(
  "DX12 UI passed: configuration only, explicit Apple actions, busy guards, imported is not ready, settings independent of ownership",
);
