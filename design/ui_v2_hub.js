        /* ---------- Accueil, Actus et fiche jeu (design system v2) ---------- */
        const hub = { feed: null, requestedAt: 0, slide: 0, timer: null, newsFilter: "all" };
        const ICON = {
          play: '<svg class="play-ico-svg" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 1.8v8.4a.5.5 0 0 0 .76.43l6.9-4.2a.5.5 0 0 0 0-.86l-6.9-4.2A.5.5 0 0 0 3 1.8Z" fill="currentColor"/></svg>',
          out: '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M5 2.5H2.5v7h7V7M7 2.5h2.5V5M9.5 2.5l-4 4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
          chev: '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="m4.5 2.5 3.5 3.5-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
          check: '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="m2.5 6.2 2.3 2.3 4.7-5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
        };
        const PF = {
          steam: ["Steam", "var(--pf-steam)"],
          epic: ["Epic Games", "var(--pf-epic)"],
          xbox: ["Xbox", "var(--pf-xbox)"],
          gog: ["GOG", "var(--pf-gog)"],
          local: ["Local", "var(--pf-local)"],
        };
        const isHubView = () => ui.view === "home" || ui.view === "news";
        function pfOf(game) {
          return PF[game?.installSource === "local" ? "local" : game?.store] || PF.steam;
        }
        function pfNode(game) {
          const [label, color] = pfOf(game);
          const node = el("span", "pf");
          const dot = el("i");
          dot.style.background = color;
          node.append(dot, document.createTextNode(label));
          return node;
        }
        function relDate(sec) {
          const t = Number(sec) * 1000;
          if (!t) return "";
          const d = new Date(t), now = new Date();
          const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
          const diff = Math.round((day(now) - day(d)) / 86400000);
          if (diff <= 0) return "Aujourd’hui";
          if (diff === 1) return "Hier";
          if (diff < 7) return `Il y a ${diff} j`;
          const opts = { day: "numeric", month: "short" };
          if (d.getFullYear() !== now.getFullYear()) opts.year = "numeric";
          return d.toLocaleDateString("fr-FR", opts);
        }
        function safeImage(url) {
          return typeof url === "string" && /^https:\/\//.test(url) && url.length < 600 ? url : "";
        }
        function hubItems(kind) {
          const items = Array.isArray(hub.feed?.items) ? hub.feed.items : [];
          return kind ? items.filter((i) => i.kind === kind) : items;
        }
        function hubGame(item) {
          return state.games.find((g) => g.id === item.gameId);
        }
        function hubArt(gameId) {
          const art = hub.feed?.art?.[gameId];
          return art && typeof art === "object" ? art : null;
        }
        function pageArtFor(game) {
          const art = hubArt(game.id);
          if (art) return { hero: safeImage(art.hero), logo: safeImage(art.logo), header: safeImage(art.header) };
          const id = game.store === "steam" && /^\d+$/.test(game.appId || game.id) ? game.appId || game.id : "";
          if (!id) return null;
          const base = `https://cdn.cloudflare.steamstatic.com/steam/apps/${id}/`;
          return { hero: base + "library_hero.jpg", logo: base + "logo.png", header: base + "header.jpg" };
        }
        function openHubLink(url) {
          if (typeof url === "string" && url) send("openHubLink", { url });
        }
        function hubRefs() {
          return state.games
            .filter((g) => g.installed || g.lastPlayed > 0)
            .sort((a, b) => Number(b.installed) - Number(a.installed) || b.lastPlayed - a.lastPlayed)
            .slice(0, 400)
            .map((g) => ({
              gameId: g.id,
              title: g.title,
              store: g.store,
              appId: String(g.appId || (g.store === "steam" && /^\d+$/.test(g.id) ? g.id : "")),
              installed: g.installed,
              lastPlayed: g.lastPlayed,
            }));
        }
        function requestHub(force = false) {
          if (!received || !state.games.length) return;
          if (!force && hub.feed && Date.now() - hub.requestedAt < 60000) return;
          hub.requestedAt = Date.now();
          send("refreshHub", { games: hubRefs(), force });
        }
        window.onHubFeed = (feed) => {
          if (!feed || typeof feed !== "object" || !Array.isArray(feed.items)) return;
          hub.feed = feed;
          updateSidebar();
          if (isHubView()) { updateToolbar(); renderHub(); }
          const dialog = $("gameDialog");
          const game = dialog.open && state.games.find((g) => g.id === ui.dialogGameId);
          if (game) finishGamePage(game);
        };
        function playOrOpen(game) {
          if (game.canLaunch && send("launchGame", { gameId: game.id })) return;
          openGame(game);
        }
        function versionOf(item) {
          const m = String(item.title || "").match(/\b(?:v(?:ersion)?\s?)?(\d+\.\d+(?:\.\d+)*[a-z]?)\b/i);
          if (m) return m[1];
          if (/hotfix/i.test(item.title)) return "hotfix";
          if (/patch/i.test(item.title)) return "patch";
          return "";
        }
        function itemLabel(item) {
          if (item.kind !== "update") return "Annonce";
          if (/hotfix|correctif|fix/i.test(item.title)) return "Correctif";
          return versionOf(item) && !/patch|hotfix/.test(versionOf(item)) ? "Version" : "Mise à jour";
        }
        function goView(view) {
          document.querySelector(`.nav-button[data-view="${view}"]`)?.click();
        }
        function hubImg(src, alt = "") {
          const img = el("img");
          img.alt = alt;
          img.loading = "lazy";
          const queue = (Array.isArray(src) ? src : [src]).map(safeImage).filter(Boolean);
          const next = () => { const url = queue.shift(); if (url) img.src = url; else img.removeAttribute("src"); };
          img.onerror = next;
          next();
          return img;
        }
        function rowHead(title, meta, linkLabel, onLink) {
          const head = el("div", "row-head");
          head.append(el("h2", "row-title", title));
          if (meta) head.append(el("span", "row-meta", meta));
          if (linkLabel) {
            const link = el("button", "row-link");
            link.type = "button";
            link.textContent = linkLabel;
            link.insertAdjacentHTML("beforeend", ICON.chev);
            link.addEventListener("click", onLink);
            head.append(link);
          }
          return head;
        }
        function actionButton(game) {
          const button = el("button", "button primary");
          button.type = "button";
          if (game.canLaunch) {
            button.innerHTML = ICON.play;
            button.append(el("span", "", "Jouer"));
          } else button.textContent = "Voir le jeu";
          button.addEventListener("click", (event) => { event.stopPropagation(); playOrOpen(game); });
          return button;
        }

        function heroSlides() {
          const slides = [], seen = new Set();
          const items = hubItems().slice().sort((a, b) => Number(hubGame(b)?.installed) - Number(hubGame(a)?.installed) || b.date - a.date);
          for (const item of items) {
            const game = hubGame(item);
            const art = game && pageArtFor(game);
            if (!game || !art?.hero || seen.has(game.id)) continue;
            seen.add(game.id);
            slides.push({ game, art, item });
            if (slides.length === 3) return slides;
          }
          for (const game of state.games.filter((g) => g.lastPlayed > 0).sort((a, b) => b.lastPlayed - a.lastPlayed)) {
            const art = pageArtFor(game);
            if (!art?.hero || seen.has(game.id)) continue;
            seen.add(game.id);
            slides.push({ game, art, item: null });
            if (slides.length === 3) break;
          }
          return slides;
        }
        function buildHero(slides) {
          const hero = el("section", "hub-hero");
          const index = Math.min(hub.slide, slides.length - 1);
          const { game, art, item } = slides[index];
          const bg = hubImg(art.hero);
          bg.className = "bg";
          bg.onerror = () => { if (art.header && bg.src !== art.header) bg.src = art.header; };
          hero.append(bg);
          if (slides.length > 1) {
            const pager = el("div", "hub-pager");
            slides.forEach((_, i) => {
              const dot = el("button", i === index ? "on" : "");
              dot.type = "button";
              dot.setAttribute("aria-label", `Jeu ${i + 1}`);
              dot.addEventListener("click", (event) => { event.stopPropagation(); hub.slide = i; renderHub(); });
              pager.append(dot);
            });
            hero.append(pager);
          }
          const copy = el("div", "copy");
          const titleFallback = () => copy.querySelector(".lg")?.replaceWith(el("div", "hero-title-fallback", game.title));
          if (art.logo) {
            const logo = hubImg(art.logo, game.title);
            logo.className = "lg";
            logo.onerror = titleFallback;
            copy.append(logo);
          } else copy.append(el("div", "hero-title-fallback", game.title));
          if (item) {
            const version = versionOf(item);
            copy.append(el("span", "tag onimg", itemLabel(item) + (version && !/patch|hotfix/.test(version) ? ` · ${version}` : "")));
            copy.append(el("h3", "", item.title));
            copy.append(el("p", "", [relDate(item.date), pfOf(game)[0]].filter(Boolean).join(" · ")));
          } else {
            copy.append(el("p", "", [game.playtimeFormatted !== "Jamais joué" ? game.playtimeFormatted : "", pfOf(game)[0]].filter(Boolean).join(" · ")));
          }
          const acts = el("div", "acts");
          acts.append(actionButton(game));
          if (item?.url) {
            const read = el("button", "glass-button", "Lire l’annonce");
            read.type = "button";
            read.addEventListener("click", (event) => { event.stopPropagation(); openHubLink(item.url); });
            acts.append(read);
          }
          copy.append(acts);
          hero.append(copy);
          if (game.installed) {
            const stateTag = el("div", "state");
            const played = game.playtimeFormatted && game.playtimeFormatted !== "Jamais joué" ? ` · ${game.playtimeFormatted}` : "";
            stateTag.append(el("span", "tag onimg", "Installé" + played));
            hero.append(stateTag);
          }
          hero.addEventListener("click", () => openGame(game));
          return hero;
        }
        function updateCard(item) {
          const game = hubGame(item);
          const art = (game && pageArtFor(game)) || {};
          const card = el("div", "ucard");
          const top = el("div", "art");
          top.append(hubImg([art.header, art.hero]), el("span", "tag onimg", itemLabel(item)));
          const body = el("div", "body");
          const meta = el("div", "g");
          meta.append(game ? pfNode(game) : el("span", "", item.gameTitle || ""), el("span", "", relDate(item.date)));
          const foot = el("div", "foot");
          const version = versionOf(item);
          foot.append(version ? el("span", "ver", version) : el("span"));
          if (game) {
            const mini = el("button", game.canLaunch ? "mini-play" : "mini-play open");
            mini.type = "button";
            mini.setAttribute("aria-label", game.canLaunch ? `Jouer à ${game.title}` : `Voir ${game.title}`);
            mini.innerHTML = game.canLaunch ? ICON.play : ICON.chev;
            mini.addEventListener("click", (event) => { event.stopPropagation(); playOrOpen(game); });
            foot.append(mini);
          }
          body.append(meta, el("h4", "", item.title), foot);
          card.append(top, body);
          card.title = item.title;
          card.addEventListener("click", () => openHubLink(item.url));
          return card;
        }
        function feedItem(item) {
          const game = hubGame(item);
          const art = (game && pageArtFor(game)) || {};
          const row = el("div", "feed-item");
          const copy = el("div");
          const meta = el("div", "g");
          meta.append(el("span", item.kind === "update" ? "tag upd" : "tag news", itemLabel(item)), el("span", "", game?.title || item.gameTitle || ""));
          copy.append(meta, el("h5", "", item.title));
          row.append(hubImg([art.header, art.hero]), copy, el("time", "", relDate(item.date)));
          row.title = item.title;
          row.addEventListener("click", () => openHubLink(item.url));
          return row;
        }
        function priceLabel(release) {
          const cents = Number(release.priceCents);
          if (!Number.isFinite(cents)) return "";
          if (cents === 0) return "Gratuit";
          try {
            return new Intl.NumberFormat("fr-FR", { style: "currency", currency: release.currency || "EUR" }).format(cents / 100);
          } catch { return euros(cents); }
        }
        function releaseItem(release) {
          const row = el("div", "feed-item release");
          const copy = el("div");
          copy.append(el("h5", "", release.name), el("div", "g", priceLabel(release)));
          const link = el("span", "store-link", "Steam");
          link.insertAdjacentHTML("beforeend", ICON.out);
          row.append(hubImg(release.image), copy, link);
          row.title = release.name;
          row.addEventListener("click", () => openHubLink(release.url));
          return row;
        }
        function untilLabel(sec) {
          const end = new Date(Number(sec) * 1000);
          if (end.toDateString() === new Date().toDateString())
            return "Gratuit jusqu’à " + end.toLocaleTimeString("fr-FR", { hour: "numeric", minute: end.getMinutes() ? "2-digit" : undefined });
          return "Gratuit jusqu’au " + end.toLocaleDateString("fr-FR", { day: "numeric", month: "short" });
        }
        function freeBox(list) {
          const current = list.filter((f) => f.current === true);
          const upcoming = list.filter((f) => f.current !== true);
          const shown = (current.length ? current : upcoming).slice(0, 2);
          const box = el("div", "free-box");
          const pair = el("div", shown.length === 1 ? "free-pair single" : "free-pair");
          for (const free of shown) {
            const tile = el("div", "free-tile");
            const text = el("div", "t");
            text.append(el("b", "", free.title), el("small", "", free.current ? untilLabel(free.end) : "Dès le " + new Date(free.start * 1000).toLocaleDateString("fr-FR", { day: "numeric", month: "short" })));
            tile.append(hubImg(free.image, free.title), text);
            tile.addEventListener("click", () => openHubLink(free.url));
            pair.append(tile);
          }
          const bar = el("div", "free-bar");
          if (current.length) {
            const left = Math.max(0, Number(current[0].end) - Date.now() / 1000);
            bar.append(el("span", "countdown", left < 86400 ? "Dernier jour" : `Encore ${Math.ceil(left / 86400)} j`));
          }
          const next = current.length ? upcoming[0] : upcoming[shown.length];
          if (next) {
            const label = el("span", "next", "Ensuite ");
            label.append(el("b", "", next.title));
            bar.append(label);
          }
          const claim = el("button", "store-link", "Récupérer");
          claim.type = "button";
          claim.insertAdjacentHTML("beforeend", ICON.out);
          claim.addEventListener("click", () => openHubLink((current[0] || shown[0])?.url || "https://store.epicgames.com/fr/free-games"));
          bar.append(claim);
          box.append(pair, bar);
          return box;
        }
        function stopHeroTimer() {
          clearInterval(hub.timer);
          hub.timer = null;
        }
        function renderHub() {
          const pane = $("hubPane");
          stopHeroTimer();
          pane.replaceChildren();
          if (ui.view === "news") return renderNewsView(pane);
          if (!hub.feed) {
            pane.append(el("div", "hub-skeleton"));
            return;
          }
          const slides = heroSlides();
          if (slides.length) {
            pane.append(buildHero(slides));
            if (slides.length > 1)
              hub.timer = setInterval(() => {
                if ($("hubPane").hidden || $("gameDialog").open) return;
                hub.slide = (hub.slide + 1) % slides.length;
                renderHub();
              }, 9000);
          }
          const updates = hubItems("update").slice(0, 4);
          if (updates.length) {
            pane.append(rowHead("Mises à jour", "de tes jeux", "Tout voir", () => { hub.newsFilter = "update"; goView("news"); }));
            const grid = el("div", "hub-updates");
            updates.forEach((item) => grid.append(updateCard(item)));
            pane.append(grid);
          }
          const news = hubItems("news").slice(0, 5);
          const free = Array.isArray(hub.feed.freeGames) ? hub.feed.freeGames : [];
          const releases = Array.isArray(hub.feed.releases) ? hub.feed.releases.slice(0, 4) : [];
          const duo = el("div", "hub-duo");
          if (news.length) {
            const col = el("div");
            col.append(rowHead("Actus", "annonces officielles", "Tout voir", () => { hub.newsFilter = "news"; goView("news"); }));
            const feed = el("div", "feed");
            news.forEach((item) => feed.append(feedItem(item)));
            col.append(feed);
            duo.append(col);
          }
          if (free.length || releases.length) {
            const col = el("div");
            if (free.length) col.append(rowHead("Offerts", "Epic Games Store"), freeBox(free));
            if (releases.length) {
              col.append(rowHead("Sorties", "cette semaine sur Steam"));
              const feed = el("div", "feed");
              releases.forEach((release) => feed.append(releaseItem(release)));
              col.append(feed);
            }
            duo.append(col);
          }
          if (duo.children.length) pane.append(duo);
          if (!slides.length && !updates.length && !news.length)
            pane.append(el("p", "hub-note", "Les actus de tes jeux arrivent ici dès ta première partie."));
        }
        function renderNewsView(pane) {
          const filters = el("div", "news-filters");
          for (const [key, label] of [["all", "Tout"], ["news", "Actus"], ["update", "Mises à jour"]]) {
            const button = el("button", hub.newsFilter === key ? "on" : "", label);
            button.type = "button";
            button.addEventListener("click", () => { hub.newsFilter = key; renderHub(); });
            filters.append(button);
          }
          pane.append(filters);
          if (!hub.feed) {
            pane.append(el("div", "hub-skeleton"));
            return;
          }
          const items = hubItems(hub.newsFilter === "all" ? null : hub.newsFilter);
          const feed = el("div", "feed");
          if (items.length) items.forEach((item) => feed.append(feedItem(item)));
          else feed.append(el("div", "feed-empty", "Rien de neuf pour l’instant."));
          pane.append(feed);
        }
        function renderViewMeta(node) {
          const item = (text, color) => {
            const span = el("span", "meta-item");
            if (color) { const dot = el("i"); dot.style.background = color; span.append(dot); }
            span.append(document.createTextNode(text));
            return span;
          };
          const parts = [];
          if (ui.view === "home") {
            parts.push(item(new Date().toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" })));
            const fresh = hubItems("update").filter((i) => Date.now() / 1000 - i.date < 14 * 86400).length;
            if (fresh) parts.push(item(`${fresh} mise${fresh > 1 ? "s" : ""} à jour`));
            const free = (hub.feed?.freeGames || []).filter((f) => f.current === true).length;
            if (free) parts.push(item(`${free} jeu${free > 1 ? "x" : ""} offert${free > 1 ? "s" : ""}`));
          } else if (ui.view === "news") {
            parts.push(item(hub.feed ? `${hubItems().length} annonces de tes jeux` : "Chargement…"));
          } else if (ui.view === "library" && received) {
            for (const key of ["steam", "epic", "xbox", "gog", "local"]) {
              const count = state.games.filter((g) => (key === "local" ? isLocalCustomGame(g) : g.store === key)).length;
              if (count) parts.push(item(`${PF[key][0].replace(" Games", "")} ${locale.format(count)}`, PF[key][1]));
            }
          }
          if (!parts.length) return;
          node.replaceChildren();
          parts.forEach((part, i) => {
            if (i) node.append(el("span", "meta-sep"));
            node.append(part);
          });
        }

        /* Fiche jeu pleine page : enveloppe du rendu existant. */
        function renderGameDialog(game) {
          renderGameDialogBody(game);
          finishGamePage(game);
        }
        function pageStat(label, value) {
          const stat = el("div", "page-stat");
          const b = el("b");
          if (value instanceof Node) b.append(value);
          else b.textContent = value;
          stat.append(el("small", "", label), b);
          return stat;
        }
        function rendererName(game) {
          if (platforms(game).includes("mac") && game.store !== "xbox") return "Natif Mac";
          return { d3dmetal: "D3DMetal", dxmt: "DXMT", dxvk: "DXVK", wined3d: "WineD3D" }[game.requiredRenderer] || "";
        }
        function finishGamePage(game) {
          const dialog = $("gameDialog");
          const art = pageArtFor(game);
          const logo = $("dialogLogo");
          const logoURL = art?.logo || "";
          if (logo.dataset.src !== logoURL) {
            logo.dataset.src = logoURL;
            logo.hidden = true;
            dialog.classList.remove("has-logo");
            logo.onload = () => { logo.hidden = false; dialog.classList.add("has-logo"); };
            logo.onerror = () => { logo.hidden = true; dialog.classList.remove("has-logo"); };
            if (logoURL) { logo.alt = game.title; logo.src = logoURL; } else logo.removeAttribute("src");
          }

          const stats = $("dialogStats");
          stats.replaceChildren(pageStat("Plateforme", pfNode(game)));
          if (game.playtimeFormatted && game.playtimeFormatted !== "Jamais joué") stats.append(pageStat("Temps de jeu", game.playtimeFormatted));
          const engine = [rendererName(game), game.requiredGraphicsAPI && game.requiredGraphicsAPI !== "unknown" ? game.requiredGraphicsAPI : ""].filter(Boolean).join(" · ");
          if (engine) stats.append(pageStat("Moteur", engine));
          const ach = game.achievements;
          if (ach && Number(ach.total) > 0) stats.append(pageStat("Succès", `${locale.format(Number(ach.unlockedCount) || 0)} / ${locale.format(Number(ach.total))}`));

          const side = $("dialogSide");
          const achievements = $("dialogAchievementsContainer");
          side.replaceChildren();
          if (achievements && achievements.childElementCount) side.append(achievements);
          else if (achievements) achievements.remove();
          const rows = [];
          if (rendererName(game)) rows.push(["Traduction", rendererName(game)]);
          if (game.requiredGraphicsAPI && game.requiredGraphicsAPI !== "unknown") rows.push(["API graphique", game.requiredGraphicsAPI]);
          const dpr = window.devicePixelRatio || 1;
          rows.push(["Écran", `${Math.round(screen.width * dpr)} × ${Math.round(screen.height * dpr)}`]);
          if (game.installed) rows.push(["État", "Installé sur ce Mac"]);
          const panel = el("div", "panel");
          panel.append(el("h6", "", "Sur ce Mac"));
          const kv = el("div", "kv");
          for (const [k, v] of rows) {
            const row = el("div");
            row.append(el("span", "", k), el("b", "", v));
            kv.append(row);
          }
          panel.append(kv);
          side.append(panel);
          renderPageFeed(game);
        }
        function renderPageFeed(game) {
          const tabs = $("dialogTabs"), feed = $("dialogFeed");
          const all = hubItems().filter((i) => i.gameId === game.id);
          if (!all.length) {
            tabs.hidden = true;
            feed.hidden = true;
            return;
          }
          const tab = ui.pageTab || "all";
          tabs.replaceChildren();
          for (const [key, label] of [["all", "Tout"], ["news", "Actus"], ["update", "Mises à jour"]]) {
            const count = key === "all" ? all.length : all.filter((i) => i.kind === key).length;
            if (key !== "all" && !count) continue;
            const button = el("button", tab === key ? "on" : "", label);
            button.type = "button";
            button.append(el("em", "", String(count)));
            button.addEventListener("click", () => { ui.pageTab = key; renderPageFeed(game); });
            tabs.append(button);
          }
          tabs.hidden = false;
          const art = pageArtFor(game) || {};
          feed.className = "page-feed feed";
          feed.replaceChildren();
          for (const item of all.filter((i) => tab === "all" || i.kind === tab)) {
            const story = el("div", "story");
            const copy = el("div");
            copy.append(el("span", item.kind === "update" ? "tag upd" : "tag news", `${itemLabel(item)} · ${relDate(item.date)}`), el("h5", "", item.title));
            if (item.summary) copy.append(el("p", "", item.summary));
            story.append(hubImg([art.header, art.hero]), copy);
            story.addEventListener("click", () => openHubLink(item.url));
            feed.append(story);
          }
          feed.hidden = false;
        }
