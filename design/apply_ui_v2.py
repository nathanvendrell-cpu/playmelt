#!/usr/bin/env python3
"""Applique le design system v2 (maquette validée le 12/11/2026) à index.html.
Chaque remplacement doit trouver son ancre exactement une fois, sinon rien n'est écrit."""
import pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = ROOT / "index.html"
CSS = (pathlib.Path(__file__).resolve().parent / "ui_v2.css").read_text()
s = INDEX.read_text()
if "DESIGN SYSTEM v2" in s:
    sys.exit("déjà appliqué")

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"ancre trouvée {n} fois (attendu {count}) : {old[:80]!r}")
    s = s.replace(old, new)

EXTRA_CSS = """
      .hub-pane .row-head { display: flex !important; justify-content: flex-start !important; gap: 10px; }
      .hub-pane .row-meta { color: var(--faint) !important; font-weight: 550 !important; }
      .row-link { margin-left: auto; border: 0; background: none; padding: 0; font-size: 12px; font-weight: 590; color: var(--muted); display: inline-flex; align-items: center; gap: 3px; }
      .row-link svg { width: 11px; height: 11px; }
      .hero-title-fallback { font-size: 34px; font-weight: 800; letter-spacing: -0.03em; line-height: 1.05; margin-bottom: 18px; text-shadow: 0 4px 18px rgba(0, 0, 0, 0.4); }
      .game-page .page-back {
        top: calc(var(--chrome-top) + 2px) !important; left: 32px !important; right: auto !important; width: auto !important; height: 30px !important;
        padding: 0 12px 0 9px !important; border-radius: 9px !important; font-size: 12px !important; display: inline-flex !important; gap: 6px;
        background: rgba(255, 255, 255, 0.14) !important; color: #fff !important; border: 0 !important;
      }
      .game-page .page-back svg { width: 11px; height: 11px; }
      .page-cols:has(.page-feed[hidden]) { grid-template-columns: 1fr; }
      .page-cols:has(.page-feed[hidden]) .page-side { grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); align-items: start; }
      [hidden][hidden] { display: none !important; }
      .hub-pane { flex: 1; min-height: 0; overflow: auto; }
      .game-page #dialogBody { flex-direction: row !important; align-items: center !important; justify-content: flex-start !important; gap: 10px !important; }
      .game-page .page-stats { margin: 12px 0 22px; }
      .game-page .dialog-grid-btn { height: 44px !important; padding: 0 16px !important; display: inline-flex !important; align-items: center !important; justify-content: center !important; min-height: 0 !important; }
      .game-page:focus, .game-page:focus-visible { outline: none !important; }
      .sub-body:focus { outline: none; }
      .view-subtitle { gap: 10px !important; }
      .view-subtitle .meta-sep::before { margin-right: 0 !important; }
      .toolbar { flex-shrink: 0; }
"""

# 1. Feuille de style v2, en fin de feuille.
rep("    </style>", CSS + EXTRA_CSS + "    </style>")

# 2. Images des boutiques (sorties Steam, offerts Epic).
rep("img-src 'self' data: metalmaxart: https://shared.fastly.steamstatic.com",
    "img-src 'self' data: metalmaxart: https://shared.fastly.steamstatic.com https://shared.akamai.steamstatic.com https://cdn2.unrealengine.com")

# 2b. Actions natives de l'Accueil et de l'abonnement (absentes de la liste blanche).
rep('''          "installNvidiaBridge",
        ]);''', '''          "installNvidiaBridge",
          "refreshHub",
          "openHubLink",
          "openCheckout",
          "activateLicense",
          "deactivateLicense",
        ]);''')

# 3. Pictogrammes (sprite) juste après <body>.
SPRITE = """  <body>
    <svg width="0" height="0" style="position: absolute" aria-hidden="true"><defs>
      <symbol id="i-home" viewBox="0 0 16 16"><path d="M2.5 7 8 2.5 13.5 7v6a.5.5 0 0 1-.5.5h-3v-4H6v4H3a.5.5 0 0 1-.5-.5Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></symbol>
      <symbol id="i-lib" viewBox="0 0 16 16"><rect x="2" y="2.5" width="5" height="5" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="9" y="2.5" width="5" height="5" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="2" y="9.5" width="5" height="5" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.5"/><rect x="9" y="9.5" width="5" height="5" rx="1.3" fill="none" stroke="currentColor" stroke-width="1.5"/></symbol>
      <symbol id="i-installed" viewBox="0 0 16 16"><path d="M4.5 2.8v10.4a.6.6 0 0 0 .9.5l8.3-5.2a.6.6 0 0 0 0-1L5.4 2.3a.6.6 0 0 0-.9.5Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></symbol>
      <symbol id="i-star" viewBox="0 0 16 16"><path d="m8 2.3 1.7 3.6 3.9.5-2.9 2.7.8 3.9L8 11.1 4.5 13l.8-3.9-2.9-2.7 3.9-.5Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></symbol>
      <symbol id="i-clock" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.7" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 5v3.2l2.2 1.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></symbol>
      <symbol id="i-news" viewBox="0 0 16 16"><path d="M3 3h8v10H4a1 1 0 0 1-1-1Zm8 3h2v6a1 1 0 0 1-2 0M5 6h4M5 8.5h4M5 11h2.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></symbol>
      <symbol id="i-dl" viewBox="0 0 16 16"><path d="M8 2.5v8m0 0L4.8 7.3M8 10.5l3.2-3.2M3 13.5h10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
      <symbol id="i-chip" viewBox="0 0 16 16"><rect x="3.5" y="3.5" width="9" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6 1.5v2m4-2v2m-4 9v2m4-2v2M1.5 6h2m-2 4h2m9-4h2m-2 4h2" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></symbol>
    </defs></svg>"""
rep("  <body>", SPRITE)

# 4. Barre latérale.
start = s.index('        <nav class="nav" id="sidebarNav">')
end = s.index("        </nav>", start) + len("        </nav>")
def nb(view, label, count_id, icon=None, dot=None, badge=False, extra=""):
    lead = f'<svg class="nav-ico"><use href="#{icon}"/></svg>' if icon else f'<i class="nav-dot" style="background: var(--pf-{dot})"></i>'
    count = f'<span class="nav-badge" id="{count_id}" hidden></span>' if badge else (f'<span class="nav-count" id="{count_id}">—</span>' if count_id else "")
    return f'              <button class="nav-button" data-view="{view}"{extra}>{lead}<span>{label}</span>{count}</button>\n'
NAV = ('        <nav class="nav" id="sidebarNav">\n'
       '          <div class="nav-section" data-section-id="library">\n            <div class="nav-section-items">\n'
       + nb("home", "Accueil", "countHome", icon="i-home", badge=True, extra=' aria-current="page"')
       + nb("library", "Bibliothèque", "countAll", icon="i-lib")
       + nb("installed", "Installés", "countInstalled", icon="i-installed")
       + nb("favorites", "Favoris", "countFavorites", icon="i-star")
       + nb("recent", "Récents", "countRecent", icon="i-clock")
       + nb("news", "Actus", "countNews", icon="i-news")
       + '            </div>\n          </div>\n'
       '          <div class="nav-section" data-section-id="platforms">\n            <div class="nav-group">Plateformes</div>\n            <div class="nav-section-items">\n'
       + nb("steam", "Steam", "countSteam", dot="steam")
       + nb("epic", "Epic Games", "countEpic", dot="epic")
       + nb("xbox", "Xbox Game Pass", "countXbox", dot="xbox")
       + nb("gog", "GOG", "countGOG", dot="gog")
       + nb("local", "Local", "countLocal", dot="local")
       + '            </div>\n          </div>\n'
       '          <div class="nav-section" data-section-id="system">\n            <div class="nav-group">Système</div>\n            <div class="nav-section-items">\n'
       + nb("installManager", "Téléchargements", "countInstalling", icon="i-dl", extra=' id="navInstallButton"')
       + nb("diagnostics", "État du Mac", None, icon="i-chip")
       + '            </div>\n          </div>\n        </nav>')
s = s[:start] + NAV + s[end:]

# 5. Bandeau : plus de pastille d'icône ; Accueil = nouvelle zone.
rep('              <span class="section-chip" id="sectionChip" aria-hidden="true"></span>\n', "")
rep('''        <section
          class="library-pane"
          id="libraryPane"''', '''        <section class="hub-pane" id="hubPane" aria-label="Accueil" hidden></section>
        <section
          class="library-pane"
          id="libraryPane"''')

# 6. Fiche jeu pleine page.
rep('''    <dialog class="game-dialog" id="gameDialog" aria-labelledby="dialogTitle">
      <div class="dialog-hero" id="dialogHero">
        <div class="dialog-hero-blur" id="dialogHeroBlur"></div>
        <img class="dialog-hero-img" id="dialogHeroImg" alt="" />
        <div class="dialog-hero-scrim"></div>
        <button class="dialog-close" id="dialogClose" aria-label="Fermer">
          ×
        </button>
        <div class="dialog-hero-badges" id="dialogHeroBadges"></div>
      </div>
      <div class="dialog-content">
        <p class="dialog-store" id="dialogStore"></p>
        <h2 id="dialogTitle"></h2>
        <div id="dialogBody"></div>
      </div>
    </dialog>''', '''    <dialog class="game-dialog game-page" id="gameDialog" aria-labelledby="dialogTitle">
      <div class="dialog-hero" id="dialogHero">
        <div class="dialog-hero-blur" id="dialogHeroBlur"></div>
        <img class="dialog-hero-img" id="dialogHeroImg" alt="" />
        <div class="dialog-hero-scrim"></div>
        <button class="dialog-close page-back" id="dialogClose" aria-label="Retour"><svg viewBox="0 0 12 12"><path d="M7.5 2.5 4 6l3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg><span>Retour</span></button>
        <img class="page-logo" id="dialogLogo" alt="" hidden />
        <div class="dialog-hero-badges" id="dialogHeroBadges"></div>
      </div>
      <div class="dialog-content">
        <p class="dialog-store" id="dialogStore"></p>
        <h2 id="dialogTitle"></h2>
        <div class="page-stats" id="dialogStats"></div>
        <div id="dialogBody"></div>
        <div class="page-tabs" id="dialogTabs" hidden></div>
        <div class="page-cols"><div class="page-feed" id="dialogFeed" hidden></div><aside class="page-side" id="dialogSide"></aside></div>
      </div>
    </dialog>''')

# 7. Vue de départ : Accueil.
rep('        const ui = {\n          view: "library",', '        const ui = {\n          view: "home",')

# 8. Bandeau : titres, méta, visibilités.
rep('''          const titles = {
            library: "Bibliothèque",''', '''          const titles = {
            home: new Date().getHours() >= 18 ? "Bonsoir" : "Bonjour",
            news: "Actus",
            library: "Bibliothèque",''')
rep('''          if ($("viewSubtitle")) $("viewSubtitle").textContent = subtitles[ui.view] || "";''',
    '''          if ($("viewSubtitle")) {
            $("viewSubtitle").textContent = subtitles[ui.view] || "";
            renderViewMeta($("viewSubtitle"));
          }''')
rep('''          $("libraryPane").hidden = toolbarHidden;''', '''          const hubView = ui.view === "home" || ui.view === "news";
          $("libraryPane").hidden = toolbarHidden || hubView;
          $("hubPane").hidden = !hubView;
          if (hubView) { $("installFilter").hidden = true; $("platformFilter").hidden = true; }''')
rep('''          updateLayoutToggle();

          const show = (id, visible)''', '''          updateLayoutToggle();
          if (hubView && $("layoutToggle")) $("layoutToggle").hidden = true;

          const show = (id, visible)''')

# 9. « Reprendre » : bouton Jouer visible.
rep('''          if (game.playtimeFormatted && game.playtimeFormatted !== "Jamais joué")
            copy.append(el("span", "continue-meta", game.playtimeFormatted));
          card.append(artBox, copy);''', '''          const metaParts = [];
          if (game.playtimeFormatted && game.playtimeFormatted !== "Jamais joué") metaParts.push(game.playtimeFormatted);
          metaParts.push(pfOf(game)[0]);
          copy.append(el("span", "continue-meta", metaParts.join(" · ")));
          card.append(artBox, copy);
          if (game.canLaunch) {
            const cp = el("span", "continue-play");
            cp.innerHTML = ICON.play + "<span>Jouer</span>";
            card.append(cp);
          }''')

# 10. Fiche : enveloppe (illustrations, logo, chiffres clés, colonne latérale, actus).
rep("        function renderGameDialog(game) {\n          ui.dialogRenderProtection = renderProtectionEnabled();",
    "        function renderGameDialogBody(game) {\n          ui.dialogRenderProtection = renderProtectionEnabled();")
rep('''            const wideUrl = game.imageURL || (game.store === "steam"''',
    '''            const wideUrl = pageArtFor(game)?.hero || game.imageURL || (game.store === "steam"''')
rep('''        function openGame(game) {
          ui.dialogGameId = game.id;
          renderGameDialog(game);
          if (!$("gameDialog").open) $("gameDialog").showModal();
        }''', '''        function openGame(game) {
          const dialog = $("gameDialog");
          if (ui.dialogGameId !== game.id) { ui.pageTab = "all"; dialog.scrollTop = 0; }
          ui.dialogGameId = game.id;
          renderGameDialog(game);
          if (!dialog.open) {
            dialog.show();
            dialog.tabIndex = -1;
            dialog.focus({ preventScroll: true });
            dialog.scrollTop = 0;
          }
        }''')

# 11. Navigation : la fiche se ferme ; Accueil et Actus.
rep('''            ui.view = button.dataset.view;
            ui.limit = 48;
            updateToolbar();''', '''            ui.view = button.dataset.view;
            ui.limit = 48;
            if ($("gameDialog").open) $("gameDialog").close();
            updateToolbar();''')
rep('''            if (ui.view === "diagnostics") renderDiagnostics();
            else if (ui.view === "installManager") renderInstallManager();
            else renderLibrary();
          }),''', '''            if (ui.view === "diagnostics") renderDiagnostics();
            else if (ui.view === "installManager") renderInstallManager();
            else if (ui.view === "home" || ui.view === "news") { renderHub(); requestHub(); }
            else renderLibrary();
          }),''')
rep('''          if (ui.view === "diagnostics") renderDiagnostics();
          else renderLibrary();
        }''', '''          if (ui.view === "diagnostics") renderDiagnostics();
          else if (ui.view === "home" || ui.view === "news") renderHub();
          else renderLibrary();
        }''')
rep('''          if (ui.view === "diagnostics") renderDiagnostics();
          else if (libraryChanged) renderLibrary();
          updateJobIndicator();''', '''          if (ui.view === "diagnostics") renderDiagnostics();
          else if (libraryChanged) { renderLibrary(); if (ui.view === "home" || ui.view === "news") renderHub(); }
          if (libraryChanged && state.games.length) requestHub();
          updateJobIndicator();''')

# 12. Recherche depuis l'Accueil : bascule vers la Bibliothèque.
rep('''        $("search").addEventListener("input", (event) => {
          ui.query = event.target.value.trim().toLocaleLowerCase("fr");
          ui.limit = 48;
          renderLibrary();''', '''        $("search").addEventListener("input", (event) => {
          ui.query = event.target.value.trim().toLocaleLowerCase("fr");
          ui.limit = 48;
          if ((ui.view === "home" || ui.view === "news") && ui.query) { ui.view = "library"; updateToolbar(); }
          renderLibrary();''')
rep('''        $("refresh").addEventListener("click", () => {
          lastGamesSignature = "";
          ui.artworkGeneration += 1;
          send("refresh");''', '''        $("refresh").addEventListener("click", () => {
          lastGamesSignature = "";
          ui.artworkGeneration += 1;
          send("refresh");
          if (ui.view === "home" || ui.view === "news") requestHub(true);''')
rep('''        $("dialogClose").addEventListener("click", () =>
          $("gameDialog").close(),
        );''', '''        $("dialogClose").addEventListener("click", () =>
          $("gameDialog").close(),
        );
        document.addEventListener("keydown", (event) => {
          if (event.key !== "Escape" || !$("gameDialog").open) return;
          if ($("gameSettingsDialog").open || $("subscriptionDialog").open) return;
          $("gameDialog").close();
        });''')

# 13. Compteurs Accueil / Actus.
rep('''          const job = state.installJob;
          const isInstalling = job &&''', '''          const homeBadge = $("countHome");
          if (homeBadge) {
            const fresh = hubItems("update").filter((i) => Date.now() / 1000 - i.date < 14 * 86400).length;
            homeBadge.textContent = String(fresh);
            homeBadge.hidden = fresh === 0;
          }
          const newsCount = $("countNews");
          if (newsCount) newsCount.textContent = hub.feed ? locale.format(hubItems().length) : "—";
          const job = state.installJob;
          const isInstalling = job &&''')

# 14. Abonnement : nouvelle feuille.
start = s.index("        function openSubscription() {")
end = s.index('        $("subscriptionClose").addEventListener', start)
s = s[:start] + (pathlib.Path(__file__).resolve().parent / "ui_v2_subscription.js").read_text() + s[end:]

# 15. Code Accueil + fiche, juste avant render().
rep("        function render() {\n          updateSidebar();",
    (pathlib.Path(__file__).resolve().parent / "ui_v2_hub.js").read_text() + "        function render() {\n          updateSidebar();")

rep("        setupSidebarAccordion();\n        render();", "        // v2 : barre latérale fixe, sans sections repliables ni réordonnables.\n        render();")

INDEX.write_text(s)
print("design system v2 appliqué")
