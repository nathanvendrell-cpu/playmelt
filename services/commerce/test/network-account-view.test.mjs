import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../public/account.js", import.meta.url), "utf8");
const html = readFileSync(new URL("../public/index.html", import.meta.url), "utf8");
const css = readFileSync(new URL("../public/account.css", import.meta.url), "utf8");
const TOKEN = "N".repeat(43);
const network = (extra = {}) => ({ enabled: true, phase: "change_required", activeNetworkMasked: "198.51.100.*", currentNetworkMasked: "203.0.113.*", changePending: false, ...extra });
const walk = (node) => [node, ...node.children.flatMap(walk)];
const findButton = (node, text) => walk(node).find((x) => x.tagName === "button" && x.textContent === text);
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(setImmediate); };

async function setup(options = {}) {
  const nodes = new Map(), calls = [], events = [];
  let url = new URL(options.url || "https://example.test/Playmelt/compte/");
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.attributes = {}; this.dataset = {}; this._text = ""; this.hidden = false; this.disabled = false; this.open = false; this.value = ""; this.isConnected = true; }
    set id(value) { this._id = value; nodes.set(value, this); }
    get id() { return this._id; }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map((x) => x.textContent).join(""); }
    set innerHTML(_) { throw Error("Remote content must stay text"); }
    append(...items) { this.children.push(...items.map((x) => { if (typeof x !== "string") return x; const n = new Element("#text"); n.textContent = x; return n; })); }
    replaceChildren(...items) { this._text = ""; this.children = []; this.append(...items); }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    addEventListener() {}
    get lastChild() { return this.children.at(-1); }
    focus() {}
    click() { if (!this.disabled) return this.onclick?.({ preventDefault() {} }); }
  }
  for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)) { const n = new Element(match[1]); n.id = match[2]; n.hidden = /\bhidden\b/.test(match[0]); }
  const f = { nodes, calls, events, enabled: options.enabled ?? true, state: options.state || network(), authenticated: options.authenticated ?? true, reply: options.reply };
  const me = { id: "network-user-fixture", email: "network@example.test", devices: [], entitlement: null, hasPassword: false, billingAvailable: false, isAdmin: false };
  const context = { URL, URLSearchParams, Intl,
    document: { getElementById: (id) => nodes.get(id), createElement: (tag) => new Element(tag), querySelector: () => ({ content: "/Playmelt/compte" }) },
    location: { get href() { return url.href; }, get origin() { return url.origin; }, get pathname() { return url.pathname; }, get search() { return url.search; }, get hash() { return url.hash; }, assign(target) { events.push({ assign: target }); } },
    history: { replaceState(_state, _title, target) { url = new URL(target, url); events.push({ replace: url.href }); } },
    localStorage: new Proxy({}, { get() { throw Error("Token persistence forbidden"); } }),
    sessionStorage: new Proxy({}, { get() { throw Error("Token persistence forbidden"); } }),
    fetch: async (target, init) => {
      const path = target.split("/v1/")[1], body = init.body === undefined ? undefined : JSON.parse(init.body);
      const call = { path, body, method: init.method, credentials: init.credentials, urlAtRequest: url.href };
      calls.push(call); events.push({ fetch: path });
      const overridden = await f.reply?.(call, f);
      if (overridden) return { ok: !overridden.error, json: async () => overridden };
      const defaults = { me: f.authenticated ? me : { error: "sign_in_required" }, "network/config": { networkEnabled: f.enabled }, network: f.state,
        "download/status": { available: false }, "billing/status": { enabled: false }, legal: { url: "/legal", version: "fixture" }, "auth/providers": { google: false } };
      if (path === "auth/login") { f.authenticated = true; return { ok: true, json: async () => ({ signedIn: true }) }; }
      if (path === "network/change") { f.state.changePending = true; return { ok: true, json: async () => ({ requested: true }) }; }
      if (path === "network/confirm") { f.state.changePending = false; return { ok: true, json: async () => ({ changed: true }) }; }
      const value = defaults[path] || {};
      return { ok: !value.error, json: async () => value };
    },
  };
  vm.createContext(context); vm.runInContext(source, context, { timeout: 1000 });
  f.evaluate = (code) => vm.runInContext(code, context);
  f.panel = nodes.get("network");
  await flush();
  return f;
}

test("network is a hidden row section with a safe anchor and referrer policy before external resources", () => {
  assert.match(html, /<section id="network" class="network-section"[^>]*hidden/);
  assert.ok(html.indexOf('name="referrer" content="no-referrer"') < html.indexOf('<link'));
  assert.match(css, /\.network-row\s*\{[^}]*display:\s*flex/);
  assert.doesNotMatch(css, /\.network[^}]*display:\s*grid/);
  assert.match(css, /\.network-actions\s*\{[^}]*flex-wrap:\s*wrap/);
});

test("flag off never fetches private network state, promises a policy or sends a mail", async () => {
  const f = await setup({ enabled: false });
  assert.equal(f.panel.hidden, true);
  assert.equal(f.calls.filter((x) => x.path === "network").length, 0);
  assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
  assert.doesNotMatch(f.panel.textContent, /illimité|adresse IP/);
  assert.equal(f.nodes.get("workspace").hidden, false);
  assert.ok(f.nodes.get("support-form").onsubmit);
});

test("GET is proposed only after authentication and a network link survives inline sign-in in memory", async () => {
  const f = await setup({ authenticated: false, url: `https://example.test/Playmelt/compte/#networkToken=${TOKEN}` });
  assert.equal(f.calls.some((x) => x.path.startsWith("network")), false);
  assert.match(f.nodes.get("account").textContent, /compte qui a reçu l’e-mail/);
  assert.match(f.nodes.get("account").textContent, /connexion Google.*rouvrez ce lien/);
  assert.equal(f.events[0].replace, "https://example.test/Playmelt/compte/#network");
  const form = walk(f.nodes.get("account")).find((x) => x.tagName === "form");
  await form.onsubmit({ preventDefault() {} });
  assert.ok(findButton(f.panel, "Confirmer mon réseau"));
  assert.equal(f.calls.filter((x) => x.path === "network/confirm").length, 0);
  assert.ok(f.calls.every((x) => !x.urlAtRequest.includes(TOKEN)));
});

test("unbound and active networks have no mutation button; another IP explicitly offers validation", async () => {
  for (const phase of ["unbound", "active", "change_required"]) {
    const f = await setup({ state: network({ phase }) });
    assert.equal(f.panel.hidden, false);
    assert.match(f.panel.textContent, /nombre illimité de machines sur ce même réseau/);
    assert.match(f.panel.textContent, /compte, l’assistance et les paiements restent accessibles/);
    assert.equal(!!findButton(f.panel, "Valider ce réseau par e-mail"), phase === "change_required");
    if (phase === "unbound") assert.match(f.panel.textContent, /première utilisation autorisée/);
    assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
  }
});

test("only masked IPv4/IPv6 are rendered and untrusted network content cannot become markup", async () => {
  const f = await setup({ state: network({ activeNetworkMasked: "2606:4700:4700:…" }) });
  assert.match(f.panel.textContent, /2606:4700:4700:…/);
  assert.match(f.panel.textContent, /203\.0\.113\.\*/);
  for (const value of ["198.51.100.27", "2606:4700:4700::1111", '<img src=x onerror="bad()">', "1".repeat(200)]) {
    f.state.currentNetworkMasked = value;
    await f.evaluate("showNetwork(accountUser)");
    assert.ok(!f.panel.textContent.includes(value));
    assert.match(f.panel.textContent, /Réseau masqué|Non enregistré/);
    assert.equal(walk(f.panel).some((x) => x.tagName === "img"), false);
  }
});

test("a change request posts the exact empty body once, then shows honest SMTP waiting feedback", async () => {
  let finish;
  const gate = new Promise((resolve) => { finish = resolve; });
  const f = await setup({ reply: async (call) => { if (call.path === "network/change") { await gate; return { requested: true }; } } });
  const control = findButton(f.panel, "Valider ce réseau par e-mail");
  const action = control.click(); control.click();
  assert.equal(control.disabled, true);
  finish(); await action;
  const calls = f.calls.filter((x) => x.path === "network/change");
  assert.equal(calls.length, 1); assert.deepEqual(calls[0].body, {});
  assert.equal(calls[0].credentials, "same-origin");
  assert.match(f.panel.textContent, /confiée au service d’envoi/);
  assert.doesNotMatch(f.panel.textContent, /e-mail.*livré/);
  assert.ok(f.calls.every((x) => !x.body || !("ip" in x.body)));
});

test("pending state does not resend email; active IP cannot overwrite a request created elsewhere", async () => {
  for (const phase of ["change_required", "active"]) {
    const f = await setup({ state: network({ phase, changePending: true }) });
    assert.match(f.panel.textContent, /validation est en attente/);
    assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
    assert.equal(!!findButton(f.panel, "Demander un nouvel e-mail"), phase === "change_required");
  }
});

test("fragment and legacy query tokens are removed before fetch and confirmed only by an explicit dedicated POST", async () => {
  for (const suffix of [`#networkToken=${TOKEN}`, `?networkToken=${TOKEN}`]) {
    const f = await setup({ url: "https://example.test/Playmelt/compte/" + suffix });
    assert.equal(f.events[0].replace, "https://example.test/Playmelt/compte/#network");
    assert.ok(!f.panel.textContent.includes(TOKEN));
    assert.match(f.panel.textContent, /téléphone ne remplace pas celui de la demande/);
    assert.equal(f.calls.filter((x) => x.path === "network/confirm").length, 0);
    await findButton(f.panel, "Confirmer mon réseau").click();
    const confirmation = f.calls.find((x) => x.path === "network/confirm");
    assert.deepEqual(confirmation.body, { token: TOKEN });
    assert.equal(confirmation.credentials, "same-origin");
    assert.equal(f.calls.some((x) => ["download/claim", "auth/confirm"].includes(x.path)), false);
    assert.match(f.panel.textContent, /réseau de votre demande est maintenant autorisé/);
    assert.equal(findButton(f.panel, "Confirmer mon réseau"), undefined);
    assert.ok(f.calls.every((x) => !x.urlAtRequest.includes(TOKEN)));
  }
});

test("malformed or ambiguous network links are never submitted or printed", async () => {
  for (const suffix of ["#networkToken=bad", `?networkToken=${TOKEN}#networkToken=${TOKEN}`, `?networkToken=${TOKEN}&networkToken=${TOKEN}`]) {
    const f = await setup({ url: "https://example.test/Playmelt/compte/" + suffix });
    assert.equal(findButton(f.panel, "Confirmer mon réseau"), undefined);
    assert.match(f.panel.textContent, /lien de validation réseau est invalide/);
    assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
    assert.ok(!f.panel.textContent.includes(TOKEN));
    assert.equal(f.events[0].replace, "https://example.test/Playmelt/compte/#network");
  }
});

test("expired and superseded confirmations give actionable feedback without automatic resend", async () => {
  for (const error of ["invalid_network_challenge", "network_change_superseded"]) {
    const f = await setup({ url: `https://example.test/Playmelt/compte/#networkToken=${TOKEN}`, reply: (call) => call.path === "network/confirm" ? { error } : undefined });
    await findButton(f.panel, "Confirmer mon réseau").click();
    assert.match(f.panel.textContent, error === "invalid_network_challenge" ? /expiré.*compte destinataire/ : /remplacé cette demande/);
    assert.equal(findButton(f.panel, "Confirmer mon réseau"), undefined);
    assert.equal(f.calls.filter((x) => x.method === "POST").length, 1);
    assert.equal(f.calls.some((x) => x.path === "network/change"), false);
  }
});

test("temporary SMTP/source/rate failures are friendly and never claim a successful request", async () => {
  for (const [error, copy] of [["network_email_unavailable", /n’a pas pu être confirmé/], ["network_source_unavailable", /ne peut pas être vérifié/], ["too_many_requests", /Patientez quelques minutes/]]) {
    const f = await setup({ reply: (call) => call.path === "network/change" ? { error } : undefined });
    await findButton(f.panel, "Valider ce réseau par e-mail").click();
    assert.match(f.panel.textContent, copy);
    assert.doesNotMatch(f.panel.textContent, /demande a été confiée/);
    assert.equal(f.calls.filter((x) => x.path === "network/change").length, 1);
    assert.ok(findButton(f.panel, "Valider ce réseau par e-mail"));
  }
});

test("a temporary confirmation failure retains only the in-memory token for an explicit retry", async () => {
  const f = await setup({ url: `https://example.test/Playmelt/compte/#networkToken=${TOKEN}`, reply: (call) => call.path === "network/confirm" ? { error: "service_unavailable" } : undefined });
  await findButton(f.panel, "Confirmer mon réseau").click();
  assert.match(f.panel.textContent, /temporairement indisponible/);
  assert.ok(findButton(f.panel, "Confirmer mon réseau"));
  assert.equal(f.calls.filter((x) => x.path === "network/confirm").length, 1);
  assert.ok(!f.panel.textContent.includes(TOKEN));
});

test("network load failure stays local and never hides account, password or support", async () => {
  const f = await setup({ reply: (call) => call.path === "network" ? { error: "service_unavailable" } : undefined });
  assert.ok(findButton(f.panel, "Réessayer"));
  assert.equal(f.nodes.get("workspace").hidden, false);
  assert.ok(f.nodes.get("password-content").children.length);
  assert.ok(f.nodes.get("support-form").onsubmit);
  assert.ok(f.nodes.get("licence").children.length);
});

test("disabled policy invalidates a captured link without mutation or false confirmation", async () => {
  const f = await setup({ enabled: false, url: `https://example.test/Playmelt/compte/#networkToken=${TOKEN}` });
  assert.equal(f.panel.hidden, true);
  assert.match(f.nodes.get("status").textContent, /n’est pas activée/);
  assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
});

test("network confirmation cannot consume a simultaneous dedicated download token", async () => {
  const download = "D".repeat(43);
  const f = await setup({ url: `https://example.test/Playmelt/compte/?networkToken=${TOKEN}#download=${download}` });
  await findButton(f.panel, "Confirmer mon réseau").click();
  assert.equal(f.evaluate("downloadToken"), download);
  assert.equal(f.evaluate("networkToken"), null);
  assert.equal(f.calls.some((x) => ["download/claim", "auth/confirm"].includes(x.path)), false);
  assert.ok(f.calls.every((x) => !x.urlAtRequest.includes(TOKEN) && !x.urlAtRequest.includes(download)));
});

test("an expired existing session clears previous network feedback and its challenge", async () => {
  const f = await setup({ url: `https://example.test/Playmelt/compte/#networkToken=${TOKEN}` });
  f.authenticated = false;
  await f.evaluate("reload()");
  assert.equal(f.evaluate("networkToken"), null);
  assert.equal(f.evaluate("networkFeedback"), null);
  assert.equal(f.panel.hidden, true);
  assert.equal(f.calls.filter((x) => x.method === "POST").length, 0);
});
