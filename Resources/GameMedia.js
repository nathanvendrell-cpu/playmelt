(function () {
  "use strict";
  const imageHosts = new Set([
    "shared.fastly.steamstatic.com", "store.fastly.steamstatic.com", "shared.akamai.steamstatic.com",
    "cdn.cloudflare.steamstatic.com", "cdn.akamai.steamstatic.com", "steamcdn-a.akamaihd.net",
    "shared.cloudflare.steamstatic.com", "cdn.fastly.steamstatic.com", "cdn.steamstatic.com",
    "images.gog.com", "images.gog-statics.com", "cdn1.epicgames.com", "cdn2.unrealengine.com",
    "i.ytimg.com", "img.youtube.com",
  ]);
  const styles = `
    .gm-root{padding:20px 0;border-top:1px solid var(--line,#58657440);min-width:0;color:inherit}
    .gm-head{display:flex;align-items:baseline;justify-content:space-between;gap:14px;margin-bottom:12px}
    .gm-head h3{font-size:15px;letter-spacing:-.02em;margin:0}.gm-note{font-size:12px;color:var(--muted,#969eaa);margin:8px 0;line-height:1.6}
    .gm-group{margin:15px 0 0}.gm-group h4{font-size:11px;font-weight:600;color:var(--muted,#969eaa);margin:0 0 9px}
    .gm-strip{display:flex;gap:10px;overflow-x:auto;scroll-snap-type:x proximity;padding:0 0 10px}
    .gm-tile{flex:0 0 clamp(150px,23vw,232px);min-width:0;padding:0;border:1px solid #8996a333;border-radius:9px;background:#10151c;color:#e6eaf0;text-align:left;overflow:hidden;cursor:pointer;scroll-snap-align:start;box-shadow:none}
    .gm-tile:hover{border-color:var(--accent,#e08150)}.gm-tile:focus-visible,.gm-lightbox button:focus-visible{outline:2px solid var(--accent,#e08150);outline-offset:3px}
    .gm-visual{position:relative;aspect-ratio:16/9;overflow:hidden;background:#151d27}.gm-visual img{display:block;width:100%;height:100%;object-fit:cover}
    .gm-fallback{height:100%;display:flex;align-items:center;justify-content:center;padding:15px;font-size:12px;color:#a9b4c3}
    .gm-play{position:absolute;right:9px;bottom:9px;border-radius:50%;background:#111c;color:#fff;width:29px;height:29px;display:grid;place-items:center;font-size:11px}
    .gm-caption{display:block;font-size:12px;font-weight:600;line-height:1.4;padding:9px 11px 3px;overflow-wrap:anywhere}
    .gm-caption:last-child{padding-bottom:10px}.gm-meta{display:block;font-size:10px;font-weight:400;color:#a4b1c2;padding:0 11px 10px}
    .gm-lightbox{width:min(1100px,calc(100vw - 32px));max-height:calc(100vh - 32px);padding:14px;border:1px solid #75849b55;border-radius:12px;background:#10151c;color:#e8edf5}
    .gm-lightbox::backdrop{background:#04070ce8}.gm-lightbox-head{display:flex;justify-content:space-between;align-items:center;gap:15px;font-size:12px;margin-bottom:12px}
    .gm-lightbox img{display:block;max-width:100%;max-height:calc(100vh - 160px);object-fit:contain;margin:auto}
    .gm-lightbox button{padding:7px 12px;border:1px solid #8793a944;border-radius:7px;background:#1b2531;color:inherit;cursor:pointer}
    .gm-lightbox-nav{display:flex;justify-content:center;gap:8px;margin-top:12px}.gm-lightbox[hidden],.gm-root [hidden]{display:none!important}
    @media(max-width:620px){.gm-tile{flex-basis:180px}.gm-root{padding-top:16px}.gm-head{align-items:flex-start}.gm-lightbox{padding:10px}}
  `;
  function text(value, fallback = "") { return typeof value === "string" ? value.slice(0, 500) : fallback; }
  function identifier(value) { return typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\x00-\x1f\x7f]/.test(value); }
  function https(value) {
    if (typeof value !== "string" || value.length > 4096 || /[\x00-\x20\x7f\\]/.test(value)) return null;
    try {
      const url = new URL(value);
      return url.protocol === "https:" && !url.username && !url.password && !url.port ? url : null;
    } catch { return null; }
  }
  function imageURL(value) { const url = https(value); return url && imageHosts.has(url.hostname) ? url.href : ""; }
  function youtubeID(video) {
    if (video.youtubeId !== undefined) return /^[\w-]{11}$/.test(video.youtubeId) ? video.youtubeId : "";
    const url = https(video.url || video.sourceUrl);
    if (!url) return "";
    let id = "";
    if (["youtube.com", "www.youtube.com", "m.youtube.com"].includes(url.hostname) && url.pathname === "/watch") id = url.searchParams.get("v") || "";
    else if (url.hostname === "youtu.be" && /^\/[\w-]{11}$/.test(url.pathname)) id = url.pathname.slice(1);
    return /^[\w-]{11}$/.test(id) ? id : "";
  }
  function normalize(payload) {
    const seenImages = new Set(), seenVideos = new Set();
    const images = (Array.isArray(payload.images) ? payload.images : []).flatMap(item => {
      if (!item || !identifier(item.id) || seenImages.has(item.id)) return [];
      const url = imageURL(item.url), thumbnail = imageURL(item.thumbnail) || url;
      if (!url || !https(item.sourceUrl)) return [];
      seenImages.add(item.id); return [{ id: item.id, url, thumbnail }];
    });
    const rank = { teaser: 0, trailer: 0, gameplay: 1, other: 2 };
    const videos = (Array.isArray(payload.videos) ? payload.videos : []).flatMap((item, order) => {
      if (!item || !identifier(item.id) || seenVideos.has(item.id) || item.officialSource !== true || !https(item.sourceUrl)) return [];
      if (item.provider === "youtube") { if (!youtubeID(item)) return []; }
      else if (item.provider === "steam") {
        const url = https(item.url);
        if (!url || !(url.hostname.endsWith(".steamstatic.com") || url.hostname === "steamcdn-a.akamaihd.net")) return [];
      } else return [];
      seenVideos.add(item.id);
      return [{ id: item.id, title: text(item.title, "Vidéo officielle"), kind: Object.hasOwn(rank, item.kind) ? item.kind : "other", provider: item.provider, thumbnail: imageURL(item.thumbnail), order }];
    }).sort((a, b) => rank[a.kind] - rank[b.kind] || a.order - b.order);
    return { status: text(payload.status), images, videos };
  }
  function create({ send, document: doc = document }) {
    let current = null, container = null, lightbox = null;
    const cache = new Map();
    if (!doc.getElementById("playmelt-game-media-style")) {
      const style = doc.createElement("style"); style.id = "playmelt-game-media-style"; style.textContent = styles; doc.head.append(style);
    }
    function node(tag, className, label) {
      const element = doc.createElement(tag);
      if (className) element.className = className;
      if (label !== undefined) element.textContent = label;
      return element;
    }
    function closeImage() { if (lightbox) { const active = lightbox; lightbox = null; active.close(); active.remove(); } }
    function showImage(images, index, trigger) {
      closeImage();
      const title = current.title;
      const dialog = node("dialog", "gm-lightbox"), top = node("div", "gm-lightbox-head"), count = node("span"), close = node("button", "", "Fermer"), image = node("img");
      dialog.setAttribute("aria-label", "Images de " + title);
      close.type = "button"; close.onclick = () => dialog.close(); top.append(count, close); dialog.append(top, image);
      const failure = node("p", "gm-note"); failure.setAttribute("role", "status"); dialog.append(failure);
      image.onerror = () => { image.hidden = true; failure.textContent = "Cette image n’a pas pu être chargée."; };
      function update() { image.hidden = false; failure.textContent = ""; image.src = images[index].url; image.alt = "Image " + (index + 1) + " de " + title; count.textContent = "Image " + (index + 1) + " / " + images.length; }
      if (images.length > 1) {
        const controls = node("div", "gm-lightbox-nav");
        for (const [label, offset] of [["Précédente", -1], ["Suivante", 1]]) { const button = node("button", "", label); button.type = "button"; button.onclick = () => { index = (index + offset + images.length) % images.length; update(); }; controls.append(button); }
        dialog.append(controls);
      }
      dialog.addEventListener("keydown", event => {
        if (event.key === "Escape") { event.stopPropagation(); return; }
        if (["ArrowLeft", "ArrowRight"].includes(event.key)) { event.preventDefault(); event.stopPropagation(); index = (index + (event.key === "ArrowRight" ? 1 : -1) + images.length) % images.length; update(); }
      });
      dialog.addEventListener("close", () => { if (lightbox === dialog) lightbox = null; dialog.remove(); if (trigger?.isConnected) trigger.focus(); });
      update(); doc.body.append(dialog); lightbox = dialog; dialog.showModal();
    }
    function picture(url, fallbackText) {
      const visual = node("span", "gm-visual"), fallback = node("span", "gm-fallback", fallbackText);
      fallback.hidden = !!url;
      if (url) {
        const image = node("img"); image.alt = ""; image.src = url; image.loading = "lazy"; image.decoding = "async";
        image.onerror = () => { image.hidden = true; fallback.hidden = false; };
        visual.append(image);
      }
      visual.append(fallback); return visual;
    }
    function render() {
      if (!container || !current) return;
      container.className = "gm-root";
      container.replaceChildren();
      const state = cache.get(current.id), gameID = current.id;
      const head = node("div", "gm-head"), refresh = node("button", "button secondary", "Actualiser les médias");
      refresh.type = "button"; refresh.disabled = state?.status === "loading";
      refresh.onclick = () => { if (!refresh.disabled && current?.id === gameID) request(gameID); };
      head.append(node("h3", "", "Images et vidéos"), refresh); container.append(head);
      container.setAttribute("aria-busy", String(!state || state.status === "loading"));
      if (!state || state.status === "loading") { container.append(node("p", "gm-note", "Chargement des médias du jeu…")); return; }
      if (!state.images.length && !state.videos.length) {
        container.append(node("p", "gm-note", ["error", "unavailable"].includes(state.status) ? "Les médias du jeu sont temporairement indisponibles." : "Aucun média officiel disponible pour le moment."));
        if (["error", "unavailable"].includes(state.status)) { const retry = node("button", "button secondary", "Réessayer"); retry.type = "button"; retry.onclick = () => { if (current?.id === gameID && cache.get(gameID) === state) request(gameID); }; container.append(retry); }
        return;
      }
      function group(title) { const section = node("section", "gm-group"), strip = node("div", "gm-strip"); section.append(node("h4", "", title), strip); container.append(section); return strip; }
      if (state.images.length) {
        const strip = group("Images");
        const gameID = current.id;
        state.images.forEach((item, index) => {
          const tile = node("button", "gm-tile"); tile.type = "button"; tile.setAttribute("aria-label", "Agrandir l’image " + (index + 1));
          tile.append(picture(item.thumbnail, "Image indisponible"), node("span", "gm-caption", "Image " + (index + 1)));
          tile.onclick = () => { if (current?.id === gameID && cache.get(gameID) === state) showImage(state.images, index, tile); }; strip.append(tile);
        });
      }
      if (state.videos.length) {
        const strip = group("Vidéos officielles"), names = { teaser: "Teaser", trailer: "Bande-annonce", gameplay: "Gameplay", other: "Vidéo" };
        const gameID = current.id;
        for (const item of state.videos) {
          const tile = node("button", "gm-tile"); tile.type = "button"; tile.setAttribute("aria-label", "Lire " + item.title + " dans Playmelt");
          const visual = picture(item.thumbnail, item.provider === "youtube" ? "YouTube" : "Steam"); visual.append(node("span", "gm-play", "▶"));
          tile.append(visual, node("span", "gm-caption", item.title), node("span", "gm-meta", names[item.kind] + " · " + (item.provider === "youtube" ? "YouTube" : "Steam")));
          tile.onclick = () => {
            if (current?.id !== gameID || cache.get(gameID) !== state) return;
            try { if (send("playGameVideo", { gameId: gameID, videoId: item.id }) !== false) return; } catch {}
            container.append(node("p", "gm-note", "La vidéo n’a pas pu être ouverte. Réessayez dans quelques instants."));
          };
          strip.append(tile);
        }
      }
    }
    function request(gameId) {
      cache.set(gameId, { status: "loading", images: [], videos: [] }); render();
      try { if (send("getGameMedia", { gameId }) !== false) return; } catch {}
      cache.set(gameId, { status: "error", images: [], videos: [] }); render();
    }
    return {
      show(game, target) {
        if (!game || !identifier(game.id) || !target) return;
        const opening = current?.id !== game.id;
        if (opening) closeImage();
        current = { id: game.id, title: text(game.title, "ce jeu") }; container = target;
        // Reopening reacquires the bounded native cache after TTL expiry or LRU
        // eviction. Progress renders of the same open page never send a request.
        if (opening || !cache.has(game.id)) request(game.id); else render();
      },
      receive(payload) {
        if (!payload || !identifier(payload.gameId) || !cache.has(payload.gameId)) return false;
        cache.set(payload.gameId, normalize(payload));
        if (current?.id === payload.gameId) render();
        return true;
      },
      hide() { closeImage(); container?.replaceChildren(); current = null; container = null; },
      dispose() { closeImage(); cache.clear(); container?.replaceChildren(); current = null; container = null; },
    };
  }
  window.PlaymeltGameMedia = { create };
})();
