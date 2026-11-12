/* Playmelt commercial website. Catalogue access is distinct from Mac gameplay evidence. */
(() => {
  "use strict";
  const $ = id => document.getElementById(id);
  const all = selector => [...document.querySelectorAll(selector)];
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const iconFallback = new URL("assets/images/PlaymeltIcon.png", document.baseURI).href;
  const state = { games: [], featured: [], selected: 0, filter: "all", search: "", page: 1, opener: null };
  const PAGE_SIZE = 6;
  let noticeTimer;
  let suppressCoverClickUntil = 0;
  function text(id, value) { $(id).textContent = value || "Non renseigné"; }
  function notice(message) {
    clearTimeout(noticeTimer); text("notice", message); $("notice").hidden = false;
    noticeTimer = setTimeout(() => { $("notice").hidden = true; }, 3500);
  }
  function element(tag, className, content) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (content !== undefined) el.textContent = content;
    return el;
  }
  function safeImageUrl(raw) {
    try {
      const url = new URL(raw, document.baseURI);
      const local = url.origin === location.origin && url.pathname.startsWith(new URL("assets/images/", document.baseURI).pathname);
      const primary = url.protocol === "https:" && ["shared.fastly.steamstatic.com", "cdn.cloudflare.steamstatic.com", "shared.akamai.steamstatic.com", "store-images.s-microsoft.com"].includes(url.hostname);
      return !url.username && !url.password && (local || primary) ? url.href : iconFallback;
    } catch { return iconFallback; }
  }
  function safeOfficialUrl(raw) {
    try {
      const url = new URL(raw);
      return url.protocol === "https:" && !url.username && !url.password && ["store.steampowered.com", "www.xbox.com"].includes(url.hostname) ? url.href : null;
    } catch { return null; }
  }
  function artwork(game) { return safeImageUrl(game.hero || game.cover); }
  function gameImage(game, eager = false) {
    const img = element("img"); img.src = safeImageUrl(game.cover); img.alt = "";
    img.draggable = false; img.loading = eager ? "eager" : "lazy";
    img.addEventListener("error", () => { img.src = iconFallback; img.classList.add("is-fallback"); }, { once: true });
    return img;
  }
  function status(el, game) { el.textContent = game.statusLabel; el.dataset.status = game.status; }
  function platform(game) { return game.mode === "cloud" ? "Xbox Cloud Gaming" : ({steam: "Steam", epic: "Epic Games", local: "Jeu local"}[game.store] || "Windows"); }
  function selectedGame() { return state.featured[state.selected]; }
  function renderHero() {
    if (!state.featured.length) return;
    const game = selectedGame();
    const existing = new Map(all("#coverflow [data-index]").map(button => [Number(button.dataset.index), button]));
    if (existing.size !== state.featured.length) existing.clear();
    const fragment = document.createDocumentFragment();
    state.featured.forEach((item, index) => {
      const button = existing.get(index) || element("button", "cover");
      const delta = (index - state.selected + state.featured.length) % state.featured.length;
      const offset = delta > Math.floor(state.featured.length / 2) ? delta - state.featured.length : delta;
      button.type = "button"; button.dataset.index = index;
      button.style.setProperty("--offset", offset); button.style.setProperty("--distance", Math.abs(offset));
      button.hidden = Math.abs(offset) > 2;
      button.setAttribute("aria-pressed", String(offset === 0));
      button.setAttribute("aria-label", `${offset === 0 ? "Ouvrir" : "Sélectionner"} ${item.title}`);
      if (!existing.has(index)) button.append(gameImage(item, Math.abs(offset) <= 2));
      if (!existing.size) fragment.append(button);
    });
    if (!existing.size) $("coverflow").replaceChildren(fragment);
    motion.setArtwork(artwork(game));
    text("previewIndex", `${String(state.selected + 1).padStart(2, "0")} / ${state.featured.length}`);
    status($("selectedStatus"), game); text("selectedTitle", game.title);
    text("selectedEngine", `${platform(game)} · ${game.mode === "cloud" ? "Accès Xbox séparé" : game.status === "tested" ? "Essai sur Mac" : "Compatibilité à évaluer"}`);
    text("previewGameTitle", game.title); status($("previewGameStatus"), game);
    text("previewGameNotes", game.description);
    $("previewGameBanner").style.backgroundImage = `url("${artwork(game)}")`;
  }
  function rotateGame(delta, keyboard = false) {
    if (!state.featured.length) return;
    state.selected = (state.selected + delta + state.featured.length) % state.featured.length;
    renderHero();
    if (keyboard) $("coverflow").querySelector('[aria-pressed="true"]').focus({preventScroll: true});
  }
  function activatePreview(view) {
    const names = {library: "Le choix vous appartient.", game: "Le jeu, dans le détail.", access: "À chaque jeu, son accès."};
    all("[data-preview]").forEach(button => { const active = button.dataset.preview === view; button.classList.toggle("selected", active); button.setAttribute("aria-pressed", String(active)); });
    for (const [key, id] of Object.entries({library: "previewLibrary", game: "previewGame", access: "previewAccess"})) $(id).hidden = key !== view;
    text("previewHeading", names[view]);
  }
  function normalize(value) { return value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase("fr"); }
  function renderCatalogue() {
    const matches = state.games.filter(game => (state.filter === "all" || game.mode === state.filter || (state.filter === "tested" && game.status === "tested")) && normalize(`${game.title} ${game.genre} ${platform(game)}`).includes(state.search));
    const pages = Math.max(1, Math.ceil(matches.length / PAGE_SIZE));
    state.page = Math.max(1, Math.min(pages, state.page));
    const start = (state.page - 1) * PAGE_SIZE;
    const fragment = document.createDocumentFragment();
    for (const game of matches.slice(start, start + PAGE_SIZE)) {
      const card = element("button", "game-card"); card.type = "button"; card.dataset.game = game.slug;
      card.setAttribute("aria-label", `Ouvrir la fiche de ${game.title}`);
      const art = element("div", "game-card-art"); art.append(gameImage(game));
      const badge = element("span", "game-badge", game.mode === "cloud" ? "Xbox Cloud" : "Windows"); badge.dataset.status = game.mode; art.append(badge);
      card.append(art, element("h3", "", game.title), element("span", "card-store", `${platform(game)} · ${game.genre}`));
      const access = element("span", "card-access", game.status === "tested" ? "Essai sur Mac" : game.mode === "cloud" ? "Accès Xbox requis" : "Compatibilité à vérifier"); access.dataset.status = game.status; card.append(access);
      fragment.append(card);
    }
    if (!matches.length) fragment.append(element("p", "empty-state", "Aucun jeu ne correspond. Essayez un autre titre ou un autre accès."));
    $("gameGrid").replaceChildren(fragment);
    text("catalogueCount", `${matches.length} jeu${matches.length > 1 ? "x" : ""} dans cette sélection`);
    text("pageLabel", matches.length ? `${start + 1}–${Math.min(matches.length, start + PAGE_SIZE)} sur ${matches.length} · ${state.page} / ${pages}` : "Aucun résultat");
    $("previousPage").disabled = state.page <= 1; $("nextPage").disabled = state.page >= pages;
  }
  function setFilter(filter) {
    state.filter = filter; state.page = 1;
    all("[data-filter]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.filter === filter)));
    renderCatalogue();
  }
  function showGame(game, opener) {
    if (!game) return;
    state.opener = opener || document.activeElement;
    const cloud = game.mode === "cloud", tested = game.status === "tested";
    text("dialogTitle", game.title); text("dialogPlatform", platform(game)); status($("dialogStatus"), game);
    $("dialogHero").style.backgroundImage = `url("${artwork(game)}")`;
    text("dialogEngine", cloud ? "Streaming Xbox · sur le service officiel" : tested ? game.engine : "Jeu Windows · compatibilité à évaluer");
    text("dialogDescription", game.description); text("dialogNotes", game.notes);
    text("dialogReportLabel", cloud ? "L’ACCÈS CLOUD" : tested ? "ESSAI PLAYMELT" : "LE JEU WINDOWS");
    text("dialogReportTitle", cloud ? "Un grand univers, sans installer le jeu." : tested ? "Un essai sur Mac confirmé." : "Votre prochain jeu à explorer.");
    $("dialogObservations").hidden = !tested;
    text("dialogChip", game.chipTested); text("dialogResolution", game.resolution);
    $("dialogResolution").parentElement.hidden = !game.resolution;
    text("dialogFps", game.fpsTarget); text("dialogMetalFx", game.metalfx); text("dialogMemory", game.vramBudget);
    text("dialogEvidenceLabel", cloud ? "DISPONIBILITÉ CHEZ XBOX" : tested ? "LE RETOUR DE JEU" : "COMPATIBILITÉ PLAYMELT");
    text("dialogEvidenceTitle", cloud ? "Accès Xbox séparé" : tested ? "Joué sur Mac" : "À évaluer sur votre Mac");
    text("dialogEvidenceDescription", cloud ? "Référencé pour le cloud par Xbox, source consultée le 12 novembre 2026. Votre pays, votre abonnement et les droits du jeu déterminent l’accès réel. Ce référencement ne constitue pas un essai Playmelt." : tested ? "Essai confirmé par l’utilisateur le 12 novembre 2026. Les réglages et le Mac de cet essai ne garantissent pas le même résultat sur toutes les configurations." : "Cette fiche présente la version Windows. Aucun essai Playmelt concluant n’est confirmé pour ce titre. Les DRM, l’anti-triche, les moteurs et les mises à jour peuvent empêcher le lancement.");
    const source = safeOfficialUrl(game.sourceUrl), store = safeOfficialUrl(game.storeUrl || game.sourceUrl);
    $("dialogStore").hidden = !store; if (store) $("dialogStore").href = store;
    $("dialogStore").textContent = cloud ? "Voir l’accès Xbox ↗" : "Voir sur Steam ↗";
    $("dialogSource").hidden = !source; if (source) $("dialogSource").href = source;
    $("dialogSource").textContent = cloud ? "Vérifier chez Xbox ↗" : "Fiche officielle du jeu ↗";
    $("dialogTestDetails").hidden = !tested; $("dialogTestDetails").open = false;
    text("dialogFootnote", cloud ? "Game Pass, achat du jeu ou autre accès éligible selon l’offre Xbox. Une connexion et des périphériques compatibles sont nécessaires." : "Jeu vendu séparément. Les performances et la compatibilité dépendent du titre, de ses protections, des réglages et du Mac.");
    if (!$("gameDialog").open) $("gameDialog").showModal(); $("gameDialog").scrollTop = 0;
    const url = new URL(location.href); url.searchParams.set("jeu", game.slug); history.replaceState(null, "", url);
  }
  function closeGame() { $("gameDialog").close(); }
  async function loadCatalogue() {
    $("catalogueError").hidden = true;
    try {
      const response = await fetch("data/compatibility.json"); if (!response.ok) throw Error("catalogue_unavailable");
      const games = await response.json();
      if (!Array.isArray(games) || !games.length || games.some(game => !game.slug || !game.title || !["windows", "cloud"].includes(game.mode) || !["tested", "explore", "cloud"].includes(game.status) || (game.status === "tested" && game.confirmation?.kind !== "user_gameplay_report") || (game.mode === "cloud" && (!game.sourceUrl || !game.verifiedAt))) || new Set(games.map(game => game.slug)).size !== games.length) throw Error("catalogue_invalid");
      state.games = games; state.featured = games.filter(game => game.featured); if (!state.featured.length) state.featured = games.slice(0, 12);
      state.selected = 0;
      for (const id of ["previewOpenGame", "previousGame", "nextGame"]) $(id).disabled = false;
      renderHero(); renderCatalogue();
      const requested = new URL(location.href).searchParams.get("jeu"); if (requested) showGame(games.find(game => game.slug === requested));
    } catch {
      state.games = []; state.featured = []; $("gameGrid").replaceChildren();
      text("catalogueCount", "Sélection momentanément indisponible"); $("catalogueError").hidden = false;
      text("coverflow", "La sélection n’est pas disponible pour le moment.");
      for (const id of ["previewOpenGame", "previousGame", "nextGame", "previousPage", "nextPage"]) $(id).disabled = true;
    }
  }
  async function loadRelease() {
    try {
      const response = await fetch("data/release.json"); if (!response.ok) return;
      const release = await response.json();
      if (!/^\d+\.\d+\.\d+$/.test(release.version) || !/^[a-f0-9]{64}$/.test(release.sha256) || !Number.isSafeInteger(release.bytes) || release.bytes < 1) return;
      /* Acquisition always requires account and e-mail verification; release metadata never links directly to a file. */
      all(".acquisition-link").forEach(link => { link.href = new URL("compte/?intent=download", document.baseURI).href; });
      all(".version-label").forEach(el => { el.textContent = release.version; });
      text("downloadSize", `${(release.bytes / 1000000).toLocaleString("fr-FR", {maximumFractionDigits: 1})} Mo`);
      text("downloadHash", release.sha256);
    } catch { /* The account acquisition path remains usable. */ }
  }
  const plans = {
    monthly: {name: "L’ABONNEMENT MENSUEL", price: "19,99 €", unit: "/ mois", billing: "Puis 19,99 € prélevés chaque mois. Renouvellement automatique."},
    quarterly: {name: "L’ABONNEMENT 3 MOIS", price: "53,99 €", unit: "/ 3 mois", billing: "Puis 53,99 € prélevés tous les 3 mois, soit environ 18,00 €/mois. Renouvellement automatique."},
    semiannual: {name: "L’ABONNEMENT 6 MOIS", price: "95,99 €", unit: "/ 6 mois", billing: "Puis 95,99 € prélevés tous les 6 mois, soit environ 16,00 €/mois. Renouvellement automatique."},
    annual: {name: "L’ABONNEMENT ANNUEL", price: "167,99 €", unit: "/ an", billing: "Puis 167,99 € prélevés chaque année, soit environ 14,00 €/mois. Renouvellement automatique."},
    lifetime: {name: "L’ACCÈS À VIE", price: "399 €", unit: "en une fois", billing: "Un paiement unique à l’ouverture des paiements. Aucun renouvellement automatique."}
  };
  function selectPlan(key) {
    const plan = plans[key]; if (!plan) return;
    all("[data-plan]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.plan === key)));
    text("planName", plan.name); text("planPrice", plan.price); text("planUnit", plan.unit); text("planBilling", plan.billing);
    text("planBadge", key === "lifetime" ? "Sans essai" : "30 jours d’essai");
    text("planTrial", key === "lifetime" ? "L’offre à vie n’inclut pas les 30 jours d’essai. Les conditions de l’accès sont détaillées avant confirmation." : "Carte demandée au démarrage de l’essai. Annulez depuis votre compte avant le premier débit pour terminer l’essai sans frais d’abonnement.");
    $("planCta").href = new URL(`compte/?plan=${key}&intent=download`, document.baseURI).href;
  }
  function initMotion() {
    const hero = $("experience");
    const preference = matchMedia("(prefers-reduced-motion: reduce)");
    let paused = preference.matches;
    let visible = true;
    let hovered = false;
    let interacted = false;
    let timer;
    const update = () => {
      clearTimeout(timer);
      const running =
        !paused &&
        !preference.matches &&
        visible &&
        !document.hidden &&
        !$("gameDialog").open;
      hero.classList.toggle("motion-paused", !running);
      $("motionToggle").setAttribute("aria-pressed", String(!running));
      $("motionToggle").setAttribute(
        "aria-label",
        running ? "Mettre les animations en pause" : "Activer les animations",
      );
      $("motionLabel").textContent = running
        ? "Aperçu animé"
        : "Animations en pause";
      $("motionToggle").querySelector(".motion-symbol").textContent = running
        ? "Ⅱ"
        : "▷";
      if (running && !hovered && !interacted)
        timer = setTimeout(() => {
          rotateGame(1);
          update();
        }, 8000);
    };
    $("motionToggle").addEventListener("click", () => {
      paused = !paused;
      if (!paused) interacted = false;
      update();
    });
    const product = hero.querySelector(".product-window");
    product.addEventListener("pointerenter", () => {
      hovered = true;
      update();
    });
    product.addEventListener("pointerleave", () => {
      hovered = false;
      update();
    });
    for (const event of ["pointerdown", "focusin"])
      product.addEventListener(event, () => {
        interacted = true;
        update();
      });
    document.addEventListener("visibilitychange", update);
    preference.addEventListener("change", () => {
      paused = preference.matches;
      update();
    });
    $("gameDialog").addEventListener("close", update);
    new MutationObserver(update).observe($("gameDialog"), {
      attributes: true,
      attributeFilter: ["open"],
    });
    new IntersectionObserver(
      (entries) => {
        visible = entries[0].isIntersecting;
        update();
      },
      { threshold: 0.1 },
    ).observe(hero);
    const reveals = new IntersectionObserver(
      (entries) => {
        for (const entry of entries)
          if (entry.isIntersecting) {
            if (!preference.matches)
              entry.target.animate(
                [
                  { opacity: 0.35, transform: "translateY(24px)" },
                  { opacity: 1, transform: "translateY(0)" },
                ],
                { duration: 750, easing: "cubic-bezier(.2,.65,.3,1)" },
              );
            reveals.unobserve(entry.target);
          }
      },
      { threshold: 0.08 },
    );
    all(".section-heading, .how-steps, .access-offer").forEach((el) =>
      reveals.observe(el),
    );
    window.addEventListener("pagehide", () => {
      clearTimeout(timer);
      reveals.disconnect();
    });
    update();
    return {
      setArtwork(url) {
        hero.style.setProperty("--scene-art", `url("${url}")`);
      },
    };
  }
  const motion = initMotion();
  $("previousGame").addEventListener("click", () => rotateGame(-1));
  $("nextGame").addEventListener("click", () => rotateGame(1));
  $("coverflow").addEventListener("click", event => {
    if (Date.now() < suppressCoverClickUntil) return;
    const button = event.target.closest("[data-index]"); if (!button) return;
    const index = Number(button.dataset.index);
    if (index === state.selected) showGame(selectedGame(), button); else {state.selected = index; renderHero();}
  });
  $("coverflow").addEventListener("keydown", event => {
    if (["ArrowLeft", "ArrowRight"].includes(event.key)) {event.preventDefault(); rotateGame(event.key === "ArrowLeft" ? -1 : 1, true);}
  });
  let swipe = null;
  $("coverflow").addEventListener("pointerdown", event => {swipe = {x: event.clientX, y: event.clientY};});
  $("coverflow").addEventListener("pointerup", event => {
    if (!swipe) return;
    const dx = event.clientX - swipe.x, dy = event.clientY - swipe.y; swipe = null;
    if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.2) {suppressCoverClickUntil = Date.now() + 300; rotateGame(dx > 0 ? -1 : 1);}
  });
  $("coverflow").addEventListener("pointercancel", () => {swipe = null;});
  all("[data-preview]").forEach(button => button.addEventListener("click", () => activatePreview(button.dataset.preview)));
  for (const id of ["previewOpenGame", "previewGameDetails"]) $(id).addEventListener("click", event => showGame(selectedGame(), event.currentTarget));
  $("gameGrid").addEventListener("click", event => {const card = event.target.closest("[data-game]"); if (card) showGame(state.games.find(game => game.slug === card.dataset.game), card);});
  $("closeDialog").addEventListener("click", closeGame);
  $("gameDialog").addEventListener("click", event => {if (event.target === $("gameDialog")) closeGame();});
  $("gameDialog").addEventListener("close", () => {
    const url = new URL(location.href); url.searchParams.delete("jeu"); history.replaceState(null, "", url);
    if (state.opener?.isConnected) state.opener.focus({preventScroll: true});
  });
  $("dialogOffer").addEventListener("click", () => {state.opener = null; closeGame();});
  all("[data-filter]").forEach(button => button.addEventListener("click", () => setFilter(button.dataset.filter)));
  all("[data-catalogue-route]").forEach(link => link.addEventListener("click", () => {state.search = ""; $("gameSearch").value = ""; setFilter(link.dataset.catalogueRoute);}));
  $("gameSearch").addEventListener("input", event => {state.search = normalize(event.target.value); state.page = 1; renderCatalogue();});
  $("previousPage").addEventListener("click", () => {state.page--; renderCatalogue();});
  $("nextPage").addEventListener("click", () => {state.page++; renderCatalogue();});
  all("[data-plan]").forEach(button => button.addEventListener("click", () => selectPlan(button.dataset.plan)));
  $("copyHash").addEventListener("click", async () => {
    try {await navigator.clipboard.writeText($("downloadHash").textContent.trim()); notice("Empreinte copiée.");}
    catch {notice("Copie indisponible. L’empreinte reste consultable ci-dessus.");}
  });
  $("reloadCatalogue").addEventListener("click", loadCatalogue);
  window.addEventListener("pagehide", () => clearTimeout(noticeTimer));
  const requestedPlan = new URL(location.href).searchParams.get("plan"); if (Object.hasOwn(plans, requestedPlan)) selectPlan(requestedPlan);
  loadCatalogue(); loadRelease();
})();
