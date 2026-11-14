/* Installed library presentation. No network, persistence or launch side effects
   outside the existing native bridge. */
(function (root) {
  'use strict';
  const tiers = [
    [0, 'Nouveau venu'], [1, 'Éclaireur'], [10, 'Habitué'], [50, 'Vétéran'],
    [100, 'Expert'], [250, 'Maître'], [500, 'Grand maître'], [1000, 'Légende vivante'],
  ];
  const rewards = [1,2,5,10,50,100,1000,10000];
  /* Noms de paliers propres à chaque jeu : écrits pour les jeux connus, sinon thème du genre deviné au titre.
     Les seuils (heures) et les points ne changent pas ; seuls les noms s'adaptent. */
  const L = {
    factorio: ['Naufragé','Mineur','Ingénieur','Logisticien','Maître du rail','Architecte d’usine','Lanceur de fusées','L’usine doit grandir'],
    satisfactory: ['Pionnier','Prospecteur','Ingénieur de terrain','Bâtisseur','Chef d’usine','Architecte orbital','Employé du mois','Légende de l’usine'],
    finalfantasy: ['Recrue','Mercenaire','Soldat 3e classe','Soldat 1re classe','Maître des matérias','Chevalier de Gaia','Héros de la Planète','Légende de Midgar'],
    spiderman: ['Voisin sympa','Lanceur de toile','Justicier du quartier','Protecteur du Queens','Héros de Manhattan','Gardien de New York','Araignée de légende','Icône de la ville'],
    megabonk: ['Bonk débutant','Cogneur','Ramasseur d’XP','Survivant','Gros bourrin','Démolisseur','Méga cogneur','Dieu du bonk'],
    rocketleague: ['Bronze','Argent','Or','Platine','Diamant','Champion','Grand champion','Légende supersonique'],
    souls: ['Sans-éclat','Vagabond','Chevalier errant','Porteur de rune','Pourfendeur de demi-dieux','Seigneur des cendres','Prétendant au trône','Seigneur d’Elden'],
    stardew: ['Citadin','Apprenti fermier','Fermier','Éleveur','Artisan de la vallée','Pilier du village','Fermier légendaire','Esprit de la vallée'],
    cyberpunk: ['Inconnu','Gamin des rues','Mercenaire','Netrunner','Solo','Fixer','Légende des rues','Légende de Night City'],
    elderscrolls: ['Prisonnier','Aventurier','Mercenaire','Thane','Maître de guilde','Héros de la Bordure','Enfant de dragon','Légende de Tamriel'],
    diablo: ['Errant','Aventurier','Pourfendeur','Chasseur de démons','Champion du Sanctuaire','Héros du Sanctuaire','Fléau des Enfers','Néphalem'],
    idle: ['Paysan','Écuyer','Chasseur','Collecteur d’âmes','Ascensionné','Maître des portails','Pourfendeur divin','Tueur éternel'],
    racing: ['Débutant','Pilote amateur','Pilote','Pilote confirmé','Champion régional','Pilote d’élite','Champion du monde','Légende de la piste'],
    war: ['Recrue','Soldat','Caporal','Sergent','Lieutenant','Capitaine','Commandant','Légende du front'],
    fantasy: ['Paysan','Aventurier','Héros en devenir','Chevalier','Champion','Seigneur','Héros des légendes','Mythe vivant'],
    business: ['Stagiaire','Gérant','Entrepreneur','Directeur','Magnat local','Tycoon','Empire','Légende des affaires'],
    farm: ['Novice des champs','Jardinier','Fermier','Éleveur','Maître des récoltes','Seigneur du domaine','Fermier d’exception','Légende du terroir'],
    horror: ['Proie','Survivant','Rescapé','Traqueur','Chasseur de cauchemars','Briseur de malédictions','Maître de la peur','Celui qui ne dort plus'],
    space: ['Cadet','Pilote','Navigateur','Explorateur','Capitaine','Amiral','Conquérant stellaire','Légende galactique'],
    builder: ['Apprenti','Bricoleur','Bâtisseur','Ingénieur','Architecte','Maître d’œuvre','Bâtisseur d’empire','Démiurge'],
    sport: ['Remplaçant','Titulaire','Capitaine','Pro','International','Star','Icône','Légende du sport'],
    arcade: ['Joueur du dimanche','Accro','Scoreur','Roi du combo','Chasseur de records','As de l’arcade','Recordman','Score éternel'],
    puzzle: ['Curieux','Apprenti','Logicien','Fin stratège','Esprit vif','Virtuose','Génie','Grand architecte'],
    strategy: ['Recrue','Tacticien','Stratège','Général','Maréchal','Conquérant','Empereur','Légende de la conquête'],
  };
  const MATCH = [
    [/factorio/i,'factorio'],[/satisfactory/i,'satisfactory'],[/final fantasy/i,'finalfantasy'],[/spider-?man/i,'spiderman'],
    [/megabonk/i,'megabonk'],[/rocket league/i,'rocketleague'],[/elden ring|dark souls|sekiro|lies of p|bloodborne|lords of the fallen/i,'souls'],
    [/stardew/i,'stardew'],[/cyberpunk/i,'cyberpunk'],[/elder scrolls|skyrim|oblivion|morrowind/i,'elderscrolls'],[/diablo/i,'diablo'],
    [/idle|clicker|incremental/i,'idle'],[/racing|rally|forza|kart|drive|motorsport|need for speed|f1|dirt|gran turismo|trackmania|crew|road rash/i,'racing'],
    [/call of duty|battlefield|counter-?strike|halo|doom|wolfenstein|war|warfare|sniper|squad|rainbow six|valorant|apex|titanfall|gears/i,'war'],
    [/resident evil|silent hill|outlast|horror|dead space|phasmophobia|alan wake|amnesia|evil within|lethal/i,'horror'],
    [/farm|harvest|ranch|garden/i,'farm'],[/tycoon|manager|simulator|cities|planet coaster|two point|anno|business/i,'business'],
    [/space|star|galax|elite dangerous|mass effect|no man|stellar|orbit|cosmo|astro/i,'space'],
    [/craft|build|factory|minecraft|terraria|valheim|raft|subnautica|forest|survival|ark|rust|grounded/i,'builder'],
    [/fc|fifa|football|nba|nhl|madden|pes|golf|tennis|basket|soccer|sport/i,'sport'],
    [/civilization|total war|age of|crusader|stellaris|europa|hearts of iron|xcom|strategy|tactics|commander|king/i,'strategy'],
    [/puzzle|portal|talos|witness|tetris|baba|zachtronics|logic/i,'puzzle'],
    [/survivor|rogue|arcade|bonk|vampire|hades|dead cells|binding|balatro|blocks|tycoon|pinball|retro|paradise/i,'arcade'],
    [/dragon|ring|souls|witcher|quest|legend|kingdom|knight|sword|baldur|divinity|fable|tale|mage|plague|order|chronicles|fantasy|hero/i,'fantasy'],
  ];
  function ladder(game) {
    const title = String(game?.title || '');
    for (const [pattern, key] of MATCH) if (pattern.test(title)) return L[key];
    if (!title) return tiers.map(([, name]) => name);
    const neutral = [tiers.map(([, name]) => name), L.arcade, L.fantasy, L.puzzle];
    let hash = 0; for (const c of String(game?.id || title)) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
    return neutral[hash % neutral.length];
  }
  function rank(seconds, game) {
    const total = Number.isFinite(Number(seconds)) ? Math.max(0, Number(seconds)) : 0;
    const hours = total / 3600;
    let index = 0;
    tiers.forEach(([start], i) => { if (hours >= start) index = i; });
    const names = game ? ladder(game) : tiers.map(([, n]) => n);
    const [start] = tiers[index], next = tiers[index + 1], name = names[index];
    return { index, name, start, next: next?.[0] ?? null, nextName: next ? names[index + 1] : null,
      hours, progress: next ? Math.min(1, (hours - start) / (next[0] - start)) : 1 };
  }
  function installed(games) {
    const seen = new Set();
    return games.filter(g => g.installed === true && g.platform !== 'cloud' && g.id && !seen.has(g.id) && seen.add(g.id))
      .slice().sort((a, b) => a.title.localeCompare(b.title, 'fr', { numeric: true }) || a.id.localeCompare(b.id));
  }
  function selection(games, id, oldIndex = 0) {
    const index = games.findIndex(g => g.id === id);
    return games.length ? (index < 0 ? Math.min(Math.max(0, oldIndex), games.length - 1) : index) : -1;
  }
  function delta(index, selected, count) {
    let distance = index - selected;
    if (distance > count / 2) distance -= count;
    if (distance < -count / 2) distance += count;
    return distance;
  }
  function create(api) {
    const { el, send, getState, artFor, portraitSources, openGame, storeName } = api;
    let big = null, games = [], selectedID = null, selectedIndex = 0, signature = '', previousFocus = null;
    let backgroundToken = 0, backgroundURL = '', backgroundLayer = 0, refreshTimer = 0;
    let drag = null, suppressClickUntil = 0, section = 'installed', sectionSignature = '';
    const controls = {};
    const button = (name, action, cls = '') => {
      const node = el('button', cls, name); node.type = 'button'; node.addEventListener('click', action); return node;
    };
    const safeImage = value => typeof value === 'string' && (/^https:\/\//.test(value) || /^metalmaxart:\/\/steam\/\d+(\/portrait)?$/.test(value)) ? value : '';
    function sourcesImage(sources, alt = '') {
      const image = el('img'); image.alt = alt; image.decoding = 'async'; image.draggable = false;
      return root.PlaymeltArtwork.bind(image,sources.map(safeImage).filter(Boolean),{eager:true});
    }
    function rankBadge(game, compact = false) {
      const r = rank(game.playtime, game);
      const badge = button('', () => showRanks(game), 'rank-badge tier-' + r.index + (compact ? ' compact' : ''));
      badge.setAttribute('aria-label', `${r.name} · ${game.title} · voir les rangs`);
      badge.append(el('span', 'rank-emblem', ['I','II','III','IV','V','VI','VII','VIII'][r.index]), el('span', '', r.name));
      badge.title = r.next === null ? 'Rang ultime · 1 000 h et plus' : `${r.start}–${r.next} h · prochain rang : ${r.nextName}`;
      return badge;
    }
    let ranks = null;
    function showRanks(game) {
      ranks?.remove(); ranks = el('dialog', 'rank-dialog');
      const r = rank(game.playtime, game), header = el('header'), names = ladder(game);
      header.append(el('div', '', game.title), button('Fermer', () => ranks.close(), 'experience-close'));
      ranks.append(header, el('h2', '', r.name), el('p', 'rank-subtitle', game.playtimeFormatted || `${Math.floor(r.hours)} h de jeu`));
      const progress = el('progress'); progress.max = 1; progress.value = r.progress;
      progress.setAttribute('aria-label', 'Progression vers le prochain rang'); ranks.append(progress);
      ranks.append(el('p', 'rank-subtitle', r.next === null ? 'Tous les paliers franchis.' : `${(Math.ceil((r.next - r.hours) * 10) / 10).toLocaleString('fr-FR')} h avant ${r.nextName}`));
      const list = el('ol', 'rank-ladder');
      tiers.forEach(([start], i) => {
        const name = names[i];
        const row = el('li', (i === r.index ? 'current ' : '') + (i <= r.index ? 'reached' : ''));
        row.append(el('span', 'rank-emblem tier-' + i, ['I','II','III','IV','V','VI','VII','VIII'][i]), el('b', '', name), el('span', '', `${start.toLocaleString('fr-FR')} h · +${rewards[i].toLocaleString('fr-FR')} pts`));
        if (i === r.index) row.setAttribute('aria-current', 'step'); list.append(row);
      });
      ranks.append(list, el('p', 'rank-footnote', 'Les points des paliers atteints se cumulent dans ton profil Playmelt.'));
      document.body.append(ranks); ranks.addEventListener('close', () => { ranks?.remove(); ranks = null; }); ranks.showModal();
    }
    /* Big Picture Playmelt : scène sombre, art du jeu dans la courbe du P, rubans orange,
       rail d'affiches. Toutes les animations restent décoratives et respectent reduced-motion. */
    const SVG = 'http://www.w3.org/2000/svg';
    let clockTimer = 0, lastDistances = new Map(), lastSelectedID = null, entering = 0;
    function glyph(id, cls = '') {
      const svg = document.createElementNS(SVG, 'svg'); svg.setAttribute('aria-hidden', 'true'); if (cls) svg.setAttribute('class', cls);
      const use = document.createElementNS(SVG, 'use'); use.setAttribute('href', '#' + id); svg.append(use); return svg;
    }
    function playIcon() {
      const svg = document.createElementNS(SVG, 'svg'); svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
      const path = document.createElementNS(SVG, 'path'); path.setAttribute('d', 'M8 5.6v12.8c0 .9 1 1.5 1.8 1l10-6.4c.7-.5.7-1.5 0-2l-10-6.4C9 4.1 8 4.7 8 5.6z'); path.setAttribute('fill', 'currentColor');
      svg.append(path); return svg;
    }
    function restart(node, cls) { if (!node) return; node.classList.remove(cls); void node.offsetWidth; node.classList.add(cls); }
    function setHints(list) {
      controls.hints.replaceChildren(...list.map(([keys, label]) => {
        const item = el('span', 'bp-hint'); keys.forEach(k => item.append(el('kbd', '', k))); item.append(el('span', '', label)); return item;
      }));
    }
    function tick() { if (controls.clock) controls.clock.textContent = new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }); }
    function placeTab() {
      const active = controls.nav?.querySelector('button.active'); if (!active) return;
      controls.nav.style.setProperty('--tab-x', active.offsetLeft + 'px'); controls.nav.style.setProperty('--tab-w', active.offsetWidth + 'px');
    }
    function setBackground(game, direction = 0) {
      const art = artFor(game) || {};
      const candidates = [...new Set([art.hero, art.header, game.imageURL, game.portraitImageURL].map(safeImage).filter(Boolean))];
      const key = game.id + ':' + candidates.join('|');
      if (backgroundURL === key) return;
      backgroundURL = key; const token = ++backgroundToken;
      const image = new Image(); image.decoding = 'async';
      const next = () => { if (token !== backgroundToken || !big?.open) return; if (candidates.length) image.src = candidates.shift(); };
      image.onerror = next;
      image.onload = () => {
        if (token !== backgroundToken || !big?.open) return;
        const layer = 1 - backgroundLayer, incoming = controls.backgrounds[layer], outgoing = controls.backgrounds[backgroundLayer];
        incoming.src = image.src; controls.ambient.src = image.src;
        incoming.dataset.dir = direction < 0 ? 'prev' : 'next';
        incoming.classList.remove('visible', 'leaving'); void incoming.offsetWidth; incoming.classList.add('visible');
        outgoing.classList.remove('visible'); outgoing.classList.add('leaving');
        controls.ambient.classList.add('visible');
        backgroundLayer = layer;
      };
      next();
    }
    function clearBackground() {
      ++backgroundToken; backgroundURL = '';
      controls.backgrounds.forEach(img => img.classList.remove('visible', 'leaving')); controls.ambient?.classList.remove('visible');
    }
    function paint() {
      if (!big?.open || section !== 'installed') return;
      const game = games[selectedIndex], count = games.length;
      controls.empty.hidden = !!game; controls.stage.hidden = !game; big.classList.toggle('bp-has-game', !!game);
      controls.previous.disabled = controls.next.disabled = count < 2;
      controls.total.textContent = `${count} jeu${count > 1 ? 'x' : ''} installé${count > 1 ? 's' : ''}`;
      if (!game) { clearBackground(); return; }
      const previousIndex = games.findIndex(g => g.id === lastSelectedID);
      const direction = previousIndex < 0 ? 0 : Math.sign(delta(selectedIndex, previousIndex, count)) || 0;
      const changed = lastSelectedID !== game.id; lastSelectedID = selectedID = game.id;
      setBackground(game, direction);
      const railWidth = controls.rail.clientWidth || window.innerWidth * .9;
      const cardWidth = Math.round(Math.min(210, Math.max(118, window.innerHeight * .165)));
      const small = .72, gap = Math.round(cardWidth * .13), pitch = cardWidth * small + gap;
      big.style.setProperty('--bp-card', cardWidth + 'px');
      [...controls.cards.children].forEach((card, i) => {
        const distance = delta(i, selectedIndex, count);
        const x = distance === 0 ? 0 : distance > 0 ? cardWidth + gap * 1.7 + (distance - 1) * pitch : distance * pitch - gap * .7;
        const visible = distance >= -1 && x < railWidth + pitch;
        const before = lastDistances.get(card); lastDistances.set(card, distance);
        if (before !== undefined && Math.abs(before - distance) > 2) { card.classList.add('bp-jump'); requestAnimationFrame(() => requestAnimationFrame(() => card.classList.remove('bp-jump'))); }
        card.style.width = cardWidth + 'px';
        card.style.transform = `translate3d(${Math.round(x)}px,0,0) scale(${distance === 0 ? 1 : small})`;
        card.style.opacity = !visible ? '0' : distance === 0 ? '1' : distance < 0 ? '.22' : String(Math.max(.3, .86 - distance * .08));
        card.style.visibility = visible ? 'visible' : 'hidden';
        card.style.zIndex = String(50 - Math.abs(distance));
        card.classList.toggle('selected', distance === 0);
        card.setAttribute('aria-selected', String(distance === 0)); card.tabIndex = distance === 0 ? 0 : -1;
        if (visible && !card.firstChild) card.append(sourcesImage(portraitSources(games[i]), ''), el('span', 'bp-card-title', games[i].title));
      });
      const store = game.store || 'steam', logo = document.getElementById('pf-' + store) ? glyph('pf-' + store) : null;
      controls.platform.replaceChildren(...(logo ? [logo] : []), el('span', '', storeName(store)));
      controls.platform.className = 'bp-platform store-' + store;
      controls.index.replaceChildren(el('b', '', String(selectedIndex + 1).padStart(2, '0')), el('span', '', '/' + String(count).padStart(2, '0')));
      controls.title.textContent = game.title;
      big.classList.toggle('bp-long-title', game.title.length > 26);
      const hours = Number(game.playtime) > 0 ? (game.playtimeFormatted || `${Math.floor(game.playtime / 3600)} h`) : '';
      controls.meta.replaceChildren(el('span', '', hours ? hours + ' de jeu' : 'Jamais lancé'), ...(game.platform === 'mac' ? [el('span', '', 'Natif Mac')] : []));
      controls.rank.replaceChildren(rankBadge(game));
      const locked = getState().renderProtectionEnabled === true;
      controls.play.disabled = !game.canLaunch || locked;
      controls.issue.textContent = locked ? 'Lancements suspendus pendant les rendus.' : game.launchBlockReason || (!game.canLaunch ? 'Installation ou moteur à vérifier dans la fiche du jeu.' : '');
      controls.progress.style.setProperty('--p', String((selectedIndex + 1) / count));
      controls.counter.textContent = `${String(selectedIndex + 1).padStart(2, '0')} — ${String(count).padStart(2, '0')}`;
      if (changed) { restart(controls.copy, 'bp-in'); restart(controls.window, 'bp-pulse'); }
    }
    function sync() {
      if (!big?.open) return;
      if (section !== 'installed') {
        const next = JSON.stringify([section,getState().games?.length,getState().profile?.points,api.getFeed?.()?.fetchedAt]);
        if (next !== sectionSignature) { sectionSignature = next; renderSection(); }
        return;
      }
      games = installed(getState().games || []);
      selectedIndex = selection(games, selectedID, selectedIndex);
      const nextSignature = JSON.stringify(games.map(g => [g.id, g.title, g.imageURL, g.portraitImageURL]));
      if (signature !== nextSignature) {
        signature = nextSignature; lastDistances = new Map();
        controls.cards.replaceChildren();
        games.forEach((game, index) => {
          const card = button('', () => { if (Date.now() < suppressClickUntil) return; if (index !== selectedIndex) { selectedIndex = index; paint(); } }, 'bp-card');
          card.setAttribute('role', 'option'); card.setAttribute('aria-label', game.title);
          controls.cards.append(card);
        });
      }
      paint();
    }
    function move(amount) {
      if (section !== 'installed' || games.length < 2) return;
      selectedIndex = (selectedIndex + amount + games.length) % games.length; paint();
      controls.cards.querySelector('[aria-selected="true"]')?.focus({ preventScroll: true });
    }
    function play() {
      if (section !== 'installed') return;
      const game = games[selectedIndex];
      if (game?.canLaunch && !controls.play.disabled) { restart(controls.play, 'bp-launch'); send('launchGame', { gameId: game.id }); }
    }
    function close() { if (big?.open) big.close(); }
    function stop() {
      ++backgroundToken; clearInterval(refreshTimer); refreshTimer = 0; clearInterval(clockTimer); clockTimer = 0; clearTimeout(entering);
      window.removeEventListener('resize', resize); document.removeEventListener('visibilitychange', visibility);
      send('setBigPicture', { enabled: false });
      big?.remove(); big = null; signature = ''; backgroundURL = ''; lastSelectedID = null; lastDistances = new Map(); previousFocus?.focus?.();
    }
    function resize() { paint(); placeTab(); }
    function visibility() { if (!document.hidden && big?.open) send('refresh'); }
    function switchSection(key) {
      if (key === section) return;
      section = key; sectionSignature = ''; restart(big, 'bp-switch'); renderSection();
    }
    function renderSection(platform) {
      big.dataset.section = section;
      if (section === 'news') {
        const item = api.getFeed?.()?.items?.[0], game = (getState().games||[]).find(g=>g.id===item?.gameId);
        if (game) setBackground(game);
      } else if (section === 'profile' || section === 'platforms') clearBackground();
      controls.nav.querySelectorAll('button').forEach(b => { const active = b.dataset.section === section; b.classList.toggle('active',active); b.setAttribute('aria-selected',String(active)); });
      placeTab();
      controls.stage.hidden = section !== 'installed'; controls.empty.hidden = true; controls.section.hidden = section === 'installed';
      controls.total.textContent = section === 'installed' ? `${games.length} jeux installés` : `${(getState().games||[]).length.toLocaleString('fr-FR')} jeux`;
      setHints(section === 'installed'
        ? [[['←','→'],'Parcourir'],[['↵'],'Jouer'],[['Q','E'],'Sections'],[['Échap'],'Quitter']]
        : [[['Tab'],'Parcourir'],[['↵'],'Ouvrir'],[['Q','E'],'Sections'],[['Échap'],'Quitter']]);
      controls.section.replaceChildren();
      const discover = api.discover?.();
      if (section === 'installed') { lastSelectedID = null; sync(); }
      else if (section === 'library') discover?.renderLibrary(controls.section,platform);
      else if (section === 'news') discover?.renderNews(controls.section);
      else if (section === 'offers') discover?.renderOffers(controls.section);
      else if (section === 'profile') discover?.renderProfile(controls.section);
      else if (section === 'platforms') discover?.renderPlatforms(controls.section,store=>{section='library';restart(big,'bp-switch');renderSection(store);});
    }
    const SECTIONS = [['installed','Installés'],['library','Bibliothèque'],['news','Actus'],['offers','Offres'],['platforms','Plateformes'],['profile','Profil']];
    function open() {
      if (big?.open) return;
      previousFocus = document.activeElement;
      big = el('dialog', 'big-picture bp bp-opening'); big.setAttribute('aria-label', 'Big Picture · jeux installés');
      controls.ambient = el('img', 'bp-ambient'); controls.ambient.alt = '';
      controls.window = el('div', 'bp-window'); const frame = el('div', 'bp-frame');
      controls.backgrounds = [el('img', 'big-background'), el('img', 'big-background')];
      controls.backgrounds.forEach(img => { img.alt = ''; frame.append(img); });
      controls.window.append(frame, el('div', 'bp-window-shade'));
      const sweep = el('div', 'bp-sweep'); sweep.append(el('i', 'bp-sweep-orange'), el('i', 'bp-sweep-ink'));
      big.append(controls.ambient, el('div', 'big-shade'), controls.window, el('div', 'bp-ribbon'), el('div', 'bp-grain'), sweep);
      const shell = el('div', 'big-shell'), header = el('header', 'big-header'), brand = el('div', 'big-brand');
      brand.append(el('i', 'bp-mark'), el('i', 'bp-word'), el('span', 'bp-tag', 'Big Picture'));
      controls.nav = el('nav','big-nav'); controls.nav.setAttribute('aria-label','Sections Big Picture'); controls.nav.setAttribute('role','tablist');
      for (const [key,label] of SECTIONS) {
        const tab = button(label,()=>switchSection(key));tab.dataset.section=key;tab.setAttribute('role','tab');controls.nav.append(tab);
      }
      controls.nav.append(el('i', 'bp-tab-ribbon'));
      const status = el('div', 'bp-status'); controls.total = el('span', 'big-total'); controls.clock = el('time', 'bp-clock');
      const quit = button('', close, 'experience-close bp-quit'); quit.append(el('kbd', '', 'Échap'), el('span', '', 'Quitter')); quit.setAttribute('aria-label', 'Quitter Big Picture');
      status.append(controls.total, controls.clock, quit);
      header.append(brand, controls.nav, status); shell.append(header);

      controls.stage = el('section', 'bp-stage'); controls.stage.setAttribute('aria-label', 'Jeux installés');
      controls.info = el('div', 'big-info'); controls.copy = el('div', 'big-copy');
      controls.index = el('div', 'bp-index'); controls.platform = el('div', 'bp-platform');
      controls.title = el('h1'); controls.meta = el('p', 'bp-meta'); controls.rank = el('div', 'bp-rank'); controls.issue = el('p', 'big-issue');
      const actions = el('div', 'big-actions'); controls.play = button('', play, 'big-play'); controls.play.append(playIcon(), el('span', '', 'Jouer'));
      actions.append(controls.play, button('Fiche du jeu', () => { const game = games[selectedIndex]; close(); if (game) openGame(game); }, 'big-details'));
      controls.copy.append(controls.platform, controls.title, controls.meta, controls.rank, actions, controls.issue);
      controls.info.append(controls.index, controls.copy);
      controls.rail = el('div', 'bp-rail'); controls.cards = el('div', 'bp-cards'); controls.cards.setAttribute('role', 'listbox'); controls.cards.setAttribute('aria-label', 'Jeu sélectionné');
      controls.rail.append(controls.cards);
      const foot = el('div', 'bp-rail-foot'); controls.progress = el('div', 'bp-progress'); controls.progress.append(el('i'));
      controls.previous = button('', () => move(-1), 'bp-arrow'); controls.previous.append(el('span', '', '‹')); controls.previous.setAttribute('aria-label', 'Jeu précédent');
      controls.next = button('', () => move(1), 'bp-arrow'); controls.next.append(el('span', '', '›')); controls.next.setAttribute('aria-label', 'Jeu suivant');
      controls.counter = el('span', 'bp-counter'); foot.append(controls.previous, controls.counter, controls.next, controls.progress);
      controls.stage.append(controls.info, controls.rail, foot); shell.append(controls.stage);

      controls.empty = el('div', 'big-empty'); controls.empty.append(el('i', 'bp-mark bp-mark-xl'), el('h2', '', 'Ta collection commence ici.'), el('p', '', 'Installe un jeu pour le retrouver dans Big Picture.'), button('Ouvrir la bibliothèque', () => { close(); api.goLibrary?.(); }, 'big-play')); shell.append(controls.empty);
      controls.section=el('section','big-section');controls.section.hidden=true;shell.append(controls.section);
      controls.hints=el('footer', 'big-hints');shell.append(controls.hints);
      big.append(shell); document.body.append(big); big.addEventListener('close', stop, { once: true });
      big.addEventListener('keydown', e => {
        if (ranks?.open || e.altKey || e.metaKey || e.ctrlKey) return;
        const typing = e.target.closest?.('input,select,textarea');
        if (!typing && (e.key === 'q' || e.key === 'Q' || e.key === 'e' || e.key === 'E')) {
          const index = SECTIONS.findIndex(([key]) => key === section), step = /q/i.test(e.key) ? -1 : 1;
          e.preventDefault(); switchSection(SECTIONS[(index + step + SECTIONS.length) % SECTIONS.length][0]); controls.nav.querySelector('button.active')?.focus({ preventScroll: true }); return;
        }
        if (section !== 'installed' || typing) return;
        if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); move(e.key === 'ArrowLeft' ? -1 : 1); }
        if (e.key === 'Enter' && (e.target === big || e.target.closest('.bp-cards'))) { e.preventDefault(); play(); }
      });
      controls.rail.addEventListener('pointerdown', e => { drag = { x: e.clientX, pointer: e.pointerId }; });
      controls.rail.addEventListener('pointerup', e => { if (drag?.pointer === e.pointerId && Math.abs(e.clientX - drag.x) > 45) { e.preventDefault(); suppressClickUntil = Date.now() + 400; move(e.clientX < drag.x ? 1 : -1); } drag = null; });
      controls.rail.addEventListener('pointercancel', () => { drag = null; });
      controls.rail.addEventListener('pointermove', e => {
        const card = e.target.closest?.('.bp-card.selected'); if (!card) return;
        const box = card.getBoundingClientRect();
        card.style.setProperty('--tilt-x', ((e.clientY - box.top) / box.height - .5).toFixed(3));
        card.style.setProperty('--tilt-y', ((e.clientX - box.left) / box.width - .5).toFixed(3));
      });
      controls.rail.addEventListener('pointerleave', () => controls.cards.querySelectorAll('.bp-card').forEach(c => { c.style.removeProperty('--tilt-x'); c.style.removeProperty('--tilt-y'); }));
      let wheelAt = 0;
      controls.stage.addEventListener('wheel', e => { e.preventDefault(); const amount = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY; if (Math.abs(amount) > 8 && Date.now() - wheelAt > 200) { move(amount > 0 ? 1 : -1); wheelAt = Date.now(); } }, { passive: false });
      big.showModal(); tick(); renderSection(); controls.cards.querySelector('[aria-selected="true"]')?.focus({ preventScroll: true });
      entering = setTimeout(() => big?.classList.remove('bp-opening'), 1600);
      window.addEventListener('resize', resize); document.addEventListener('visibilitychange', visibility);
      send('setBigPicture', { enabled: true }); send('refresh');
      refreshTimer = setInterval(() => { if (!document.hidden) send('refresh'); }, 15000);
      clockTimer = setInterval(tick, 10000);
    }
    window.addEventListener('pagehide', () => { clearInterval(refreshTimer); clearInterval(clockTimer); });
    return { open, close, sync, rankBadge, showRanks, rank, setBackground };
  }
  const exported = { create, rank, ladder, tiers, rewards, installed, selection, delta };
  if (typeof module !== 'undefined' && module.exports) module.exports = exported;
  else root.PlaymeltExperience = exported;
})(typeof window === 'undefined' ? {} : window);
