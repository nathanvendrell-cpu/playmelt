"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), path = require("node:path"), vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../Resources/GameMedia.js"), "utf8");
const walk = node => [node, ...node.children.flatMap(walk)];
const yt = (extra = {}) => ({ id: "youtube-fixture", title: "Trailer officiel", kind: "trailer", provider: "youtube", youtubeId: "AbCdEf123_-", thumbnail: "https://i.ytimg.com/vi/AbCdEf123_-/hqdefault.jpg", sourceUrl: "https://www.youtube.com/watch?v=AbCdEf123_-", officialSource: true, ...extra });
const image = (extra = {}) => ({ id: "image-fixture", url: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/123/ss_fixture.jpg", thumbnail: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/123/ss_fixture_thumb.jpg", sourceUrl: "https://store.steampowered.com/app/123/", ...extra });
function setup(sendOverride) {
  const ids = new Map(), calls = [], doc = { focused: null };
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.attributes = {}; this._text = ""; this.parent = null; this.hidden = false; this.listeners = {}; }
    set id(value) { this._id = value; ids.set(value, this); } get id() { return this._id; }
    set textContent(value) { this._text = String(value); this.children = []; } get textContent() { return this._text + this.children.map(n => n.textContent).join(""); }
    set innerHTML(_) { throw Error("Media may never inject markup"); }
    append(...nodes) { for (const node of nodes) { node.remove(); this.children.push(node); node.parent = this; } }
    replaceChildren(...nodes) { for (const node of this.children) node.parent = null; this.children = []; this._text = ""; this.append(...nodes); }
    remove() { if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    addEventListener(key, value) { this.listeners[key] = value; }
    showModal() { this.open = true; doc.modal = this; }
    close() { this.open = false; if (doc.modal === this) doc.modal = null; this.listeners.close?.(); }
    focus() { doc.focused = this; }
    get isConnected() { return this === doc.body || this === doc.head || !!this.parent?.isConnected; }
    click() { return this.onclick?.({ preventDefault() {}, stopPropagation() {} }); }
  }
  doc.createElement = tag => new Element(tag); doc.getElementById = id => ids.get(id);
  doc.head = new Element("head"); doc.body = new Element("body");
  const container = new Element("section"); doc.body.append(container);
  const context = { window: {}, document: doc, URL };
  vm.createContext(context); vm.runInContext(source, context);
  const media = context.window.PlaymeltGameMedia.create({ send(action, payload) { calls.push({ action, payload }); return sendOverride?.(action, payload); }, document: doc });
  const show = (id = "steam:123", target = container) => media.show({ id, title: "Jeu fixture" }, target);
  const ready = (extra = {}) => media.receive({ gameId: "steam:123", status: "ready", images: [image()], videos: [yt()], ...extra });
  const videos = () => walk(container).filter(n => n.tagName === "button" && n.attributes["aria-label"]?.startsWith("Lire "));
  return { media, show, ready, container, calls, doc, videos };
}

test("show requests a game's official media once across repeated page/progress renders", () => {
  const f = setup(); f.show(); f.show(); f.show();
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0].action, "getGameMedia"); assert.equal(f.calls[0].payload.gameId, "steam:123");
  assert.match(f.container.textContent, /Chargement/); f.ready(); f.show();
  assert.equal(f.calls.length, 1); assert.equal(f.container.attributes["aria-busy"], "false");
  assert.equal(f.doc.head.children.length, 1, "styles are installed once");
});

test("official teaser/trailer precede gameplay and other clips; every video uses the native in-app command", () => {
  const f = setup(); f.show(); f.ready({ videos: [yt({ id: "other", kind: "other" }), yt({ id: "gameplay", kind: "gameplay" }), yt({ id: "trailer", kind: "trailer" }), yt({ id: "teaser", kind: "teaser" })] });
  for (const button of f.videos()) button.click();
  const plays = f.calls.filter(c => c.action === "playGameVideo");
  assert.deepEqual(plays.map(c => c.payload.videoId), ["trailer", "teaser", "gameplay", "other"]);
  for (const c of plays) { assert.equal(c.payload.gameId, "steam:123"); assert.deepEqual(Object.keys(c.payload).sort(), ["gameId", "videoId"]); }
  assert.equal(f.calls.some(c => c.action === "openHubLink"), false);
  assert.equal(walk(f.container).some(n => ["iframe", "video", "a"].includes(n.tagName)), false, "the main view contains no remote player or outbound video link");
});

test("a Steam trailer follows the same native path as YouTube", () => {
  const f = setup(); f.show(); f.ready({ videos: [{ id: "steam-trailer", title: "Bande-annonce Steam", kind: "trailer", provider: "steam", url: "https://video.akamai.steamstatic.com/store_trailers/fixture/trailer.mp4", sourceUrl: "https://store.steampowered.com/app/123/", officialSource: true }] });
  f.videos()[0].click(); assert.equal(f.calls.at(-1).action, "playGameVideo"); assert.equal(f.calls.at(-1).payload.videoId, "steam-trailer");
});

test("unofficial videos, title-only searches and invalid provider/source URLs never become playable cards", () => {
  const f = setup(); f.show(); f.ready({ videos: [yt({ officialSource: false }), yt({ id: "search", youtubeId: undefined, sourceUrl: "https://www.youtube.com/results?search_query=Game" }), yt({ id: "invalid", youtubeId: "invalid" }), yt({ id: "unknown", provider: "other" }), yt({ id: "source", sourceUrl: "https://user:password@example.test/a" }), { ...yt(), id: "steam-external", provider: "steam", url: "https://example.test/video.mp4" }] });
  assert.equal(f.videos().length, 0); assert.equal(f.calls.length, 1);
});

test("stale or unsolicited snapshots cannot switch the visible game or play a clip from its previous page", () => {
  const f = setup(); assert.equal(f.media.receive({ gameId: "steam:123", status: "ready", images: [image()], videos: [yt()] }), false);
  f.show(); f.ready(); const oldVideo = f.videos()[0], oldImage = walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1");
  f.show("gog:456"); f.ready({ videos: [yt({ title: "Ancien jeu" })] });
  assert.match(f.container.textContent, /Chargement/); assert.doesNotMatch(f.container.textContent, /Ancien jeu/);
  oldVideo.click(); oldImage.click(); assert.equal(f.doc.modal, undefined); assert.equal(f.calls.filter(c => c.action === "playGameVideo").length, 0);
});

test("remote titles remain text and unsafe image URLs are discarded without markup injection", () => {
  const f = setup(); f.show(); const payload = '<img src=x onerror="bad()">';
  f.ready({ videos: [yt({ title: payload })], images: [image({ id: "script", url: "javascript:bad()" }), image({ id: "file", url: "file:///tmp/private" }), image({ id: "host", url: "https://outside.example.test/image.jpg" }), image({ id: "credential", url: "https://user:password@images.gog.com/image.jpg" })] });
  assert.match(f.container.textContent, /<img src=x/); assert.equal(walk(f.container).filter(n => n.tagName === "img").length, 1, "only the intended video thumbnail exists");
  assert.equal(walk(f.container).some(n => n.tagName === "script"), false);
});

test("image lightbox is local, keyboard navigable, restores focus and does not close the underlying game on Escape", () => {
  const f = setup(); f.show(); f.ready({ images: [image(), image({ id: "second", url: "https://images.gog-statics.com/second.jpg" })], videos: [] });
  const tile = walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1"); tile.click();
  const dialog = f.doc.modal; assert.equal(dialog.open, true); assert.match(dialog.textContent, /Image 1 \/ 2/);
  let stopped = 0, prevented = 0;
  dialog.listeners.keydown({ key: "ArrowRight", stopPropagation() { stopped++; }, preventDefault() { prevented++; } });
  assert.match(dialog.textContent, /Image 2 \/ 2/); assert.equal(prevented, 1);
  dialog.listeners.keydown({ key: "Escape", stopPropagation() { stopped++; }, preventDefault() { throw Error("native dialog Escape must remain enabled"); } });
  assert.equal(stopped, 2); dialog.close(); assert.equal(f.doc.focused, tile);
  assert.equal(f.calls.length, 1, "viewing images emits no playback/navigation command");
});

test("image failures stay in the local panel and do not create a blank white player or external fallback", () => {
  const f = setup(); f.show(); f.ready({ videos: [] });
  const tile = walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1"), thumbnail = walk(tile).find(n => n.tagName === "img");
  thumbnail.onerror(); assert.equal(thumbnail.hidden, true); assert.equal(walk(tile).find(n => n.className === "gm-fallback").hidden, false);
  tile.click(); const large = walk(f.doc.modal).find(n => n.tagName === "img"); large.onerror(); assert.match(f.doc.modal.textContent, /n’a pas pu être chargée/);
  assert.equal(f.calls.length, 1);
});

test("bridge/media errors offer explicit retry without an automatic request loop", () => {
  const f = setup(() => false); f.show(); assert.match(f.container.textContent, /temporairement indisponibles/); assert.equal(f.calls.length, 1);
  f.show(); assert.equal(f.calls.length, 1);
  const retry = walk(f.container).find(n => n.tagName === "button" && n.textContent === "Réessayer"); retry.click(); assert.equal(f.calls.length, 2);
  const g = setup((action) => action !== "playGameVideo"); g.show(); g.ready(); g.videos()[0].click(); assert.match(g.container.textContent, /vidéo n’a pas pu être ouverte/);
});

test("dispose closes the owned lightbox, removes media nodes and refuses late snapshots", () => {
  const f = setup(); f.show(); f.ready(); walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1").click();
  f.media.dispose(); assert.equal(f.doc.modal, null); assert.equal(f.container.children.length, 0); assert.equal(f.media.receive({ gameId: "steam:123", status: "ready" }), false);
});

test("closing the game page hides its media and lightbox; reopening reacquires the native cache once", () => {
  const f = setup(); f.show(); f.ready(); walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1").click();
  f.media.hide(); assert.equal(f.doc.modal, null); assert.equal(f.container.children.length, 0);
  f.ready(); assert.equal(f.container.children.length, 0, "a late snapshot cannot reopen the hidden page");
  f.show(); assert.equal(f.calls.length, 2); assert.match(f.container.textContent, /Chargement/); assert.equal(f.videos().length, 0);
  f.show(); assert.equal(f.calls.length, 2, "progress renders do not repeat the reopening request");
  f.ready(); assert.ok(f.videos().length);
});

test("an existing official YouTube URL is accepted without any title search or browser navigation", () => {
  const f = setup(); f.show(); f.ready({ videos: [yt({ youtubeId: undefined, sourceUrl: "https://youtu.be/AbCdEf123_-" })] });
  assert.equal(f.videos().length, 1); f.videos()[0].click(); assert.equal(f.calls.at(-1).action, "playGameVideo");
});

test("the app wiring loads the module with its nonce and authorizes the exact native media commands", () => {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  assert.match(html, /<script nonce="metalmax-local" src="GameMedia\.js"><\/script>/);
  assert.match(html, /id="dialogMedia"/); assert.match(html, /window\.onGameMedia = payload => gameMedia\?\.receive\(payload\)/);
  const csp = html.match(/http-equiv="Content-Security-Policy"\s+content="([^"]+)"/)[1];
  assert.match(csp, /https:\/\/i\.ytimg\.com/); assert.doesNotMatch(csp, /frame-src[^;]*youtube/);
  const sent = [], begin = html.indexOf("const allowedActions = new Set("), end = html.indexOf("function imageSources(", begin);
  const context = { state: { games: [] }, window: { webkit: { messageHandlers: { metalmax: { postMessage: value => sent.push(value) } } } }, renderProtectionEnabled: () => false, windowsExecutionUnavailable: () => false };
  const send = vm.runInNewContext(html.slice(begin, end) + ";send", context);
  assert.equal(send("getGameMedia", { gameId: "gog:456" }), true);
  assert.equal(send("playGameVideo", { gameId: "gog:456", videoId: "official-fixture" }), true);
  assert.deepEqual(sent.map(x => x.action), ["getGameMedia", "playGameVideo"]);
});


test("switching back to an evicted or expired native game cache requests fresh media instead of replaying cached UI tiles", () => {
  const f = setup(); f.show(); f.ready(); const oldVideo = f.videos()[0];
  f.show("gog:456"); f.media.receive({ gameId: "gog:456", status: "empty", images: [], videos: [] });
  f.show(); assert.equal(f.calls.filter(c => c.action === "getGameMedia" && c.payload.gameId === "steam:123").length, 2);
  assert.equal(f.videos().length, 0); oldVideo.click(); assert.equal(f.calls.filter(c => c.action === "playGameVideo").length, 0);
  f.ready(); f.videos()[0].click(); assert.equal(f.calls.at(-1).action, "playGameVideo");
});

test("manual refresh recovers a still-open page after native cache expiry without replaying stale media or looping", () => {
  const f = setup(); f.show(); f.ready(); const oldVideo = f.videos()[0], oldImage = walk(f.container).find(n => n.attributes["aria-label"] === "Agrandir l’image 1");
  const refresh = walk(f.container).find(n => n.tagName === "button" && n.textContent === "Actualiser les médias");
  assert.equal(refresh.disabled, false); refresh.click(); assert.equal(f.calls.length, 2);
  const pending = walk(f.container).find(n => n.textContent === "Actualiser les médias");
  assert.equal(pending.disabled, true); pending.click(); f.show(); assert.equal(f.calls.length, 2);
  oldVideo.click(); oldImage.click(); assert.equal(f.doc.modal, undefined); assert.equal(f.calls.filter(c => c.action === "playGameVideo").length, 0);
  f.ready(); assert.equal(walk(f.container).find(n => n.textContent === "Actualiser les médias").disabled, false);
});

test("an unavailable native response exposes a manual retry rather than a permanent empty state", () => {
  const f = setup(); f.show(); f.ready({ status: "unavailable", images: [], videos: [] });
  assert.match(f.container.textContent, /temporairement indisponibles/);
  walk(f.container).find(n => n.tagName === "button" && n.textContent === "Réessayer").click();
  assert.equal(f.calls.length, 2); f.show(); assert.equal(f.calls.length, 2);
});

test("every image CDN accepted by the official native catalogue survives UI filtering and CSP", () => {
  const catalog = fs.readFileSync(path.join(__dirname, "../GameMediaCatalog.swift"), "utf8");
  const hosts = [...catalog.match(/private static let imageHosts: Set<String> = \[([^\]]+)\]/)[1].matchAll(/"([^"\s]+)"/g)].map(m => m[1]);
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8"), csp = html.match(/http-equiv="Content-Security-Policy"\s+content="([^"]+)"/)[1];
  const imageDirective = csp.split(";").find(x => x.trim().startsWith("img-src ")).trim().split(/\s+/);
  assert.equal(hosts.length, 8);
  for (const host of hosts) {
    assert.ok(imageDirective.includes("https://" + host), "CSP must allow official catalogue host " + host);
    const f = setup(); f.show(); f.ready({ images: [image({ url: "https://" + host + "/fixture.jpg", thumbnail: "https://" + host + "/fixture_thumb.jpg" })], videos: [] });
    assert.equal(walk(f.container).filter(n => n.attributes["aria-label"] === "Agrandir l’image 1").length, 1, host);
  }
});
