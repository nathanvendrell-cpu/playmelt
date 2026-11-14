"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const html = fs.readFileSync(path.join(__dirname, "..", "index.html"), "utf8");
const script = Array.from(html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g), m => m[1]).filter(Boolean).join("\n");
new vm.Script(script); // Parse the complete UI without running it.
const start = script.indexOf("function epicSessionPresent()");
const end = script.indexOf("function updateToolbar()", start);
const toolbarStart=script.indexOf("// --- Epic ---"), toolbarEnd=script.indexOf("// --- GOG ---",toolbarStart);
const listenerStart = script.indexOf('// Epic Platform Handlers');
const listenerEnd = script.indexOf('["all", "installed"].forEach', listenerStart);
assert(start > 0 && end > start && listenerStart > end && listenerEnd > listenerStart);
const elements = {};
const sent = [];
const context = {
  state: {epic:{available:true,authenticated:false,busy:false}, games:[], accounts:[], libraryStatus:{status:"local"}},
  ui: {view:"epic"},
  locale: new Intl.NumberFormat("fr-FR"),
  document: {querySelectorAll:() => []},
  renderProtectionEnabled: () => true,
  send: action => sent.push(action),
  $: id => elements[id] ||= {hidden:false, disabled:false, handlers:{}, classList:{toggle(){}}, addEventListener(name, action) {this.handlers[name] = action;}},
};
vm.runInNewContext(script.slice(start, end) + script.slice(listenerStart, listenerEnd) + "function updateToolbar(){const show=(id,visible)=>$(id).hidden=!visible;"+script.slice(toolbarStart,toolbarEnd)+"};this.update=updateToolbar;", context);
const disconnect = elements.epicDisconnectBtn;
let checks = 0;
function check(condition, label) {assert(condition, label); checks++;}
context.update();
check(disconnect.hidden, "No disconnect action without session");
disconnect.handlers.click();
check(sent.length === 0, "Hidden action cannot dispatch");
for (const storageStatus of ["stored", "restored", "delete-error"]) {
  context.state.epic = {available:false,authenticated:false,busy:false,storageStatus};
  context.update();
  check(!disconnect.hidden && !disconnect.disabled, "Persisted session can be explicitly removed even without connector");
  disconnect.handlers.click();
  check(sent.pop() === "disconnectEpic", "Removal only requests native confirmation");
}
context.state.epic = {available:true,authenticated:true,busy:false};
context.update();
check(!disconnect.hidden && !elements.epicPlugPlayBtn.hidden && !elements.epicPlugPlayBtn.disabled, "Sync and disconnect coexist");
check(elements.epicPlugPlayText.textContent === "Connecté", "Connection label preserved");
elements.epicPlugPlayBtn.handlers.click();
check(sent.pop() === "syncEpic", "Existing synchronization action preserved");
context.state.epic.busy = true;
context.update();
check(disconnect.disabled, "Busy connector disables disconnect");
disconnect.handlers.click();
check(sent.length === 0, "Busy state guards event handler as well as button");
context.state.epic.busy = false;
context.ui.view = "steam";
context.update();
check(disconnect.hidden, "Disconnect only appears in Epic view");
disconnect.handlers.click();
check(sent.length === 0, "Other views cannot dispatch disconnect");
context.ui.view = "epic";
for (const storageStatus of [undefined, "empty", "unknown", "read-error"]) {
  context.state.epic = {available:true,authenticated:false,busy:false,storageStatus};
  context.update();
  check(disconnect.hidden && elements.epicPlugPlayText.textContent === "Connexion", "Unverified storage does not invent a session");
}
elements.epicPlugPlayBtn.handlers.click();
check(sent.pop() === "connectEpic", "Existing connection action preserved");
const allowStart = script.indexOf("const allowedActions = new Set(");
const allowEnd = script.indexOf("const renderProtectedActions", allowStart);
const allowed = vm.runInNewContext(script.slice(allowStart, allowEnd) + ";allowedActions");
check(allowed.has("disconnectEpic"), "Native action is allowlisted");
console.log(`Epic session UI: ${checks} CPU fixture checks passed; no browser, account or keychain access`);
