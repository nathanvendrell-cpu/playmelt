(function(root){
  'use strict';
  const stores={steam:'Steam',epic:'Epic Games',gog:'GOG',xbox:'Xbox'};
  function offers(feed,now=Date.now()/1000){
    const sales=(feed?.offers||[]).filter(x=>!x.end||x.end>now);
    const free=(feed?.freeGames||[]).filter(x=>x.current===true&&x.start<=now&&x.end>now).map(x=>({...x,id:'epic:'+(x.id||x.url),store:'epic',kind:'giveaway',priceCents:0,currency:'EUR'}));
    const seen=new Set();return [...free,...sales].filter(x=>x.id&&!seen.has(x.id)&&seen.add(x.id));
  }
  function create(api){
    const {el,getState,getFeed,openLink,openGame,artFor,rank}=api;
    let offerStore='all',offerKind='all',profileLimit=24,profileQuery='',libraryStore='all',libraryQuery='',libraryLimit=48,newsLimit=18;
    const btn=(text,action,cls='')=>{const b=el('button',cls,text);b.type='button';b.addEventListener('click',action);return b;};
    const glyph=store=>{const g=el('span','pf-glyph-wrap');g.innerHTML='<svg class="pf-glyph" aria-hidden="true"><use href="#pf-'+store+'"/></svg>';return g;};
    const brandChip=(store,cls)=>{const c=el('span',cls+' store-'+store);c.append(glyph(store),el('span','',stores[store]||store));return c;};
    const image=(url,cls='',alt='')=>{const i=el('img',cls);i.alt=alt;return root.PlaymeltArtwork.bind(i,url);};
    const money=cents=>new Intl.NumberFormat('fr-FR',{style:'currency',currency:'EUR'}).format(cents/100);
    const depth=node=>{if(window.matchMedia('(prefers-reduced-motion: reduce)').matches)return node;node.addEventListener('pointermove',e=>{const r=node.getBoundingClientRect();node.style.setProperty('--rx',((.5-(e.clientY-r.top)/r.height)*5)+'deg');node.style.setProperty('--ry',(((e.clientX-r.left)/r.width-.5)*9)+'deg');});node.addEventListener('pointerleave',()=>{node.style.setProperty('--rx','0deg');node.style.setProperty('--ry','0deg');});return node;};
    const date=seconds=>new Date(seconds*1000).toLocaleDateString('fr-FR',{day:'numeric',month:'short'});
    const art=game=>artFor(game)||{};
    function price(item){const p=el('div','offer-price');if(item.originalCents>item.priceCents)p.append(el('s','',money(item.originalCents)));p.append(el('strong','',item.priceCents===0?'Offert':money(item.priceCents)));return p;}
    function offerCard(item,hero=false){
      const card=btn('',()=>openLink(item.url),'offer-card'+(hero?' offer-hero':''));
      card.append(image(item.image,'offer-art',item.title));
      const badge=el('span','offer-badge'+(item.kind==='upcoming'?' is-soon':''),item.kind==='giveaway'?'À récupérer':item.kind==='upcoming'?'Semaine prochaine':`−${item.discount} %`);card.append(badge);
      const copy=el('div','offer-copy'),platform=brandChip(item.store,'offer-platform-brand');copy.append(platform,el(hero?'h2':'h3','',item.title));
      const bottom=el('div','offer-bottom');bottom.append(price(item),el('span','offer-arrow','↗'));copy.append(bottom);
      if(item.kind==='upcoming'&&item.start)copy.append(el('small','offer-deadline',`Offert dès le ${date(item.start)}`));else if(item.end)copy.append(el('small','offer-deadline',`Jusqu’au ${date(item.end)}`));
      if(item.store==='xbox')copy.append(el('small','offer-platform',item.platforms?.includes('PC')?'PC · Xbox':'Xbox · voir les appareils compatibles'));
      card.append(copy);return depth(card);
    }
    function renderOffers(pane){
      pane.replaceChildren();pane.classList.add('discover');const feed=getFeed(),all=offers(feed);
      const toolbar=el('div','discover-filters');
      for(const [key,label]of Object.entries({all:'Toutes les plateformes',...stores}))toolbar.append(btn(label,()=>{offerStore=key;renderOffers(pane);},offerStore===key?'active':''));
      pane.append(toolbar);
      const types=el('div','discover-types');for(const [key,label]of [['all','Tout'],['giveaway','Jeux offerts'],['sale','Promotions']])types.append(btn(label,()=>{offerKind=key;renderOffers(pane);},offerKind===key?'active':''));pane.append(types);
      const items=all.filter(x=>(offerStore==='all'||x.store===offerStore)&&(offerKind==='all'||x.kind===offerKind));
      const featured=items.filter(x=>x.kind==='giveaway').slice(0,2);if(featured.length<2&&offerKind!=='giveaway')featured.push(...items.filter(x=>x.kind==='sale').slice(0,2-featured.length));
      if(featured.length){const hero=el('div','offers-spotlight');featured.forEach(x=>hero.append(offerCard(x,true)));pane.append(hero);}
      const remaining=items.filter(x=>!featured.includes(x));
      if(remaining.length){pane.append(el('h2','discover-heading',offerKind==='giveaway'?'À ajouter à ta collection':'Les promotions du moment'));const grid=el('div','offers-grid');remaining.forEach(x=>grid.append(offerCard(x)));pane.append(grid);}
      if(!items.length)pane.append(el('p','discover-empty',feed?'Aucune offre disponible dans ce filtre pour le moment.':'Chargement des offres…'));
      const links=el('div','store-links');
      const urls={steam:'https://store.steampowered.com/specials/',epic:'https://store.epicgames.com/fr/sales-and-specials',gog:'https://www.gog.com/fr/games/discounted',xbox:'https://www.xbox.com/fr-FR/games/browse/game-deals'};
      for(const [key,label]of Object.entries(stores))if(offerStore==='all'||offerStore===key){const b=btn('',()=>openLink(urls[key]),'store-link store-'+key);b.append(el('b','',label),el('span','',key==='epic'?'Toutes les promotions Epic →':'Toute la sélection →'));links.append(b);}pane.append(links);
      const unavailable=Object.entries(feed?.offerSources||{}).filter(([,status])=>status==='unavailable').map(([key])=>stores[key]);
      if(unavailable.length)pane.append(el('p','discover-note',`Flux momentanément indisponible : ${unavailable.join(', ')}. Les boutiques restent consultables ci-dessus.`));
      if(feed?.fetchedAt)pane.append(el('p','discover-note',`Prix publics en euros · relevés le ${date(feed.fetchedAt)} à ${new Date(feed.fetchedAt*1000).toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'})} · prix confirmé par la boutique avant achat.`));
    }
    function newsCard(item,hero=false,options={}){
      const game=(getState().games||[]).find(g=>g.id===item.gameId),a=(options.art&&(options.art.hero||options.art.header)?options.art:null)||getFeed()?.art?.[item.gameId]||(game?art(game):{})||{};
      const card=btn('',()=>openLink(item.url),'game-journal-row news-band game-news-band'+(hero?' news-band-lead':'')+(options.context?' news-band-context':''));card.title=item.title;
      card.append(image([a.hero,a.header,game?.imageURL,game?.portraitImageURL],'nb-bg'),image([a.header,game?.imageURL,a.hero,game?.portraitImageURL],'nb-cap',item.gameTitle||game?.title||''));
      const copy=el('div','game-journal-copy'),meta=el('div','game-news-meta');meta.append(el('span',item.kind==='update'?'tag upd':'tag news',item.kind==='update'?'Correctif':'Annonce'));
      if(!options.context)meta.append(el('span','',item.gameTitle||game?.title||''),el('span','game-news-platform',stores[item.store||game?.store]||''));
      meta.append(el('time','',(api.labelDate||date)(item.date)));copy.append(meta,el(options.context?'h5':'h3','',item.title));
      if(item.summary)copy.append(el('p','',item.summary));card.append(copy,el('span','game-journal-arrow','↗'));return depth(card);
    }
    function renderNews(pane,kind='all',scope=null){
      pane.classList.add('discover');const items=(getFeed()?.items||[]).filter(x=>(kind==='all'||x.kind===kind)&&(!scope||scope(x)));
      if(!items.length){pane.append(el('p','discover-empty',getFeed()?'Rien de neuf pour l’instant.':'Chargement des actualités…'));return;}
      const list=el('div','news-band-list');items.slice(0,newsLimit).forEach((x,i)=>list.append(newsCard(x,i===0)));pane.append(list);
      if(items.length>newsLimit){const more=btn('Afficher plus d’actualités',()=>{newsLimit+=18;list.replaceChildren(...items.slice(0,newsLimit).map((x,i)=>newsCard(x,i===0)));if(items.length<=newsLimit)more.hidden=true;},'discover-more');pane.append(more);}
    }
    function playerAvatar(player,cls=''){
      const node=el('div','player-avatar '+cls);
      if(/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(player.photo||'')){const photo=el('img');photo.src=player.photo;photo.alt='Ton avatar';node.append(photo);}
      else {const game=[...(getState().games||[])].sort((a,b)=>Number(b.installed)-Number(a.installed)||Number(b.playtime)-Number(a.playtime)).find(g=>g.portraitImageURL||g.imageURL);if(game)node.append(image([game.portraitImageURL,game.imageURL],'','Avatar de '+game.title));else node.append(el('span','player-initials',(player.name||'P').slice(0,2).toUpperCase()));}
      return node;
    }
    function editPlayer(){
      if(document.getElementById('player-editor'))return;
      const state=getState(),player=state.player||{},dialog=el('dialog','player-editor');dialog.id='player-editor';dialog.setAttribute('aria-label','Personnaliser mon profil');
      const form=el('form'),head=el('div','player-editor-head');head.append(el('h2','','Ton identité de joueur'),btn('Fermer',()=>dialog.close(),'player-close'));form.append(head);
      const identity=el('div','player-editor-identity'),preview=playerAvatar(player),label=el('label','','Pseudo'),input=el('input');input.type='text';input.name='nickname';input.maxLength=40;input.value=player.name||'';input.placeholder='Ton pseudo';label.append(input);identity.append(preview,label);form.append(identity);
      let style='portrait',selected=null,query='',limit=12;
      const tabs=el('div','avatar-tabs');for(const [key,title]of [['portrait','Affiches'],['scene','Scènes'],['logo','Logos']]){const b=btn(title,()=>{style=key;selected=null;limit=12;for(const node of tabs.children)node.classList.toggle('on',node===b);draw();},key===style?'on':'');tabs.append(b);}form.append(tabs);
      const search=el('input','avatar-search');search.type='search';search.placeholder='Chercher un jeu de ma bibliothèque';search.setAttribute('aria-label','Rechercher un avatar');search.addEventListener('input',()=>{query=search.value;limit=12;draw();});form.append(search);
      const gallery=el('div','avatar-gallery'),more=btn('Afficher plus',()=>{limit+=12;draw();},'avatar-more');form.append(gallery,more);
      function draw(){gallery.replaceChildren();const games=[...(state.games||[])].filter(g=>g.title.toLocaleLowerCase('fr').includes(query.toLocaleLowerCase('fr'))).sort((a,b)=>Number(b.installed)-Number(a.installed)||Number(b.playtime)-Number(a.playtime)).filter(g=>style==='logo'?!!art(g).logo:!!(g.portraitImageURL||g.imageURL||art(g).hero));
        for(const game of games.slice(0,limit)){const a=art(game),urls=style==='logo'?[a.logo]:style==='scene'?[a.hero,a.header,game.imageURL]:[game.portraitImageURL,game.imageURL,a.header];const choice=btn('',()=>{selected={gameId:game.id,style};preview.replaceChildren(image(urls,'avatar-preview-'+style,game.title));for(const node of gallery.children)node.classList.toggle('selected',node===choice);},'avatar-choice avatar-choice-'+style+(selected?.gameId===game.id?' selected':''));choice.setAttribute('aria-label','Choisir '+game.title);choice.append(image(urls,'',game.title),el('span','',game.title));gallery.append(choice);}more.hidden=games.length<=limit;if(!games.length)gallery.append(el('p','discover-note','Aucun visuel disponible pour cette recherche.'));}
      draw();
      const actions=el('div','player-editor-actions');actions.append(btn('Importer ma photo',()=>{dialog.close();api.send('choosePlayerPhoto');},'button'));const save=el('button','button primary','Enregistrer');save.type='submit';actions.append(save);form.append(actions);
      form.addEventListener('submit',e=>{e.preventDefault();const name=input.value.trim();if(selected){dialog.close();api.send('chooseGameAvatar',{...selected,...(name?{name}:{})});}else if(name){dialog.close();api.send('savePlayerProfile',{name});}else input.focus();});dialog.append(form);dialog.addEventListener('close',()=>dialog.remove());document.body.append(dialog);dialog.showModal();
    }
    function renderProfile(pane){
      pane.replaceChildren();pane.classList.add('discover');const state=getState(),player=state.player||{},p=state.profile||{points:0,level:1,name:'Nouveau venu',entries:[],levels:[]};
      const hero=el('section','profile-hero player-hero'),scenery=el('div','player-scenery');for(const entry of p.entries.slice(0,3)){const g=state.games.find(x=>x.id===entry.gameId);scenery.append(image([g?.portraitImageURL,entry.image],'',entry.title));}hero.append(scenery);
      const identity=btn('',editPlayer,'player-identity');identity.setAttribute('aria-label','Changer mon avatar');identity.append(playerAvatar(player),el('small','','Modifier'));
      const copy=el('div','profile-copy');copy.append(el('span','discover-kicker',`NIVEAU ${p.level} · ${p.name}`),el('h2','',player.name||'Ton pseudo'),el('p','profile-points',`${Number(p.points).toLocaleString('fr-FR')} points`));const progress=el('progress');progress.max=1;progress.value=p.next?Math.min(1,(p.points-p.floor)/(p.next-p.floor)):1;progress.setAttribute('aria-label','Progression du profil');copy.append(progress,el('p','',p.next?`${(p.next-p.points).toLocaleString('fr-FR')} points avant le niveau ${p.level+1}`:'Tous les niveaux de profil atteints.'),btn('Personnaliser mon profil',editPlayer,'player-edit'));hero.append(identity,copy);pane.append(hero);
      const ladder=el('div','profile-levels');for(const level of p.levels||[]){const item=el('div','profile-level'+(level.level<=p.level?' reached':'')+(level.level===p.level?' current':''));item.append(el('span','',String(level.level).padStart(2,'0')),el('b','',level.name),el('small','',`${level.points.toLocaleString('fr-FR')} pts`));ladder.append(item);}pane.append(ladder);root.PlaymeltBadges?.render(pane,state);
      const storage=player.storage||{};
      if(storage.ready&&storage.total>0){
        const fmtOctets=b=>b>=1e9?`${(b/1e9).toLocaleString('fr-FR',{maximumFractionDigits:0})} Go`:`${Math.round(b/1e6).toLocaleString('fr-FR')} Mo`;
        const libre=Math.max(0,storage.free),part=Math.min(1,Math.max(0,(storage.usedPercent||0)));
        const card=el('section','profile-storage'+(libre/storage.total<0.1?' low':''));
        card.append(el('span','discover-kicker',`STOCKAGE · ${storage.volume||'Disque'}`));
        const bar=el('progress');bar.max=1;bar.value=part;bar.setAttribute('aria-label','Espace disque utilisé');card.append(bar);
        card.append(el('p','profile-storage-line',`${fmtOctets(storage.total)} au total · ${fmtOctets(libre)} libres — ${Math.round((libre/storage.total)*100)} %`));
        if(libre/storage.total<0.1)card.append(el('p','profile-storage-warning','Espace insuffisant pour de nouvelles installations.'));
        pane.append(card);
      }
      const heading=el('div','discover-heading-row');heading.append(el('h2','discover-heading','Ton parcours, jeu par jeu'),el('span','',`${p.entries.length} jeux`));pane.append(heading);
      const search=el('input','profile-search');search.type='search';search.placeholder='Retrouver un jeu dans mon parcours';search.setAttribute('aria-label','Rechercher dans mon profil');search.value=profileQuery;pane.append(search);
      const rows=el('div','profile-game-list'),more=btn('Afficher 24 jeux de plus',()=>{profileLimit+=24;draw();},'discover-more');pane.append(rows,more);
      function draw(){rows.replaceChildren();const entries=p.entries.filter(x=>x.title.toLocaleLowerCase('fr').includes(profileQuery.toLocaleLowerCase('fr')));for(const entry of entries.slice(0,profileLimit)){
        const game=state.games.find(x=>x.id===entry.gameId),a=game?art(game):{},row=el('article','profile-game-row');row.append(image([a.hero,a.header,game?.imageURL,entry.image],'profile-game-scene',''));
        const title=game?btn('',()=>openGame(game),'profile-game-title'):el('div','profile-game-title');title.append(image([a.header,game?.imageURL,entry.image],'profile-game-thumb',entry.title));const name=el('div');name.append(el('strong','',entry.title),el('small','',stores[entry.store]||'Local'));title.append(name);row.append(title);
        if(a.logo)row.append(image(a.logo,'profile-game-logo',''));
        const info=el('div','profile-game-stats');for(const [value,label]of [[`${Math.floor(entry.playtime/3600).toLocaleString('fr-FR')} h`,'JOUÉES'],[root.PlaymeltExperience.ladder(game||{title:entry.title,id:entry.gameId})[entry.rank]||root.PlaymeltExperience.tiers[0][1],'MEILLEUR RANG'],[`+${entry.points.toLocaleString('fr-FR')}`,'POINTS ACQUIS']]){const cell=el('div');cell.append(el('strong','',value),el('small','',label));info.append(cell);}row.append(info);rows.append(row);
      }more.hidden=entries.length<=profileLimit;}search.addEventListener('input',()=>{profileQuery=search.value;profileLimit=24;draw();});draw();
      pane.append(el('p','discover-note','Tes points restent acquis après désinstallation. Les paliers de chaque jeu s’additionnent.'));if(p.warning)pane.append(el('p','discover-warning',p.warning));
    }
    function renderLibrary(pane,store){
      if(store!==undefined){libraryStore=store;libraryLimit=48;}
      pane.replaceChildren();pane.classList.add('discover');const all=getState().games||[];
      const tools=el('div','big-library-tools'),search=el('input');search.type='search';search.placeholder='Rechercher dans la bibliothèque';search.setAttribute('aria-label','Rechercher dans Big Picture');search.value=libraryQuery;
      const select=el('select');select.setAttribute('aria-label','Plateforme de la bibliothèque');for(const [key,label]of Object.entries({all:'Toutes les plateformes',...stores,local:'Local'}))select.append(new Option(label,key));select.value=libraryStore;select.addEventListener('change',()=>{libraryStore=select.value;libraryLimit=48;draw();});tools.append(search,select);pane.append(tools);
      const count=el('p','discover-note'),wall=el('div','library-wall'),more=btn('Afficher plus de jeux',()=>{libraryLimit+=48;draw();},'discover-more');pane.append(count,wall,more);
      const draw=()=>{const items=all.filter(g=>(libraryStore==='all'||g.store===libraryStore)&&g.title.toLocaleLowerCase('fr').includes(libraryQuery.toLocaleLowerCase('fr')));count.textContent=`${items.length.toLocaleString('fr-FR')} jeu${items.length>1?'x':''}`;wall.replaceChildren();for(const g of items.slice(0,libraryLimit)){const card=btn('',()=>openGame(g),'library-wall-card');card.append(image([g.localPortraitURL,g.portraitImageURL,g.imageURL],'',g.title),el('span','library-status',g.installed?'Installé':stores[g.store]||'Local'),el('strong','',g.title));card.addEventListener('focus',()=>api.setBackground?.(g));card.addEventListener('mouseenter',()=>api.setBackground?.(g));wall.append(card);}more.hidden=items.length<=libraryLimit;};
      search.addEventListener('input',()=>{libraryQuery=search.value;libraryLimit=48;draw();});draw();
    }
    function renderPlatforms(pane,onSelect){
      pane.replaceChildren();pane.classList.add('discover');const stage=el('div','platform-stage');
      for(const [key,label]of Object.entries(stores)){const games=(getState().games||[]).filter(x=>x.store===key),card=btn('',()=>onSelect(key),'platform-tower store-'+key);const posters=el('div','platform-posters');games.filter(g=>g.portraitImageURL||g.imageURL).slice(0,3).forEach(g=>posters.append(image(g.portraitImageURL||g.imageURL,'',g.title)));card.append(posters,el('span','platform-monogram',key==='xbox'?'X':key==='gog'?'gog':key==='epic'?'EPIC':'S'),el('h2','',label),el('p','',`${games.length} jeu${games.length>1?'x':''} · ${games.filter(x=>x.installed).length} installé${games.filter(x=>x.installed).length>1?'s':''}`),el('span','platform-open','Explorer la bibliothèque →'));stage.append(depth(card));}pane.append(stage);
    }
    const hours=s=>{const h=Math.floor(s/3600);return h>=1?new Intl.NumberFormat('fr-FR').format(h)+' h':Math.round(s/60)+' min';};
    const kicker={steam:'Ta bibliothèque Steam',epic:'Ton coffre Epic Games',xbox:'Xbox Game Pass Ultimate',gog:'Ta collection GOG'};
    function platformHero(store){
      const games=(getState()?.games||[]).filter(g=>g.store===store);
      const withArt=g=>{const a=art(g);return a.hero||a.header||g.imageURL;};
      const pick=[...games].filter(withArt).sort((a,b)=>(b.installed-a.installed)||(b.playtime-a.playtime)||(b.lastPlayed-a.lastPlayed))[0];
      const hero=el('section','pf-hero store-'+store);
      if(pick){const a=art(pick);hero.append(image([a.hero,pick.imageURL,a.header,pick.portraitImageURL],'pf-hero-bg'));}
      const mark=el('span','pf-hero-mark');mark.innerHTML='<svg aria-hidden="true"><use href="#pf-'+store+'"/></svg>';hero.append(mark);
      const copy=el('div','pf-hero-copy');copy.append(brandChip(store,'pf-hero-chip'));
      const kick=el('p','pf-hero-kicker',kicker[store]||stores[store]);copy.append(kick);
      if(pick){
        copy.append(el('h2','pf-hero-title',pick.title));
        const meta=[pick.installed?'Installé':(store==='xbox'?'Cloud et PC':'Dans ta bibliothèque'),pick.playtime>0?hours(pick.playtime)+' de jeu':''].filter(Boolean).join(' · ');
        copy.append(el('p','pf-hero-meta',meta));
        const playable=pick.installed&&pick.canLaunch,actions=el('div','pf-hero-actions');
        const go=btn('',()=>{if(playable&&api.send?.('launchGame',{gameId:pick.id}))return;openGame(pick);},'pf-action store-'+store);go.append(el('span','pf-play','▶'),el('span','',playable?'Jouer':'Voir la fiche'));actions.append(go);
        if(playable)actions.append(btn('Voir la fiche',()=>openGame(pick),'pf-hero-sheet'));
        copy.append(actions);
        hero.classList.add('is-clickable');hero.addEventListener('click',e=>{if(!e.target.closest('button'))openGame(pick);});
      }else copy.append(el('h2','pf-hero-title',stores[store]));
      hero.append(copy);
      if(store==='xbox')hero.append(el('p','pf-hero-note','Cloud : jouable ici · PC : catalogue Windows, installation locale non prise en charge pour le moment.'));
      return hero;
    }
    const nf=n=>new Intl.NumberFormat('fr-FR').format(n);
    const pick=(list,seed)=>list.length?list[Math.abs(seed)%list.length]:'';
    function platformSummary(store){
      const games=(getState()?.games||[]).filter(g=>g.store===store),label=stores[store]||store;
      const on=(g,p)=>g.platform===p||(Array.isArray(g.platforms)&&g.platforms.includes(p));
      const total=games.reduce((t,g)=>t+(g.playtime||0),0),h=Math.floor(total/3600);
      const played=games.filter(g=>g.playtime>0||g.lastPlayed>0),never=games.length-played.length;
      const top=[...games].sort((a,b)=>b.playtime-a.playtime)[0];
      const share=top&&total>0?Math.round(top.playtime/total*100):0;
      const day=Math.floor(Date.now()/86400000);
      const band=el('section','pf-summary store-'+store),head=el('div','pf-summary-head');
      head.append(brandChip(store,'pf-summary-brand'),el('span','pf-summary-label',store==='xbox'?'Ton Game Pass en chiffres':label+' en chiffres'));
      const stats=el('div','pf-summary-stats'),stat=(value,name,accent)=>{const d=el('div','pf-stat'+(accent?' is-accent':''));d.append(el('b','',value),el('span','',name));stats.append(d);};
      if(store==='xbox'){
        stat(nf(games.length),'jeux au catalogue');stat(nf(games.filter(g=>on(g,'cloud')).length),'jouables en cloud',true);stat(nf(games.filter(g=>on(g,'windows')).length),'sur PC');
        stat(nf(games.filter(g=>Number(g.gamePassRecent)>=0).length),'ajouts récents');stat(nf(played.length),'déjà lancés');
      }else{
        stat(nf(games.length),'jeux possédés');stat(h>0?nf(h)+' h':total>0?Math.max(1,Math.round(total/60))+' min':'0 h',h>0||total>0?'de jeu au compteur':'au compteur, pour l’instant',true);
        stat(nf(games.filter(g=>g.installed).length),'installés');
        if(store==='steam')stat(nf(games.filter(g=>on(g,'mac')).length),'natifs Mac');
        {const pct=games.length?never/games.length*100:0;stat((never===games.length||never===0?Math.round(pct):Math.min(99,Math.max(1,Math.round(pct))))+' %','jamais lancés');}
      }
      const quips=[];
      if(top&&share>=15)quips.push(`${top.title} pèse ${share} % de ton temps ${label}. On appelle ça une relation sérieuse.`);
      if(h>=24)quips.push(`${nf(h)} h, soit ${nf(Math.round(h/24))} jours d’affilée sans dormir. Ton canapé a gagné le droit à une retraite.`);
      if(never>=10&&store!=='xbox')quips.push(`${nf(never)} jeux jamais lancés : ta pile de jeux en attente a sa propre pile de jeux en attente.`);
      if(store==='xbox')quips.push(`${nf(games.filter(g=>on(g,'cloud')).length)} jeux jouables tout de suite, sans téléchargement. Le plus dur, c’est de choisir.`);
      if(store==='epic')quips.push('Chaque jeudi, un jeu offert. Ta bibliothèque Epic grandit plus vite que ton temps libre.');
      if(store==='gog')quips.push('Sans DRM : ces jeux sont vraiment à toi. Même dans vingt ans.');
      if(!quips.length)quips.push('Tout est prêt. Il ne manque que toi.');
      band.append(head,stats,el('p','pf-summary-quip',pick(quips,day)));
      // Ligne de phrases qui défilent : faits tirés de ta bibliothèque + clins d'œil.
      const facts=[];
      const longest=[...games].filter(g=>g.lastPlayed>0).sort((a,b)=>a.lastPlayed-b.lastPlayed)[0];
      if(longest)facts.push(`Pas vu depuis longtemps : ${longest.title}. Il t’attend toujours.`);
      const recent=[...games].filter(g=>g.lastPlayed>0).sort((a,b)=>b.lastPlayed-a.lastPlayed)[0];
      if(recent)facts.push(`Dernière partie : ${recent.title}.`);
      const fresh=games.filter(g=>!(g.playtime>0)&&!(g.lastPlayed>0));
      if(fresh.length)facts.push(`Idée du jour : lancer ${pick(fresh,day).title}, jamais essayé.`);
      if(top&&top.playtime>3600)facts.push(`Record : ${top.title}, ${nf(Math.floor(top.playtime/3600))} h. Le jeu te connaît mieux que ta famille.`);
      if(h>0)facts.push(`${nf(h)} h de jeu, c’est ${nf(Math.round(h/2))} films. Mais en mieux.`);
      facts.push(...{steam:['Un jeu en solde reste un jeu acheté.','La file de découvertes ne dort jamais.'],epic:['Récupérer un jeu offert compte comme une victoire.','Le jeudi, on rafraîchit la boutique.'],xbox:['Le cloud, c’est jouer sans attendre une barre de progression.','Une manette, un Mac, et c’est parti.'],gog:['Les classiques ne vieillissent pas, ils mûrissent.','Ton installateur hors ligne est une capsule temporelle.']}[store]||[]);
      if(facts.length){
        const ticker=el('div','pf-ticker'),track=el('div','pf-ticker-track');
        ticker.append(el('span','pf-ticker-dot'),track);
        const order=facts.map((f,i)=>facts[(i+day)%facts.length]);
        order.forEach((text,i)=>track.append(el('span','pf-ticker-item'+(i===0?' is-on':''),text)));
        let at=0;const timer=setInterval(()=>{if(!ticker.isConnected){clearInterval(timer);return;}const items=track.children;items[at].classList.remove('is-on');at=(at+1)%items.length;items[at].classList.add('is-on');},5200);
        band.append(ticker);
      }
      return band;
    }
    function renderStore(pane,store){
      pane.replaceChildren();
      pane.append(platformSummary(store),platformHero(store));
      if(store==='xbox')return;
      const urls={steam:'https://store.steampowered.com/specials/',epic:'https://store.epicgames.com/fr/',gog:'https://www.gog.com/fr/games/discounted'};
      const items=offers(getFeed()).filter(x=>x.store===store);
      const sections=store==='epic'?[['giveaway','Jeux offerts · cette semaine et la suivante','Boutique Epic',urls.epic],['sale','Promotions Epic','Toutes les promotions','https://store.epicgames.com/fr/sales-and-specials']]:[['sale','Promotions '+stores[store],'Toutes les promotions',urls[store]]];
      sections.forEach(([kind,label,cta,url],i)=>{
        const found=items.filter(x=>x.kind===kind).slice(0,4);
        if(kind==='giveaway'){const now=Date.now()/1000;found.push(...(getFeed()?.freeGames||[]).filter(x=>x.current!==true&&Number(x.start)>now).slice(0,Math.max(1,3-found.length)).map(x=>({...x,id:'epic-soon:'+(x.id||x.url),store:'epic',kind:'upcoming',priceCents:0,currency:'EUR'})));}
        if(!found.length&&i>0)return;
        const head=el('div','store-section-head'),action=btn('',()=>openLink(url),'pf-action store-'+store);action.append(glyph(store),el('span','',cta));
        head.append(el('h2','store-section-title',found.length?label:'Boutique '+stores[store]),action);pane.append(head);
        if(found.length){const row=el('div','offers-grid'+(kind==='giveaway'?' platform-giveaways':''));found.forEach(x=>row.append(offerCard(x)));pane.append(row);}
      });
      if(!items.length)pane.append(el('p','discover-note',getFeed()?'Le flux d’offres est momentanément indisponible. La boutique reste accessible.':'Chargement des offres…'));
    }
    function renderStoreDeals(pane,store,limit=8){const found=offers(getFeed()).filter(x=>x.store===store&&x.kind!=="giveaway").slice(0,limit);if(!found.length)return;const head=el('div','store-section-head');head.append(el('h2','store-section-title','Bons plans '+(stores[store]||store)));pane.append(head);const grid=el('div','offers-grid');found.forEach(x=>grid.append(offerCard(x)));pane.append(grid);}
    function renderOfferHighlights(pane){const grid=el('div','offers-grid');offers(getFeed()).slice(0,4).forEach(x=>grid.append(offerCard(x)));pane.append(grid);}
    return {renderStoreDeals,renderStore,renderOffers,renderOfferHighlights,renderProfile,renderNews,renderLibrary,renderPlatforms,newsCard,brandChip,glyph};
  }
  if(typeof module!=='undefined'&&module.exports)module.exports={offers};else root.PlaymeltDiscover={create,offers};
})(typeof window==='undefined'?{}:window);

// ── Badges Playmelt : 14 familles × 4 paliers + 4 secrets, calculés sur les vraies données du joueur ──
(function(root){
  'use strict';
  const KEY='playmelt_badges_v1',H=3600,DAY=86400,NS='http://www.w3.org/2000/svg';
  const TIERS=[['bronze','Bronze'],['silver','Argent'],['gold','Or'],['prism','Prisme']];
  const nf=n=>new Intl.NumberFormat('fr-FR').format(Math.floor(n));
  const GLYPHS={
    stack:'<rect x="4" y="9" width="16" height="11" rx="2"/><path d="M6.5 6h11M9 3h6"/>',
    hourglass:'<path d="M7 3h10M7 21h10"/><path d="M8 3c0 4.5 8 5.5 8 9s-8 4.5-8 9"/><path d="M16 3c0 4.5-8 5.5-8 9s8 4.5 8 9"/>',
    flame:'<path d="M12 21c-3.9 0-6.5-2.6-6.5-6.2 0-3.6 3-5.8 3.6-9.3 2.4 1.7 3.2 3.8 3 5.6 1.2-.8 2-2.1 2.1-3.6 2.4 2 3.8 4.6 3.8 7.4 0 3.6-2.5 6.1-6 6.1z"/>',
    compass:'<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5l-2 5-5 2 2-5z"/>',
    trophy:'<path d="M8 4h8v5a4 4 0 0 1-8 0z"/><path d="M8 6H5a3 3 0 0 0 3 4M16 6h3a3 3 0 0 1-3 4M12 13v4M8.5 20h7M10 17h4"/>',
    diamond:'<path d="M12 3l8 9-8 9-8-9z"/><path d="M12 8l3.5 4-3.5 4-3.5-4z"/>',
    crown:'<path d="M4 19h16M5 16 4 7l5 4 3-6 3 6 5-4-1 9z"/>',
    orbit:'<circle cx="12" cy="12" r="3"/><ellipse cx="12" cy="12" rx="9.5" ry="4" transform="rotate(-30 12 12)"/><circle cx="19.6" cy="7.2" r="1.3"/>',
    laptop:'<rect x="5" y="5" width="14" height="10" rx="1.5"/><path d="M3 19h18l-2-4H5z"/>',
    cloud:'<path d="M7 18a4 4 0 0 1-.4-8A5.5 5.5 0 0 1 17.3 9 4.5 4.5 0 0 1 17 18z"/>',
    chest:'<path d="M4 11h16v9H4z"/><path d="M4 11a8 6 0 0 1 16 0"/><path d="M11 13h2v3h-2z"/>',
    drive:'<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 12h5"/><circle cx="16.5" cy="12" r="1"/>',
    bolt:'<path d="M13 2 5 13h6l-1 9 8-11h-6z"/>',
    peaks:'<path d="M2 20 9 8l4 6 3-4 6 10z"/><path d="M7.5 10.5 9 12l1.5-1.5"/>',
    moon:'<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
    ghost:'<path d="M5 20v-9a7 7 0 0 1 14 0v9l-2.3-1.6L14.4 20 12 18.4 9.6 20l-2.3-1.6z"/><circle cx="9.5" cy="11" r=".8"/><circle cx="14.5" cy="11" r=".8"/>',
    owl:'<path d="M5 6l3 2h8l3-2v9a7 7 0 0 1-14 0z"/><circle cx="9" cy="12" r="2"/><circle cx="15" cy="12" r="2"/><path d="M11.3 15.5h1.4"/>',
    secret:'<path d="M9.2 9a2.9 2.9 0 1 1 4.3 2.5c-.9.5-1.5 1.1-1.5 2.2v.6"/><circle cx="12" cy="18" r=".6"/>'
  };
  const FAMILIES=[
    {id:'collection',name:'Collectionneur',glyph:'stack',unit:['jeu','jeux'],goals:[50,250,750,1500],titles:['Étagère pleine','Mur de boîtes','Archiviste','Conservateur du musée'],hint:'Jeux possédés, toutes boutiques (catalogue Game Pass non compté).',value:s=>s.owned},
    {id:'marathon',name:'Marathonien',glyph:'hourglass',unit:['heure','heures'],goals:[100,1000,3000,6000],titles:['Week-end prolongé','Mi-temps assumé','Six mois de canapé','Une vie parallèle'],hint:'Temps de jeu cumulé sur toutes tes plateformes.',value:s=>s.hours},
    {id:'obsession',name:'Obsession',glyph:'flame',unit:['heure','heures'],goals:[50,200,500,1000],titles:['Accroché','Obsédé','Résident permanent','Il habite là'],hint:'Ton record d’heures sur un seul jeu.',value:s=>s.maxHours},
    {id:'explorer',name:'Explorateur',glyph:'compass',unit:['jeu lancé','jeux lancés'],goals:[10,50,150,300],titles:['Curieux','Touche-à-tout','Explorateur','Cartographe'],hint:'Jeux différents auxquels tu as joué.',value:s=>s.played},
    {id:'hunter',name:'Chasseur de succès',glyph:'trophy',unit:['succès','succès'],goals:[50,250,1000,3000],titles:['Pisteur','Chasseur','Traqueur','Prédateur'],hint:'Succès débloqués dans tes jeux.',value:s=>s.unlocked},
    {id:'perfect',name:'Perfectionniste',glyph:'diamond',unit:['jeu à 100 %','jeux à 100 %'],goals:[1,3,10,25],titles:['Sans-faute','Platine','Maniaque','Tout, partout'],hint:'Jeux dont tu as débloqué tous les succès.',value:s=>s.perfect},
    {id:'veteran',name:'Spécialiste',glyph:'crown',unit:['jeu à 50 h','jeux à 50 h'],goals:[1,5,15,30],titles:['Spécialiste','Polyvalent','Multi-vétéran','Panthéon'],hint:'Jeux où tu as passé au moins 50 heures.',value:s=>s.veteran},
    {id:'nomad',name:'Sans frontières',glyph:'orbit',unit:['plateforme','plateformes'],goals:[2,3,5,7],titles:['Bilingue','Polyglotte','Diplomate','Citoyen du monde'],hint:'Boutiques et services reliés à Playmelt.',value:s=>s.platforms},
    {id:'mac',name:'Natif Mac',glyph:'laptop',unit:['jeu natif Mac joué','jeux natifs Mac joués'],goals:[1,5,15,40],titles:['Fait maison','Natif','Pur Mac','Ambassadeur'],hint:'Jeux qui tournent nativement sur Mac et auxquels tu as joué.',value:s=>s.mac},
    {id:'cloud',name:'Tête dans les nuages',glyph:'cloud',unit:['jeu Game Pass lancé','jeux Game Pass lancés'],goals:[1,5,15,40],titles:['Premier envol','Pilote de nuage','Météorologue','Maître des orages'],hint:'Jeux Xbox Game Pass lancés.',value:s=>s.xbox},
    {id:'chest',name:'Pilleur de coffres',glyph:'chest',unit:['jeu Epic','jeux Epic'],goals:[10,50,150,300],titles:['Chasseur de cadeaux','Pilleur de coffres','Dragon sur son or','Trésorier royal'],hint:'Ta bibliothèque Epic, jeux offerts compris.',value:s=>s.epic},
    {id:'disk',name:'Disque gourmand',glyph:'drive',unit:['jeu installé','jeux installés'],goals:[1,3,8,15],titles:['Premier plein','SSD chargé','Disque gourmand','Le SSD crie'],hint:'Jeux installés en ce moment sur ton Mac.',value:s=>s.installed},
    {id:'streak',name:'En forme',glyph:'bolt',unit:['jeu en 14 jours','jeux en 14 jours'],goals:[2,4,8,15],titles:['Échauffement','En rythme','Boulimique','Insatiable'],hint:'Jeux différents lancés ces 14 derniers jours.',value:s=>s.recent},
    {id:'ascension',name:'Ascension',glyph:'peaks',unit:['niveau','niveaux'],goals:[3,5,7,9],titles:['Premiers pas','Grimpeur','Alpiniste','Sommet'],hint:'Ton niveau de profil Playmelt.',value:s=>s.level}
  ];
  const SECRETS=[
    {id:'secret-month',name:'Un mois sans dormir',glyph:'moon',hint:'Un seul jeu. Beaucoup, beaucoup d’heures.',desc:'720 heures sur un seul jeu : trente jours pleins.',test:s=>s.maxHours>=720},
    {id:'secret-thousand',name:'Le millier',glyph:'stack',hint:'Compte tes boîtes.',desc:'1 000 jeux possédés.',test:s=>s.owned>=1000},
    {id:'secret-shame',name:'La pile de la honte',glyph:'ghost',hint:'Ceux qui attendent sagement leur tour.',desc:'100 jeux possédés jamais lancés.',test:s=>s.never>=100},
    {id:'secret-owl',name:'Noctambule',glyph:'owl',hint:'Certaines parties finissent tard.',desc:'Une partie lancée entre 1 h et 5 h du matin.',test:s=>s.night}
  ];
  const sec=v=>{v=Number(v)||0;return v>1e12?v/1000:v;};
  function stats(state){
    const seen=new Set(),games=(state?.games||[]).filter(g=>g&&g.id&&!seen.has(g.id)&&seen.add(g.id));
    const played=g=>Number(g.playtime)>0||sec(g.lastPlayed)>0,now=Date.now()/1000;
    let total=0,max=0,unlocked=0,perfect=0,veteran=0;
    for(const g of games){const t=Number(g.playtime)||0;total+=t;if(t>max)max=t;if(t>=50*H)veteran++;const a=g.achievements;
      if(a&&typeof a==='object'&&Number(a.total)>0){const u=Number(a.unlockedCount)||0;unlocked+=u;if(u>=Number(a.total))perfect++;}}
    const owned=games.filter(g=>g.store!=='xbox'),list=games.filter(played);
    const stores=new Set(games.map(g=>g.store).filter(x=>x&&x!=='local'));
    let services=[];try{services=root.PlaymeltServices?.active?.(state)||[];}catch{}
    return {owned:owned.length,hours:total/H,maxHours:max/H,played:list.length,unlocked,perfect,veteran,
      platforms:stores.size+services.filter(x=>!stores.has(x)).length,
      mac:list.filter(g=>(g.platforms||[]).includes('mac')).length,xbox:list.filter(g=>g.store==='xbox').length,
      epic:games.filter(g=>g.store==='epic').length,installed:games.filter(g=>g.installed===true&&g.platform!=='cloud').length,
      recent:list.filter(g=>sec(g.lastPlayed)>0&&now-sec(g.lastPlayed)<14*DAY).length,level:Number(state?.profile?.level)||1,
      never:owned.filter(g=>!played(g)).length,
      night:list.some(g=>{const t=sec(g.lastPlayed);if(!t)return false;const h=new Date(t*1000).getHours();return h>=1&&h<5;})};
  }
  function evaluate(state,stored){
    const s=stats(state),got=stored?.got||{};
    const fam=FAMILIES.map(f=>{const value=Math.floor(f.value(s)),reached=f.goals.filter(g=>value>=g).length-1,tier=Math.max(reached,got[f.id]?.tier??-1);
      const next=f.goals[tier+1];return {kind:'family',f,id:f.id,value,tier,next,progress:next?Math.min(1,value/next):1};});
    const secrets=SECRETS.map(x=>({kind:'secret',f:x,id:x.id,tier:(x.test(s)||got[x.id])?0:-1}));
    return {stats:s,families:fam,secrets};
  }
  const load=()=>{try{return JSON.parse(localStorage.getItem(KEY)||'null');}catch{return null;}};
  const save=d=>{try{localStorage.setItem(KEY,JSON.stringify(d));}catch{}};
  function sync(state){
    if(!(state?.games||[]).length)return {data:load(),result:null,newly:[]};
    let data=load();const now=Date.now();if(!data)data={since:now,got:{},fresh:[]};const first=now-data.since<120000;
    const result=evaluate(state,data),newly=[];
    for(const b of [...result.families,...result.secrets]){
      const prev=data.got[b.id],prevTier=prev?prev.tier:-1;if(b.tier<=prevTier)continue;
      const dates={...(prev?.dates||{})};for(let t=prevTier+1;t<=b.tier;t++)dates[t]={at:now,baseline:first};
      data.got[b.id]={tier:b.tier,dates};if(!data.fresh.includes(b.id))data.fresh.push(b.id);if(!first)newly.push(b);
    }
    if(first)data.first=true;save(data);return {data,result,newly};
  }
  function ensureDefs(){
    if(typeof document==='undefined'||document.getElementById('pmb-defs'))return;
    const g=(id,stops)=>`<linearGradient id="pmb-${id}" x1="0" y1="0" x2="1" y2="1">${stops.map((c,i)=>`<stop offset="${i/(stops.length-1)}" stop-color="${c}"/>`).join('')}</linearGradient>`;
    const svg=document.createElementNS(NS,'svg');svg.id='pmb-defs';svg.setAttribute('width','0');svg.setAttribute('height','0');svg.setAttribute('aria-hidden','true');svg.style.position='absolute';
    svg.innerHTML='<defs>'+g('bronze',['#ffd0a3','#c47a3f','#7a3f17','#e0a067'])+g('silver',['#ffffff','#b9c3cc','#6c7884','#e3e9ee'])+g('gold',['#fff3b0','#f0b93a','#9a5f0c','#ffd768'])
      +g('lock',['#4a535c','#2b3239','#1c2126','#3a424a'])+g('secret',['#c9a8ff','#6b3fd1','#2a1460','#9d74ff'])
      +'<linearGradient id="pmb-prism" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7ef3ff"/><stop offset=".33" stop-color="#b48cff"/><stop offset=".66" stop-color="#ff9ed6"/><stop offset="1" stop-color="#ffe58f"/><animateTransform attributeName="gradientTransform" type="rotate" from="0 .5 .5" to="360 .5 .5" dur="8s" repeatCount="indefinite"/></linearGradient>'
      +'<linearGradient id="pmb-bevel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".45" stop-color="#fff" stop-opacity=".06"/><stop offset=".55" stop-color="#000" stop-opacity=".05"/><stop offset="1" stop-color="#000" stop-opacity=".35"/></linearGradient>'
      +'<radialGradient id="pmb-face" cx=".5" cy=".38" r=".7"><stop offset="0" stop-color="#2c3a46"/><stop offset="1" stop-color="#0d1318"/></radialGradient></defs>';
    document.body.append(svg);
  }
  function medal(glyph,tier,secret){
    ensureDefs();const key=secret?(tier>=0?'secret':'lock'):tier<0?'lock':TIERS[tier][0];
    const pips=!secret&&tier>=0?Array.from({length:tier+1},(_,i)=>`<circle cx="${50+(i-tier/2)*7}" cy="89" r="2.1"/>`).join(''):'';
    const ink=secret&&tier<0?GLYPHS.secret:GLYPHS[glyph]||GLYPHS.secret;
    const span=document.createElement('span');span.className='bdg-medal tier-'+key;
    span.innerHTML=`<svg viewBox="0 0 100 100" aria-hidden="true"><polygon class="bdg-rim" points="50,2 84,16 98,50 84,84 50,98 16,84 2,50 16,16" fill="url(#pmb-${key})"/><polygon points="50,2 84,16 98,50 84,84 50,98 16,84 2,50 16,16" fill="url(#pmb-bevel)"/><path d="M50 2v15M84 16 73.3 26.7M98 50H83M84 84 73.3 73.3M50 98V83M16 84l10.7-10.7M2 50h15M16 16l10.7 10.7" stroke="#ffffff2e" stroke-width=".8"/><polygon points="50,7.5 80.2,19.8 92.5,50 80.2,80.2 50,92.5 19.8,80.2 7.5,50 19.8,19.8" fill="none" stroke="#ffffff50" stroke-width="1"/><circle cx="50" cy="50" r="33" fill="url(#pmb-face)" stroke="url(#pmb-${key})" stroke-width="3.2"/><circle cx="50" cy="50" r="28" fill="none" stroke="#ffffff1f" stroke-width="1" stroke-dasharray="2 3"/><g transform="translate(32 31) scale(1.5)" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${ink}</g><g fill="currentColor">${pips}</g>${key==='prism'||key==='secret'?'<path class="bdg-spark" d="M86 6l1.6 4.4L92 12l-4.4 1.6L86 18l-1.6-4.4L80 12l4.4-1.6z" fill="#fff"/><path class="bdg-spark s2" d="M13 74l1 2.8 2.8 1-2.8 1L13 81.6l-1-2.8-2.8-1 2.8-1z" fill="#fff"/>':''}</svg>`;
    return span;
  }
  const el=(tag,cls,text)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=String(text);return n;};
  const unit=(f,n)=>f.unit[n>1?1:0];
  const when=d=>d?(d.baseline?'Déjà acquis à ton arrivée':'Débloqué le '+new Date(d.at).toLocaleDateString('fr-FR',{day:'numeric',month:'short',year:'numeric'})):'';
  const titleOf=b=>b.kind==='secret'?b.f.name:b.tier>=0?b.f.titles[b.tier]:b.f.titles[0];
  function card(b,data){
    const secret=b.kind==='secret',got=b.tier>=0,fresh=got&&!data?.first&&data?.fresh?.includes(b.id);
    const node=el('button','bdg-card'+(got?'':' is-locked')+(secret?' is-secret':'')+(fresh?' is-new':''));node.type='button';
    node.append(medal(b.f.glyph,b.tier,secret));
    const copy=el('span','bdg-copy');
    if(secret){copy.append(el('small','',got?'Secret débloqué':'Badge secret'),el('strong','',got?b.f.name:'???'),el('span','bdg-goal',got?b.f.desc:b.f.hint));}
    else{
      copy.append(el('small','',b.f.name+(got?' · '+TIERS[b.tier][1]:'')),el('strong','',got?b.f.titles[b.tier]:b.f.titles[0]));
      copy.append(el('span','bdg-goal',b.next?`${nf(b.value)} / ${nf(b.next)} ${unit(b.f,b.next)}${got?' → '+b.f.titles[b.tier+1]:''}`:`${nf(b.value)} ${unit(b.f,b.value)} · palier maximum`));
      const bar=el('span','bdg-bar'),fill=el('i');fill.style.setProperty('--p',String(b.progress));bar.append(fill);copy.append(bar);
    }
    if(fresh)copy.firstChild.append(el('span','bdg-new','Nouveau'));
    node.append(copy);
    const detail=el('span','bdg-detail');
    if(secret)detail.append(el('span','bdg-step'+(got?' on':''),got?when(data?.got?.[b.id]?.dates?.[0]):'Pas encore. Indice : '+b.f.hint));
    else b.f.goals.forEach((goal,t)=>{const step=el('span','bdg-step tier-'+TIERS[t][0]+(t<=b.tier?' on':''));step.append(el('b','',TIERS[t][1]),el('span','',b.f.titles[t]),el('em','',t<=b.tier?when(data?.got?.[b.id]?.dates?.[t]):`${nf(goal)} ${unit(b.f,goal)}`));detail.append(step);});
    detail.append(el('span','bdg-hint',secret?'':b.f.hint));node.append(detail);
    node.addEventListener('click',()=>node.classList.toggle('is-open'));
    return node;
  }
  function render(pane,state){
    const {data,result}=sync(state);if(!result)return;
    const all=[...result.families,...result.secrets],total=FAMILIES.length*4+SECRETS.length;
    const count=result.families.reduce((n,b)=>n+b.tier+1,0)+result.secrets.filter(b=>b.tier>=0).length;
    const section=el('section','bdg-panel'+(data?.first&&data.fresh.length>6?' is-arrival':''));
    const head=el('div','bdg-head'),ring=el('span','bdg-total');ring.style.setProperty('--p',String(count/total));ring.append(el('b','',String(count)),el('small','','/ '+total));
    const ht=el('div','bdg-head-copy');ht.append(el('span','discover-kicker','BADGES PLAYMELT'),el('h2','',count?`${count} badges débloqués`:'Tes premiers badges t’attendent'),
      el('p','',data?.first&&data.fresh.length?'Tout ce que tu as déjà accompli compte : tes badges sont débloqués d’après ta vraie bibliothèque.':'Quatre paliers par badge : Bronze, Argent, Or, puis Prisme. Clique un badge pour voir la suite.'));
    head.append(ring,ht);section.append(head);
    const rank=b=>(b.kind==='secret'?2.5:b.tier)+(b.next?b.progress*.01:0.05);
    const best=all.filter(b=>b.tier>=0).sort((a,b)=>rank(b)-rank(a)).slice(0,3);
    if(best.length){const show=el('div','bdg-showcase');best.forEach((b,i)=>{const item=el('div','bdg-show'+(i===0?' is-first':''));item.append(medal(b.f.glyph,b.tier,b.kind==='secret'),el('strong','',titleOf(b)),el('small','',b.kind==='secret'?'Secret':b.f.name+' · '+TIERS[b.tier][1]));show.append(item);});section.append(show);}
    const grid=el('div','bdg-grid');result.families.slice().sort((a,b)=>(b.tier-a.tier)||(b.progress-a.progress)).forEach((b,i)=>{const c=card(b,data);c.style.setProperty('--i',String(i));grid.append(c);});section.append(grid);
    const sh=el('h3','bdg-sub','Badges secrets');sh.append(el('span','',`${result.secrets.filter(b=>b.tier>=0).length} / ${SECRETS.length}`));section.append(sh);
    const sg=el('div','bdg-grid bdg-secrets');result.secrets.forEach((b,i)=>{const c=card(b,data);c.style.setProperty('--i',String(i+FAMILIES.length));sg.append(c);});section.append(sg);
    pane.append(section);
    if(data?.fresh?.length)setTimeout(()=>{const d=load();if(d){d.fresh=[];d.first=false;save(d);}},5000);
  }
  let popTimer=0;
  function check(state,opts={}){
    const {newly}=sync(state);if(!newly.length||typeof document==='undefined')return newly;
    const top=newly.slice().sort((a,b)=>(b.kind==='secret'?2.5:b.tier)-(a.kind==='secret'?2.5:a.tier))[0];
    document.querySelector('.bdg-pop')?.remove();clearTimeout(popTimer);
    const pop=el('div','bdg-pop');const rays=el('span','bdg-pop-rays');pop.append(rays,medal(top.f.glyph,top.tier,top.kind==='secret'));
    const copy=el('div','bdg-pop-copy');copy.append(el('small','',top.kind==='secret'?'Badge secret débloqué':'Badge débloqué · '+TIERS[top.tier][1]),el('strong','',titleOf(top)),
      el('span','',top.kind==='secret'?top.f.desc:top.f.name+(newly.length>1?` · et ${newly.length-1} autre${newly.length>2?'s':''}`:'')));pop.append(copy);
    const close=el('button','bdg-pop-close','×');close.type='button';close.setAttribute('aria-label','Fermer');close.addEventListener('click',e=>{e.stopPropagation();pop.remove();});pop.append(close);
    pop.addEventListener('click',()=>{pop.remove();opts.onOpen?.();});document.body.append(pop);popTimer=setTimeout(()=>pop.classList.add('is-leaving'),7000);setTimeout(()=>pop.remove(),7600);
    return newly;
  }
  const api={stats,evaluate,sync,render,check,FAMILIES,SECRETS,TIERS};
  if(typeof module!=='undefined'&&module.exports)module.exports.badges=api;else root.PlaymeltBadges=api;
})(typeof window==='undefined'?{}:window);
