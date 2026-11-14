(function(root){
'use strict';
const platforms=[
 {id:'steam',name:'Steam',action:'syncLibrary',detail:'Bibliothèque, installations et succès'},
 {id:'epic',name:'Epic Games',action:'connectEpic',detail:'Bibliothèque, jeux offerts et installations'},
 {id:'xbox',name:'Xbox Game Pass',action:'openXbox',detail:'Cloud intégré · catalogue PC Windows'},
 {id:'gog',name:'GOG',action:'openGOG',detail:'Bibliothèque synchronisée avec GOG Galaxy'},
 {id:'amazon',name:'Amazon Games / Luna',url:'https://luna.amazon.fr/',detail:'Compte et cloud'},
 {id:'ea',name:'EA',url:'https://www.ea.com/',detail:'Compte et boutique'},
 {id:'ubisoft',name:'Ubisoft Connect',url:'https://www.ubisoft.com/fr-fr/ubisoft-connect',detail:'Compte et boutique'},
 {id:'battle',name:'Battle.net',url:'https://eu.shop.battle.net/fr-fr',detail:'Compte et boutique'},
 {id:'itch',name:'itch.io',url:'https://itch.io/login',detail:'Compte et achats'},
 {id:'humble',name:'Humble Bundle',url:'https://www.humblebundle.com/',detail:'Compte, achats et clés'},
 {id:'geforce',name:'GeForce NOW',url:'https://play.geforcenow.com/',detail:'Service cloud'}
];
// Registre des plateformes : identité (couleurs, logo), type et détection de connexion.
const services={
 amazon:{name:'Amazon Luna',short:'Luna',a:'#9146ff',b:'#4b1fb8',soft:'#c8a8ff',bg:'#140d22',surface:'#24183b',kind:'cloud',detect:'cookie',url:'https://luna.amazon.fr/',tagline:'Le cloud gaming d’Amazon, inclus avec Prime Gaming.'},
 geforce:{name:'GeForce NOW',short:'GeForce NOW',a:'#76b900',b:'#3f6b00',soft:'#b6f04a',bg:'#0d120a',surface:'#1a2412',kind:'cloud',detect:'manual',url:'https://play.geforcenow.com/',tagline:'Tes jeux Steam, Epic et Ubisoft en cloud, sur des PC NVIDIA.'},
 ea:{name:'EA',short:'EA',a:'#ff4747',b:'#b31f2e',soft:'#ff9a9a',bg:'#1a0d10',surface:'#2c161b',kind:'store',detect:'cookie',url:'https://www.ea.com/',tagline:'Compte EA et boutique EA app.'},
 ubisoft:{name:'Ubisoft Connect',short:'Ubisoft',a:'#1e90ff',b:'#0047b3',soft:'#8cc4ff',bg:'#0b1220',surface:'#162238',kind:'store',detect:'manual',url:'https://www.ubisoft.com/fr-fr/ubisoft-connect',tagline:'Compte Ubisoft, récompenses et boutique.'},
 battle:{name:'Battle.net',short:'Battle.net',a:'#148eff',b:'#0a4fa8',soft:'#8fc6ff',bg:'#0a111c',surface:'#152236',kind:'store',detect:'cookie',url:'https://eu.shop.battle.net/fr-fr',tagline:'Les jeux Blizzard et Activision.'},
 itch:{name:'itch.io',short:'itch.io',a:'#fa5c5c',b:'#c03a3a',soft:'#ffa3a3',bg:'#1a0e0e',surface:'#2d1919',kind:'store',detect:'cookie',url:'https://itch.io/login',tagline:'Le repaire des jeux indépendants.'},
 humble:{name:'Humble Bundle',short:'Humble',a:'#e8483a',b:'#8f1f1a',soft:'#ff9d92',bg:'#1a0f0d',surface:'#2d1a17',kind:'store',detect:'cookie',url:'https://www.humblebundle.com/',tagline:'Bundles, clés et Humble Choice.'}
};
root.PlaymeltServices={
 list:services,
 read(){try{const raw=JSON.parse(localStorage.getItem('playmelt_services')||'{}');return {added:Array.isArray(raw.added)?raw.added:[],removed:Array.isArray(raw.removed)?raw.removed:[]};}catch{return {added:[],removed:[]};}},
 write(v){try{localStorage.setItem('playmelt_services',JSON.stringify(v));}catch{}},
 active(state){const v=this.read();let auto=state?.services;if(auto)try{localStorage.setItem("playmelt_services_auto",JSON.stringify(auto));}catch{}else try{auto=JSON.parse(localStorage.getItem("playmelt_services_auto")||"{}");}catch{auto={};}return Object.keys(services).filter(id=>!v.removed.includes(id)&&(v.added.includes(id)||auto[id]===true));},
 add(id){const v=this.read();v.added=[...new Set([...v.added,id])];v.removed=v.removed.filter(x=>x!==id);this.write(v);},
 remove(id){const v=this.read();v.added=v.added.filter(x=>x!==id);v.removed=[...new Set([...v.removed,id])];this.write(v);}
};
function create(api){const {el,getState,send,openLink,goProfile,renderMachine,openGame}=api;let selected='accounts',query='',gameLimit=30;const button=(text,fn,cls='button')=>{const b=el('button',cls,text);b.type='button';b.addEventListener('click',fn);return b;};
function render(panel){panel.replaceChildren();panel.classList.add('settings-page');const nav=el('nav','settings-tabs');nav.setAttribute('aria-label','Catégories de paramètres');const content=el('div','settings-content');
for(const [id,name]of [['accounts','Connexions'],['machine','Mac & moteurs'],['games','Réglages des jeux'],['local','Installation locale'],['benchmarks','Benchmarks'],['profile','Mon compte']])nav.append(button(name,()=>{selected=id;query='';gameLimit=30;render(panel);},'settings-tab'+(selected===id?' active':'')));panel.append(nav,content);
const state=getState();
if(selected==='accounts'){
 const heading=el('div','settings-heading');heading.append(el('h2','','Connexions'),button('Assistant de configuration',()=>api.onboard(),'settings-inline-action'));content.append(heading);const search=el('input','settings-search');search.type='search';search.placeholder='Rechercher une plateforme';search.setAttribute('aria-label','Rechercher une plateforme');search.value=query;
 const list=el('div','settings-platforms');content.append(search,list);send('checkServices');
 function draw(){list.replaceChildren();const state=getState(),S=root.PlaymeltServices,active=S.active(state);
 const isOn=p=>p.url?active.includes(p.id):p.id==='steam'?state.libraryStatus?.status==='synced':p.id==='gog'?state.gog?.available===true:state[p.id]?.authenticated===true;
 const shown=platforms.filter(p=>p.name.toLocaleLowerCase('fr').includes(query.toLocaleLowerCase('fr')));
 for(const [title,on] of [['Services détectés',true],['Services à vérifier',false]]){
  const rows=shown.filter(p=>isOn(p)===on);if(!rows.length)continue;
  const head=el('h3','settings-group-title',title);head.append(el('span','settings-group-count',String(rows.length)));list.append(head);
  for(const p of rows){
   const svc=S.list[p.id],row=el('div','settings-platform'+(on?' is-on':'')),icon=el('div','settings-platform-icon platform-icon-'+p.id);
   icon.innerHTML='<svg aria-hidden="true"><use href="#pf-'+(p.id==='geforce'?'geforce':p.id)+'"/></svg>';if(svc){icon.style.setProperty('--lg-a',svc.a);icon.style.setProperty('--lg-b',svc.b);}
   const diagnostic=p.id==='epic'?(state.epic?.storageError||state.epic?.message):p.id==='gog'?state.gog?.message:'';
   const copy=el('div','settings-platform-copy');copy.append(el('strong','',p.name),el('small','',(svc&&!on?svc.tagline:p.detail)+(diagnostic?' · '+diagnostic:'')));
   const auto=getState().services?.[p.id]===true;
   const label=on?(p.url?(auto?'Session détectée':'Ajouté'):p.id==='xbox'?'Session détectée':p.id==='gog'?'Cache local':p.id==='epic'?(state.epic?.credentialStorage==='keychain'?'Connecté · Trousseau':'Session temporaire'):'Connecté'):p.url?'Non connecté':p.id==='steam'?'À vérifier':'À connecter';
   const status=el('span',on?'session-state connected':'session-state',label);
   const actions=el('div','settings-platform-actions');
   if(p.url){
    if(on){actions.append(button('Ouvrir',()=>openLink(p.url),'settings-row-action'),button('Retirer',()=>{S.remove(p.id);api.onServicesChanged?.();draw();},'settings-inline-action'));}
    else{actions.append(button('Se connecter',()=>{S.read().removed.includes(p.id)&&(S.write({...S.read(),removed:S.read().removed.filter(x=>x!==p.id)}));openLink(p.url);},'settings-row-action'));
     if(svc?.detect==='manual'||S.read().removed.includes(p.id))actions.append(button('Ajouter',()=>{S.add(p.id);api.onServicesChanged?.();draw();},'settings-inline-action'));}
   }else actions.append(button(on?'Gérer':p.id==='steam'?'Vérifier':'Connecter',()=>send(p.action),'settings-row-action'));
   row.append(icon,copy,status,actions);list.append(row);
  }
 }
 if(!list.childElementCount)list.append(el('p','settings-description','Aucune plateforme ne correspond.'));}
 root.PlaymeltServices.redraw=()=>{if(list.isConnected)draw();};
 search.addEventListener('input',()=>{query=search.value;draw();});draw();}
if(selected==='machine')renderMachine(content);
if(selected==='games'){
 content.append(el('h2','','Réglages des jeux'));const search=el('input','settings-search');search.type='search';search.placeholder='Rechercher un jeu installé';search.setAttribute('aria-label','Rechercher un jeu installé');search.value=query;const list=el('div','settings-game-list'),more=button('Afficher plus de jeux',()=>{gameLimit+=30;draw();},'discover-more');content.append(search,list,more);
 function draw(){list.replaceChildren();const games=state.games.filter(x=>x.installed&&x.title.toLocaleLowerCase('fr').includes(query.toLocaleLowerCase('fr')));for(const g of games.slice(0,gameLimit)){const row=el('div','settings-game-row'),img=el('img','settings-game-art');img.alt='';root.PlaymeltArtwork.bind(img,[g.imageURL,g.portraitImageURL]);const copy=el('div','settings-game-copy');copy.append(el('strong','',g.title),el('small','',g.platform==='mac'?'Mac natif':g.store==='xbox'?'Xbox Cloud':'Windows · '+(g.requiredRenderer==='d3dmetal'?'DirectX 12':'Moteur automatique')));row.append(img,copy,button('Réglages',()=>api.openGameSettings(g),'settings-row-action'));list.append(row);}if(!games.length)list.append(el('p','settings-description','Aucun jeu installé ne correspond à la recherche.'));more.hidden=games.length<=gameLimit;}
 search.addEventListener('input',()=>{query=search.value;gameLimit=30;draw();});draw();}
if(selected==='local'){
 content.append(el('h2','','Ajouter un jeu local'),el('p','settings-description','Importe un dossier de jeu Windows déjà installé ou une archive ZIP. L’original est conservé.'));
 const flow=el('ol','install-steps');for(const text of ['Choisir le fichier','Vérifier le jeu','Importer dans Playmelt'])flow.append(el('li','',text));content.append(flow);
 const local=state.localImport||{};content.append(button('Choisir un fichier ou un dossier',()=>send('chooseLocalGame'),'settings-row-action primary'));
 if(local.status==='checking')content.append(el('p','settings-description','Analyse des fichiers…'));
 if(local.status==='review'){
 const form=el('form','local-import-review'),nameLabel=el('label','','Nom du jeu'),name=el('input','settings-search');name.value=local.name||'';name.required=true;name.maxLength=160;nameLabel.append(name);const exeLabel=el('label','','Exécutable du jeu'),exe=el('select','settings-search');for(const candidate of local.executables||[])exe.append(new Option(candidate,candidate));exeLabel.append(exe);form.append(el('p','settings-description',`${(local.files||0).toLocaleString('fr-FR')} fichiers · ${((local.bytes||0)/1073741824).toLocaleString('fr-FR',{maximumFractionDigits:1})} Go à copier`),nameLabel,exeLabel);
 const commit=el('button','settings-row-action primary','Importer le jeu');commit.type='submit';commit.disabled=!local.executables?.length;form.append(commit);form.addEventListener('submit',e=>{e.preventDefault();send('installLocalGame',{title:name.value.trim(),executable:exe.value});});if(!local.executables?.length)form.append(el('p','settings-description','Aucun exécutable de jeu identifié. Cet ensemble peut nécessiter une installation Windows.'));content.append(form);
 }
 if(local.status==='installing')content.append(el('p','settings-description','Import en cours. Les fichiers d’origine restent intacts.'),button('Annuler l’import',()=>send('cancelLocalImport'),'settings-row-action'));
 if(local.status==='imported')content.append(el('p','session-state connected',local.title+' a été ajouté à la bibliothèque.'));
 if(local.error)content.append(el('p','discover-warning',local.error));
 const vm=el('section','settings-account'),label=el('label','settings-toggle'),toggle=el('input');toggle.type='checkbox';toggle.checked=state.vmInstallPreference===true;toggle.addEventListener('change',()=>send('setVMInstallPreference',{enabled:toggle.checked}));label.append(toggle,el('span','','Me proposer une VM pour les installateurs Windows'));vm.append(el('h3','','Installateurs .exe et .msi'),label,el('p','settings-description','Pas encore disponible. Aucun installateur n’est lancé sur le Mac.'));if(local.status==='needsVM')vm.append(el('p','discover-warning',local.message));content.append(vm);
}
if(selected==='benchmarks'){content.append(el('h2','','Les performances de tes jeux'),el('p','settings-description','Une mesure est liée au jeu, au Mac, au moteur et aux réglages de la session. Les résultats restent privés avant validation et publication.'));const data=state.benchmarks||{};const control=el('section','settings-account');const toggle=el('input');toggle.type='checkbox';toggle.checked=data.enabled!==false;toggle.addEventListener('change',()=>send('setAutomaticBenchmarks',{enabled:toggle.checked}));const label=el('label','settings-toggle');label.append(toggle,el('span','','Mesurer automatiquement les sessions Windows prises en charge'));control.append(label,el('p','settings-description','Échantillon Metal de 30 secondes. Aucun score global ni résultat de jeu n’est déduit du seul modèle de Mac.'));if(data.running)control.append(el('p','session-state connected','Mesure en cours…'),button('Arrêter la mesure',()=>send('stopBenchmark')));content.append(control);
const check=el('section','settings-account');check.append(el('h3','','Vérifier mes installations'),el('p','settings-description','Contrôle des fichiers, du moteur et des paramètres de lancement. Le résultat ne remplace pas un essai dans le jeu.'),button('Vérifier les jeux installés',()=>send('checkInstalledGames')));for(const row of state.launchDiagnostics||[]){const line=el('div','settings-game-row');line.append(el('strong','',row.title),el('span',row.ready?'session-state connected':'session-state',row.message));check.append(line);}content.append(check);
const sessions=data.sessions||[];if(!sessions.length)content.append(el('div','settings-empty','Aucune mesure pour l’instant. Lance un jeu Windows installé depuis Playmelt.'));
for(const session of sessions){const card=el('section','settings-account');card.append(el('span','discover-kicker','MESURE LOCALE'),el('h3','',session.title),el('p','settings-description',[session.machine?.chip,session.machine?.memoryGB?session.machine.memoryGB+' Go':'',new Date(session.createdAt*1000).toLocaleString('fr-FR')].filter(Boolean).join(' · ')));const result=session.result||{};if(result.status==='measured'){for(const metric of result.groups||[]){const row=el('div','settings-game-row');row.append(el('strong','',Number(metric.presentedFPS).toLocaleString('fr-FR',{maximumFractionDigits:1})+' images/s'),el('span','',`${metric.width} × ${metric.height} · ${Math.round(metric.durationSeconds)} s`));card.append(row);}card.append(el('p','settings-description','Images présentées par Metal. Cette session peut contenir un menu ou un chargement ; elle doit être qualifiée avant publication.'));}else card.append(el('p','settings-description',result.reason==='collecting'?'Identification du jeu ou mesure en cours…':result.reason==='cancelled'?'Mesure arrêtée.':'Résultat non mesuré : aucune série de données exploitable.'));content.append(card);}}

if(selected==='profile'){
 const p=state.profile,card=el('section','settings-account');card.append(el('span','discover-kicker','PROFIL PLAYMELT'),el('h2','',state.player?.name||'Mon profil'),el('p','',`${(p?.points||0).toLocaleString('fr-FR')} points · niveau ${p?.level||1}`),button('Pseudo, avatar et progression',goProfile,'settings-row-action'));content.append(card);
 const a=state.account||{},view=root.PlaymeltAccount.presentation(a),account=el('section','settings-account');
 account.append(el('h3','','Compte et abonnement'),el('strong',view.verified?'session-state connected':'session-state',view.label));
 if(view.signedIn)account.append(el('p','settings-description',a.email));account.append(el('p','settings-description',view.detail));
 const actions=el('div','settings-account-actions');account.append(actions);
 if(view.ready){
  actions.append(button(view.signedIn?(view.active?view.manageLabel:'Choisir une formule'):'Connecter mon compte',()=>view.signedIn?(view.active?send('openPlaymeltAccount'):api.openSubscription()):send('connectPlaymelt'),'settings-row-action primary'));
  if(view.signedIn)actions.append(button('Actualiser mon accès',()=>send('refreshPlaymelt'),'settings-inline-action'),button('Se déconnecter de ce Mac',()=>send('disconnectPlaymelt'),'settings-inline-action'));
  if(view.signedIn&&a.hasPassword===false)actions.append(button('Définir mon mot de passe',()=>send('openPlaymeltAccount'),'settings-inline-action'));
 }
 if(!view.active)actions.append(button('Voir les formules',()=>api.openSubscription(),'settings-inline-action'));
 const activate=button('Activer un code',()=>send('openPlaymeltAccount',{section:'activation'}),'settings-inline-action');activate.disabled=!view.ready;if(!view.active)actions.append(activate);
 if(a.pending)account.append(el('p','settings-device-code',a.userCode||'Connexion en cours…'));if(a.message)account.append(el('p','settings-description',a.message));content.append(account);
 const help=el('section','settings-account');help.append(el('h3','','Aide et informations'));
 for(const [title,path]of [['Support Playmelt','support/'],['Mentions légales','legal/mentions-legales/'],['Conditions de vente','legal/conditions-de-vente/'],['Confidentialité','legal/confidentialite/']]){const link=button(title,()=>openLink('https://7agency.fr/Playmelt/'+path),'settings-inline-action');help.append(link);}content.append(help);
}

}
return {render,showAccount(){selected="profile";}};}
root.PlaymeltSettings={create,platforms};
})(window);
