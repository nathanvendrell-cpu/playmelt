"use strict";
const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const section = (start, end) => {
  const a = html.indexOf(start),
    b = html.indexOf(end, a);
  assert(a > 0 && b > a);
  return html.slice(a, b);
};
function node(tag, cls, text) {
  return {
    tag,
    cls,
    textContent: text || "",
    children: [],
    dataset: {},
    handlers: {},
    append(...nodes) {
      this.children.push(...nodes);
    },
    replaceChildren(...nodes) {
      this.children = nodes;
    },
    addEventListener(name, fn) {
      this.handlers[name] = fn;
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
  ["dialogTitle", "dialogStore", "dialogBody", "gameDialog", "diagnostics"].map(
    (id) => [id, node("div")],
  ),
);
const all = (root) => [root, ...root.children.flatMap(all)],
  button = (label) =>
    all(elements.dialogBody).find(
      (n) => n.tag === "button" && n.textContent === label,
    );
const sent = [];
const native = {
  id: "steam-mac",
  name: "Steam macOS",
  displayName: "Mac natif",
  platform: "mac",
  available: true,
};
const dx11 = {
  id: "playmelt-windows",
  name: "Windows",
  displayName: "DirectX 11",
  platform: "windows",
  renderer: "dxmt",
  available: true,
};
const dx12 = {
  id: "playmelt-d3dmetal",
  name: "DX12",
  displayName: "DirectX 12",
  platform: "windows",
  renderer: "d3dmetal",
  available: true,
  graphicsValidated: false,
};
const context = {
  state: {
    renderProtectionEnabled: false,
    games: [],
    runtimes: [native, dx11, dx12],
    hardware: {},
    warnings: [],
    libraryStatus: {},
    windowsRuntime: {
      status: "ready",
      readyEngine: true,
      steamInstalled: true,
      d3dMetal: {
        status: "ready",
        imported: true,
        prepared: true,
        steamInstalled: true,
        busy: false,
        canLaunch: false,
      },
    },
  },
  ui: { dialogGameId: null },
  $: (id) => elements[id],
  el: node,
  document: {
    getElementById: (id) => elements[id] || null,
    querySelectorAll: () => [],
  },
  send: (action, payload) => sent.push({ action, payload }),
  platforms: (game) => game.platforms || [],
  platformLabel: () => "",
  storeName: () => "Steam",
  locale: new Intl.NumberFormat("fr-FR"),
  Option: function (text, value) {
    const option = node("option", "", text);
    option.value = value;
    return option;
  },
};
const api = vm.runInNewContext(
  section("const renderProtectedActions =", "function el(") +
    section("function renderProtectionEnabled()", "function renderLibrary()") +
    section("function fact(", "function render()") +
    ";({openGame,installationRoutes,createWindowsRuntimeControls,renderDiagnostics})",
  context,
);
const game = {
  id: "steam:mac",
  store: "steam",
  title: "Native game",
  platforms: ["mac"],
  canInstall: true,
  canInstallAndPlay: true,
  runtimeId: native.id,
  installRoutes: [
    { runtimeId: native.id, canInstall: true, canInstallAndPlay: true },
    { runtimeId: dx11.id, canInstall: true, canInstallAndPlay: true },
  ],
};
api.openGame(game);
assert.equal(sent.length, 0);
assert(all(elements.dialogBody).some((n) => n.textContent === "Mac natif"));
assert(
  !all(elements.dialogBody).some((n) => n.tag === "select"),
  "A single route does not add a pointless selector",
);
button("Installer et jouer").handlers.click();
assert.equal(sent.pop().payload.runtimeId, native.id);
const windowsGame = {
  ...game,
  id: "steam:526870",
  title: "Satisfactory",
  platforms: ["windows"],
  runtimeId: dx11.id,
  requiredRenderer: "dxmt",
  installRoutes: [
    { runtimeId: dx11.id, canInstall: true, canInstallAndPlay: true },
    { runtimeId: dx12.id, canInstall: true, canInstallAndPlay: true },
  ],
};
api.openGame(windowsGame);
assert.deepEqual(
  Array.from(api.installationRoutes(windowsGame), (r) => r.runtime.id),
  [dx11.id],
  "DX11 profile rejects D3DMetal even if a stale option contains it",
);
assert(all(elements.dialogBody).some((n) => n.textContent === "DirectX 11"));
button("Installer et jouer").handlers.click();
assert.equal(sent.pop().payload.runtimeId, dx11.id);
const selectable = {
  ...windowsGame,
  id: "steam:other",
  requiredRenderer: "auto",
};
api.openGame(selectable);
const select = all(elements.dialogBody).find((n) => n.tag === "select");
assert(select && select.children.length === 2);
select.value = dx12.id;
select.handlers.change();
assert(
  button("Installer") && !button("Installer et jouer"),
  "Unvalidated DX12 route cannot inherit auto-launch from DX11",
);
button("Installer").handlers.click();
const install = sent.pop();
assert.equal(install.action, "installGame");
assert.equal(install.payload.runtimeId, dx12.id);
const legacy = { ...selectable };
delete legacy.installRoutes;
assert.deepEqual(
  Array.from(api.installationRoutes(legacy), (r) => r.runtime.id),
  [dx11.id],
  "Legacy snapshots are limited to the native-selected runtime",
);
const noPlatform = { ...legacy, platforms: [], canLaunch: false };
api.openGame(noPlatform);
assert.equal(api.installationRoutes(noPlatform).length, 0);
assert(
  !button("Jouer") && !button("Installer et jouer") && !button("Installer"),
  "Unknown platform has no invented game action",
);
const unavailable = { ...windowsGame, installRoutes: [], canLaunch: false };
context.state.windowsRuntime.status = "future-unknown";
api.openGame(unavailable);
assert(all(elements.dialogBody).some((n) => n.textContent === "État inconnu"));
assert(
  !all(elements.dialogBody).some((n) => n.tag === "button"),
  "Unknown engine state cannot enable setup",
);
for (const [runtime, label] of [
  [{ status: "missing", readyEngine: false }, "Préparer DirectX 11"],
  [
    { status: "ready", readyEngine: true, steamInstalled: false },
    "Installer Steam pour DirectX 11",
  ],
  [
    { status: "ready", readyEngine: true, steamInstalled: true },
    "Ouvrir Steam DirectX 11",
  ],
]) {
  context.state.windowsRuntime = runtime;
  const controls = api.createWindowsRuntimeControls();
  assert(
    all(controls).some((n) => n.tag === "button" && n.textContent === label),
  );
}
context.state.renderProtectionEnabled = true;
assert(
  all(api.createWindowsRuntimeControls()).find((n) => n.tag === "button")
    .disabled,
  "Settings keep render protection",
);
context.state.windowsRuntime = {
  status: "ready",
  readyEngine: true,
  steamInstalled: true,
  d3dMetal: {
    status: "ready",
    imported: true,
    prepared: true,
    steamInstalled: true,
  },
};
api.renderDiagnostics();
const settings = all(elements.diagnostics);
for (const label of ["Mac natif", "DirectX 11", "DirectX 12"])
  assert.equal(
    settings.filter((n) => n.textContent === label).length,
    1,
    "One settings row per route: " + label,
  );
assert(
  !settings.some(
    (n) =>
      n.textContent === "Importer le composant Apple" ||
      n.textContent === "Obtenir auprès d’Apple",
  ),
  "Completed import adds no obsolete settings links",
);
context.state.executionPolicy = { mode: "no-wine", windowsExecutionAvailable: false };
context.state.renderProtectionEnabled = false;
assert.equal(api.installationRoutes(windowsGame).length, 0, "No-Wine policy rejects cached available Windows routes");
assert.equal(api.installationRoutes(game).length, 1, "Native route remains usable");
api.openGame({ ...windowsGame, canLaunch: true, requiredRenderer: "d3dmetal" });
assert(!all(elements.dialogBody).some((n) => n.tag === "button"), "A stale game flag cannot expose Wine or setup from the game sheet");
api.renderDiagnostics();
assert(!all(elements.diagnostics).some((n) => n.tag === "button" && /DirectX|Steam pour/.test(n.textContent)), "No Wine setup actions remain in settings");
console.log(
  "Route UI passed: native/DX11/DX12 capabilities, unknown states, one next action, unique settings rows and protected defaults",
);
