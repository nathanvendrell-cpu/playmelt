import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import vm from "node:vm";

const source = readFileSync(new URL("../public/admin.js", import.meta.url), "utf8");
const workspace = source.slice(source.indexOf("// Client workspace:"), source.indexOf("// Registration queue."));
const labels = source.slice(source.indexOf("function accessLabel("), source.indexOf("// Client workspace:"));
const nodeSource = source.slice(source.indexOf("function node("), source.indexOf("async function api("));
const badgeSource = source.slice(source.indexOf("const badge ="), source.indexOf("function renderOverview("));

function fixtureUser(extra = {}) {
  return { asOf: 1900000000, id: "client-fixture", email: "partenaire@example.test", created: 1899000000,
    isInternal: false, methods: { password: false, google: true, emailLinkObserved: false },
    lastLogin: 1899999900, lastPair: null, access: null, billingLinked: false, trial: null,
    downloadRequests: { total: 1, lastRequested: 1899999900 },
    entitlements: { total: 0, items: [] }, devices: { total: 0, items: [] },
    payments: { total: 0, items: [] }, support: { total: 0, items: [] }, ownerCodes: { total: 0, items: [] },
    promotionAudit: { total: 0, items: [] }, revocablePromotions: [],
    lifetimeAccess: { available: true, canGrant: true, revocableGrants: [], audit: { total: 0, items: [] } }, ...extra };
}
function setup(user = fixtureUser()) {
  let focused = null;
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.attributes = {}; this.dataset = {}; this._text = ""; this.hidden = false; this.disabled = false; this.checked = false; this.value = ""; }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map((x) => x.textContent).join(""); }
    set innerHTML(_) { throw Error("Untrusted markup must not enter the client workspace"); }
    append(...items) { this.children.push(...items); }
    replaceChildren(...items) { this._text = ""; this.children = [...items]; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    getAttribute(key) { return this.attributes[key] ?? null; }
    get childElementCount() { return this.children.length; }
    querySelector(tag) { return walk(this).find((x) => x.tagName === tag) || null; }
    focus() { focused = this; }
    click() { if (!this.disabled) this.onclick?.({ preventDefault() {} }); }
    scrollIntoView() {}
  }
  const elements = { "admin-status": new Element("p"), "accounts-list": new Element("div"), "account-detail": new Element("section") }, calls = [], refreshes = [];
  const context = { document: { createElement: (tag) => new Element(tag) }, Node: Element, crypto: { randomUUID },
    $: (id) => elements[id], count: (n) => String(n ?? "—"), date: (n) => n ? String(n) : "—", money: (n) => (n / 100) + " EUR",
    detailRequest: 0, activeClientID: null, clientTab: "account", lastAccountTrigger: null,
    supportStatusNames: { open: "Ouvert" },
    api: async (path, body) => { calls.push({ path, body }); if (context.failMutation && body) throw Error("Réseau indisponible"); return body ? { id: "grant-fixture", plan: "lifetime", until: 1900604800 } : user; },
    loadAccounts: async () => { refreshes.push(true); } };
  vm.createContext(context); vm.runInContext(nodeSource + badgeSource + labels + workspace, context);
  return { context, elements, calls, refreshes, user, focused: () => focused };
}
function walk(node) { return [node, ...node.children.flatMap(walk)]; }
function find(node, tag, text) { return walk(node).find((x) => x.tagName === tag && x.textContent === text); }
function fields(form) { return { reason: find(form, "textarea", ""), confirm: walk(form).find((x) => x.tagName === "input" && x.type === "checkbox"), save: walk(form).find((x) => x.tagName === "button" && x.type !== "button") }; }
const submit = (form) => form.onsubmit({ preventDefault() {} });

test("the client workspace prioritizes identity/access/actions and omits empty secondary tabs", () => {
  const f = setup(), view = f.context.renderClientDetail(f.user), tabs = walk(view).filter((x) => x.attributes.role === "tab");
  assert.equal(tabs.length, 1); assert.equal(tabs[0].textContent, "Compte");
  assert.ok(view.textContent.includes(f.user.email)); assert.match(view.textContent, /Google associé/);
  assert.equal(find(view, "button", "Attribuer à vie").disabled, false);
  assert.equal(find(view, "button", "Accès temporaire").disabled, false);
  assert.doesNotMatch(view.textContent, /Aucun élément enregistré|Aucun paiement|Aucun appareil|Aucune demande reçue/);
  assert.equal(walk(view).filter((x) => x.tagName === "form").length, 0, "grant forms are not expanded or created before explicit choice");
});
test("list/detail navigation preserves the list and closes back to its trigger", async () => {
  const f = setup(), trigger = { focus() { f.context.triggerFocused = true; } }; f.context.lastAccountTrigger = trigger;
  await f.context.loadAccountDetail(f.user.id);
  assert.equal(f.elements["accounts-list"].hidden, true); assert.equal(f.elements["account-detail"].hidden, false);
  find(f.elements["account-detail"], "button", "← Tous les clients").click();
  assert.equal(f.elements["accounts-list"].hidden, false); assert.equal(f.elements["account-detail"].hidden, true); assert.equal(f.context.triggerFocused, true);
});
test("lifetime is fail-closed until capability and permits paid-preserving attribution separately from a promotion", () => {
  for (const lifetimeAccess of [undefined, { available: false, canGrant: true }, { available: true, canGrant: false, blockedReason: "Accès à vie déjà actif" }]) {
    const f = setup(fixtureUser({ lifetimeAccess })), view = f.context.renderClientDetail(f.user);
    find(view, "button", "Attribuer à vie").click(); assert.equal(walk(view).filter((x) => x.tagName === "form").length, 0);
  }
  const f = setup(fixtureUser({ access: { plan: "monthly", phase: "active", until: 1901000000 } })), view = f.context.renderClientDetail(f.user);
  assert.equal(find(view, "button", "Attribuer à vie").disabled, false); assert.equal(find(view, "button", "Accès temporaire").disabled, true);
  find(view, "button", "Attribuer à vie").click();
  const form = walk(view).find((x) => x.tagName === "form");
  assert.match(form.textContent, /facturation Stripe éventuelle reste inchangée/); assert.match(form.textContent, /accès à vie à partenaire@example.test/);
});
test("lifetime confirmation requires a reason and exact beneficiary acknowledgement; retries keep the same idempotency key", async () => {
  const f = setup(), form = f.context.clientActionForm(f.user, "lifetime"), input = fields(form);
  await submit(form); assert.equal(f.calls.length, 0);
  input.reason.value = "Accès partenaire"; await submit(form); assert.equal(f.calls.length, 0);
  input.confirm.checked = true; f.context.failMutation = true; await submit(form);
  const first = f.calls[0]; assert.equal(first.path, "admin/accounts/client-fixture/lifetime");
  assert.deepEqual(Object.keys(first.body).sort(), ["confirmed", "reason", "requestId"]); assert.equal(first.body.confirmed, true); assert.equal(first.body.reason, "Accès partenaire");
  f.context.failMutation = false; await submit(form);
  assert.equal(f.calls[1].body.requestId, first.body.requestId); assert.equal(f.refreshes.length, 1);
  assert.match(f.elements["admin-status"].textContent, /Accès à vie attribué/);
});
test("temporary and scoped lifetime revocation use distinct exact endpoints and payloads", async () => {
  const f = setup(), promo = f.context.clientActionForm(f.user, "promotion"), p = fields(promo);
  const duration = walk(promo).find((x) => x.tagName === "select"); duration.value = "30"; p.reason.value = "Campagne de découverte"; p.confirm.checked = true; await submit(promo);
  assert.equal(f.calls[0].path, "admin/accounts/client-fixture/promotions"); assert.equal(f.calls[0].body.days, 30);
  const revoke = f.context.clientActionForm(f.user, "revoke-lifetime", { id: "admin_lifetime_fixture" }), r = fields(revoke); r.reason.value = "Fin du partenariat"; r.confirm.checked = true; await submit(revoke);
  assert.equal(f.calls[1].path, "admin/accounts/client-fixture/lifetime/admin_lifetime_fixture/revoke"); assert.equal("days" in f.calls[1].body, false);
});
test("real secondary data creates keyboard-operable tabs and all remote content remains text", () => {
  const payload = '<img src=x onerror="bad()">';
  const f = setup(fixtureUser({ email: payload, methods: { google: true }, devices: { total: 1, items: [{ label: payload, created: 1899900000, revoked: 0 }] },
    lifetimeAccess: { available: true, canGrant: true, revocableGrants: [], audit: { total: 1, items: [{ action: "grant", actor: payload, reason: payload, created: 1899990000 }] } } }));
  const view = f.context.renderClientDetail(f.user), tabs = walk(view).filter((x) => x.attributes.role === "tab");
  assert.equal(tabs.length, 3); assert.match(view.textContent, /<img src=x/); assert.equal(walk(view).some((x) => x.tagName === "img"), false);
  tabs[0].onkeydown({ key: "ArrowRight", preventDefault() {} });
  assert.equal(tabs[1].getAttribute("aria-selected"), "true"); assert.equal(f.focused(), tabs[1]);
  assert.equal(walk(view).find((x) => x.id === "client-panel-devices").hidden, false);
});
