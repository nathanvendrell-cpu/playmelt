# Prototype PE64 et appels Win64 sur macOS

Ce prototype charge et exécute **uniquement notre petit programme PE synthétique**
dans un hôte macOS x86_64. Il n'utilise ni Wine ni machine virtuelle. Sur Apple
Silicon, le processus x86_64 passe par Rosetta : ce n'est pas une exécution ARM64
native du code Windows. Le prototype n'est pas intégré au bouton Jouer de Playmelt.

## Ce qui est implémenté

`pe_loader.c` prépare une image PE32+ AMD64 en mémoire : validation des plages,
copie des sections et zéro initial, relocalisations DIR64/ABSOLUTE, liaison des
imports nommés ou par ordinal par un resolver explicite, puis permissions par page. La mémoire
est d'abord en lecture/écriture, ensuite les sections de code passent en
lecture/exécution. Aucune page n'est simultanément accessible en écriture et
exécution. Un conflit de permissions entre sections partageant une page est refusé.

`pm_pe_load()` ne lance jamais le point d'entrée. Le harnais séparé `cpu_probe.c`
l'appelle explicitement sur les octets embarqués produits par `probe_fixture.py`.
Il n'accepte aucun chemin d'exécutable. `pm_pe_unload()` rapporte le résultat réel
de `munmap` ; en cas d'échec, le handle reste disponible pour un nouvel essai.

Le chargeur strict accepte les DLL uniquement lorsque leur point d'entrée vaut zéro. Le
catalogue d'exports est copié depuis les octets originaux avant relocalisation
et liaison : noms, ordinaux, trous et forwarders restent distincts. Les adresses
d'exports directs désignent la nouvelle image ; leurs permissions finales sont
exposées, car un export peut désigner des données sans être une fonction.

`pe_modules.c` relie des images déjà chargées et explicitement enregistrées. Il
résout les noms de modules sans tenir compte de la casse, conserve la casse des
symboles et suit les forwarders nommés ou par ordinal avec limites et détection
de cycles. Un module absent peut utiliser le resolver WinAPI fourni par l'hôte ;
un symbole absent d'un module enregistré ne déclenche aucun repli silencieux.
Il n'y a aucune recherche de fichiers, initialisation DLL ni chargement automatique.
Les images sont empruntées : décharger les clients, retirer le module du registre,
puis décharger son image. Cette API est confinée au thread appelant et ne gère pas
les références entre modules pendant une exécution concurrente.

`winapi_subset.c` fournit sept fonctions via l'ABI Microsoft x64, uniquement pour
les noms précis de `kernel32.dll` ou `kernelbase.dll` :

| Fonction | Comportement actuel |
|---|---|
| `SetLastError`, `GetLastError` | Valeur distincte pour chaque thread hôte. Aucun TEB Windows n'est créé. |
| `GetCurrentProcessId` | Identifiant du processus hôte réel. |
| `QueryPerformanceCounter`, `QueryPerformanceFrequency` | Horloge continue macOS convertie en comptes ; fréquence exposée de 1 milliard de comptes/s, sans promesse de précision à la nanoseconde. |
| `GetTickCount64` | Temps de cette horloge en millisecondes, incluant la veille. |
| `GetSystemTimeAsFileTime` | Temps UTC dans le format Windows, unités de 100 ns depuis 1601. |

Dans ce resolver WinAPI, les noms inconnus et les imports par ordinal sont refusés. Aucun succès fictif,
recherche de DLL, téléchargement ou `dlopen` n'est utilisé.

`winapi_modules.c` ajoute un resolver optionnel pour `GetModuleHandleA`,
`GetModuleHandleW` et `GetProcAddress`. Les handles viennent exclusivement des
images enregistrées ou des tables de services hôtes explicitement déclarées.
Les noms exacts, ordinaux, données et forwarders sont résolus avec le même registre
fermé. Un contexte lié au thread protège leur durée de vie ; il ne peut pas être
détruit pendant son utilisation. Les erreurs alimentent le `LastError` existant.
Le resolver initial des sept fonctions reste utilisable seul.

Les noms de modules sont limités aux basenames ASCII ; `W` accepte leur encodage
UTF-16 ASCII, sans conversion Unicode générale. Aucun `LoadLibrary`, `FreeLibrary`,
compteur de références Windows, API set ou chargement de dépendance n'est simulé.

Une API séparée `pm_pe_load_synthetic_dll` autorise un point d'entrée non nul
uniquement pour nos fixtures embarquées. Elle prépare l'image sans l'appeler.
`pm_pe_synthetic_dll_attach` et `detach` appellent explicitement ce point via l'ABI
x64 ; un attach refusé déclenche son nettoyage. Le handle et le thread d'origine
sont requis. Double appel, réentrance et libération pendant l'attachement sont
refusés. Cette expérimentation ne fournit ni verrou global de chargement Windows,
ni notifications de threads, CRT, TLS ou gestion d'exception. Un appelant C peut
toujours fournir des octets dangereux : cette API n'est pas une sandbox.

## Preuve CPU reproductible

Depuis la racine du dépôt, sans aucun jeu :

```sh
python3 -B research/windows_native/loader/run_cpu_probe.py
```

Le script fabrique une image PE de 3 584 octets, compile l'hôte Mach-O x86_64 à
priorité réduite, l'exécute dans un processus distinct, puis nettoie son dossier
temporaire sous `Products.noindex`. Les commandes sont bornées dans le temps et
leurs groupes de processus sont suivis pour le nettoyage.

La fixture vérifie le pointeur absolu après déplacement de l'image, l'alignement
de pile et les appels Win64, le PID, une erreur de thread choisie, QPC/QPF,
TickCount64 encadré par les lectures QPC et FILETIME encadré par l'heure UTC hôte.
La sortie JSON distingue `syntheticPEExecuted`, `rosettaTranslated`,
`relocatedFromPreferredBase`, `gameExecuted`, `wineUsed` et `imageUnmapped`.
Ce n'est ni un test de jeu ni une comparaison de performances avec Windows.

Un second harnais vérifie la liaison entre deux PE synthétiques :

```sh
python3 -B research/windows_native/loader/run_module_probe.py
```

Le client et sa DLL font chacun 3 584 octets. Le client appelle une fonction par
nom, une autre par ordinal, un forwarder vers le PID hôte et un forwarder vers
l'ordinal de la DLL ; il lit aussi un export de données. Le harnais contrôle les
cinq pointeurs IAT exacts, les résultats, les deux relocalisations, le refus d'un
module absent et d'un trou d'ordinal, puis le retrait et la libération des images.
Aucun `DllMain` n'est exécuté. Les modules testés sont entièrement écrits dans
ce dépôt ; aucune DLL d'un jeu ou de Windows n'est fournie à ces harnais.

Deux autres harnais embarqués isolent les nouvelles fonctions et le cycle DLL :

```sh
python3 -B research/windows_native/loader/run_winapi_call_probe.py
python3 -B research/windows_native/loader/run_dll_lifecycle_probe.py
```

Le premier appelle réellement les trois fonctions depuis un PE, puis utilise les
adresses obtenues. Le second exécute quatre notifications de DLL synthétiques,
vérifie les arguments, l'ordre attach/detach, le refus d'attach et les refus de
réentrance, mauvais thread et libération prématurée. Les images sont libérées
avant la sortie. Ces commandes compilent et s'exécutent successivement à priorité
réduite ; elles n'acceptent aucun chemin d'exécutable externe.

Les suites `test_pe_loader.c` et `test_winapi_subset.c` couvrent séparément les
rejets, les permissions, les allocations/libérations et les fonctions système.
La première utilise des doubles des appels mémoire, avec vérification
AddressSanitizer/UndefinedBehaviorSanitizer. Le harnais intégré utilise les vrais
appels mémoire de macOS. `test_pe_modules.c` couvre le registre avec des catalogues
simulés ; `test_probe_lifecycle.py` vérifie aussi le nettoyage d'un enfant qui
ignore SIGTERM après la sortie de son parent. Aucun GPU, modèle d'inférence ou shader n'est lancé.

## VirtualProtect dans des allocations détenues

`winapi_memory.h/.c` ajoute un resolver optionnel pour `VirtualProtect`, sans
modifier le chargeur PE ni les protections des jeux. L'API host crée ses propres
allocations anonymes RW : huit régions au maximum, 1 Mio par région et 4 Mio par
contexte, backing d'alignement guest compris. Il n'existe aucune inscription de
mémoire empruntée. Le contexte doit être lié explicitement au thread appelant ;
les mutations par les API hôtes restent interdites tant qu'il est lié. Les deux
formes guest de `VirtualAlloc`/`VirtualFree` décrites plus bas ont leur propre
contrat. La sortie du thread libère la liaison, puis le propriétaire doit détruire
le contexte. Une erreur de `munmap` conserve la région en quarantaine pour réessayer.

Chaque demande doit tenir dans une seule allocation d'origine. Les pages
englobantes sont modifiées par le vrai `mprotect` de macOS. Les modes disponibles
sont NOACCESS, R, RW et RX ; execute-only, RWX, COW, GUARD et les autres
modificateurs sont refusés. La sortie `oldProtect` reçoit le mode antérieur de la
première page. Elle doit désigner quatre octets dans une **autre allocation
détenue**, dont toutes les pages concernées sont RW. Les piles ordinaires et les
pointeurs étrangers ne sont pas acceptés. Le paramètre C est un `void*` pour ne
pas imposer un faux alignement DWORD ; les sorties non alignées sont copiées par
octets via `memcpy`, avec la même convention d'appel Windows x64.

Un échec OS de `mprotect` peut laisser certaines permissions modifiées. Toute
l'allocation cible est alors mise en quarantaine : elle ne peut plus servir de
cible ni de sortie, même sur une page apparemment inchangée. Son ancien suivi
des protections n'est plus une preuve. La sortie reste intacte ; le propriétaire
doit délier puis libérer cette allocation. Aucun rollback implicite ni succès
fondé seulement sur des métadonnées n'est annoncé. Les erreurs Win32 utilisées
et les limites de ce sous-ensemble sont détaillées dans le header.

La validation initiale a passé **415 contrôles** avec ASan/UBSan : protections macOS
observées, arrondis et franchissements de pages, modes antérieurs différents,
sorties non alignées, limites, mauvais thread, refus W+X, échecs OS et nettoyage.
Un double rend réellement une première page inaccessible puis échoue pour
vérifier la quarantaine sans accès à cette page. Depuis la racine du projet :

```sh
(
  set -eu
  scratch=$(mktemp -d Products.noindex/virtualprotect-tests.XXXXXX)
  trap 'rm -rf -- "$scratch"' EXIT
  nice -n 15 xcrun clang -std=c11 -Wall -Wextra -Werror -Wstrict-prototypes \
    -O1 -g -arch x86_64 -mmacosx-version-min=15.0 \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I research/windows_native/loader \
    research/windows_native/loader/test_winapi_memory.c \
    research/windows_native/loader/winapi_subset.c \
    -o "$scratch/test"
  UBSAN_OPTIONS=halt_on_error=1 nice -n 15 "$scratch/test"
)
python3 -B research/windows_native/loader/run_memory_probe.py
```

Le second harnais embarque uniquement notre PE synthétique et appelle l'adresse
réelle de `VirtualProtect` via son IAT. Trois points de contrôle observent les
permissions macOS après passage RX, retour RW et refus RWX. Les pages détenues
ainsi protégées ne contiennent aucun code exécuté. Le PE de test utilise Rosetta
sur Apple Silicon ; aucun jeu, DLL Apple, shader, Steam, Wine ou travail GPU n'est
lancé. Les logs et hashes des sources compilées sont conservés localement dans
`work/winapi-memory-tests.log` et `work/winapi-memory-source-hashes.json` ; les
deux premiers essais négatifs restent dans le log. Cela ne qualifie ni la mémoire
virtuelle complète de Windows, ni les exceptions, ni DirectX 12.

## NtQueryVirtualMemory pour les régions connues

Le même module mémoire fournit maintenant `NtQueryVirtualMemory` via `ntdll.dll`,
avec ses six arguments Windows x64. Seuls le pseudo-handle du processus courant
et `MemoryBasicInformation` sont acceptés. La réponse de 48 octets décrit les
pages détenues, depuis la page interrogée vers les pages suivantes ayant les
mêmes protections, sans franchir leur allocation d'origine. La cible n'est pas
déréférencée, même lorsqu'elle est NOACCESS.

Les deux sorties éventuelles sont validées ensemble : seules des zones détenues
RW sont acceptées, leurs chevauchements sont refusés et les paddings sont mis à
zéro. Un refus préserve les deux sorties et `LastError`. Les codes NTSTATUS et
leur ordre sont une politique documentée de ce sous-ensemble. Il n'explore ni
les régions libres, ni les images PE, ni les piles, ni un autre processus. Une
région mise en quarantaine reste refusée ; aucune permission incertaine n'est
présentée comme connue.

La validation initiale a passé 633 contrôles CPU ASan/UBSan, ainsi que les 415
contrôles de `VirtualProtect`. Le harnais ci-dessous exécute cinq appels depuis un PE
synthétique, dont les arguments cinq et six placés sur la pile, puis compare
les résultats à vingt observations des protections Mach des régions détenues :

```sh
python3 -B research/windows_native/loader/run_memory_query_probe.py
```

Les preuves sont conservées dans `work/ntquery-memory-probe.json` et
`work/ntquery-memory-tests-initial.log`. Aucun jeu, autre exécutable ou composant
Apple n'est accepté par ce harnais ; toutes ses allocations et processus sont
nettoyés après exécution.

## Allocation et libération demandées par le PE

Les imports `VirtualAlloc` et `VirtualFree`, observés dans DXGI, disposent d'un
sous-ensemble réel à quatre et trois arguments Windows x64. Seules ces formes
sont admises, dans le contexte mémoire lié au thread appelant :

```c
VirtualAlloc(NULL, taille, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
VirtualFree(base_guest_exacte, 0, MEM_RELEASE);
```

Une demande de 1 octet à 1 Mio produit une fenêtre anonyme initialement à zéro,
arrondie aux pages de l'hôte et alignée sur 64 Kio. Le backing complet est réservé
en PROT_NONE, puis seule la fenêtre devient RW. Les marges restent inaccessibles
et exclues de `VirtualProtect` et `NtQueryVirtualMemory`. Le backing est conservé
entier jusqu'à sa libération : aucun découpage intermédiaire fragile. Le plafond
de 4 Mio inclut les marges et les éventuels nettoyages différés, avec huit slots
au maximum. Il s'agit de mémoire virtuelle CPU, sans réservation de VRAM ni
promesse sur la mémoire physique résidente.

`VirtualFree` ne libère que les bases guest publiées par ce même contexte. Une
adresse intérieure, inconnue, déjà libérée ou issue de l'allocateur hôte est
refusée. Les autres formes Windows restent refusées : adresse imposée,
réservation seule, commit seul, décommit, reset, grandes pages et allocation
exécutable. La granularité des pages reste celle de l'hôte ; aucune émulation
générale des pages Windows n'est annoncée.

Une allocation dont la protection échoue est nettoyée. Si ce nettoyage échoue
aussi, elle reste comptée dans un slot interne en quarantaine, sans base publiée,
jusqu'à la destruction du contexte après détachement. Une libération échouée
conserve le backing, le budget et la base pour réessayer ; les autres usages de
la région sont refusés entre-temps. Aucun succès n'est renvoyé pour une opération
OS échouée. Les succès préservent `LastError` ; le header définit les codes de
refus propres à ce sous-ensemble.

Le runner suivant compile et exécute successivement cinq suites CPU ASan/UBSan
à priorité réduite, puis notre seul PE embarqué :

```sh
python3 -B research/windows_native/loader/run_allocation_probe.py
```

Le 26 octobre 2026, 1 711 contrôles ont passé : 419 protection, 633 query,
318 allocation/libération, 109 collisions et 232 résolution commune. Le compteur
d'allocation peut varier selon les marges effectivement présentes. La sonde a
vérifié une demande de 37 octets, 4 096 octets initialement à zéro, une base
alignée sur 64 Kio, des écritures et lectures par le PE, puis les états Mach
RW, R et absent après libération. `VirtualAlloc` passe par l'IAT et l'adresse
de `VirtualFree` obtenue par `GetProcAddress` est vérifiée avant son appel.
Les requêtes à six arguments et les canaris des sorties sont également contrôlés.

Les pages allouées ne sont jamais exécutées. Le runner refuse les arguments
externes, nettoie ses groupes de processus et son dossier temporaire, et vérifie
les hashes des 25 sources avant/après. La preuve complète de cette exécution est
`work/virtual-allocation-proof-attempt1.log`. Aucun jeu ni composant Apple n'a été
chargé ; ce résultat ne valide pas le chargement de DXGI ou de DirectX 12.

## Événements Windows anonymes sur CPU

`winapi_events.c` fournit un sous-ensemble de `CreateEventExA`, `SetEvent`,
`ResetEvent`, `WaitForSingleObject` et `CloseHandle`, cinq imports observés dans
DXGI. Les arguments réellement employés par cette DLL restent à inspecter ;
ces imports seuls ne prouvent pas qu'elle peut utiliser ce sous-ensemble.

Le contexte possède au plus seize objets anonymes, événements et sémaphores
confondus, et accepte huit threads hôtes
explicitement liés. Aucun thread Windows n'est créé. Les handles sont des
jetons opaques non déréférencés et non réutilisés pendant la vie du module hôte.
Les handles périmés, étrangers au contexte ou d'un autre type sont refusés.
Le propriétaire doit joindre ses threads et sérialiser la destruction avec
toute tentative de liaison ; les pointeurs C du contexte doivent rester valides.

Seuls les événements sans nom ni attributs de sécurité sont acceptés. Les flags
permettent l'état initial signalé et le réarmement manuel. Les droits sont limités
à `EVENT_MODIFY_STATE` et `SYNCHRONIZE`, vérifiés pour chaque opération ;
`EVENT_ALL_ACCESS`, les ACL et les autres formes restent refusés.

L'attente utilise une condition pthread et une échéance monotone fixe, sans
polling. Le délai admis va de zéro à 100 ms ; les valeurs supérieures et
`INFINITE` échouent explicitement. L'ordonnanceur peut retarder la reprise :
ce plafond ne constitue pas une garantie de temps réel. Chaque attente reçoit
son propre signal de réveil : un événement automatique en libère une, un
événement manuel libère les attentes en cours et reste signalé jusqu'à Reset.
Reset n'efface pas un réveil déjà attribué. Un appel sans attente ne peut pas
consommer celui d'un autre thread.

Fermer le handle exact utilisé par une attente échoue avec `ERROR_BUSY` et le
conserve. Un autre alias du même objet peut être fermé pendant cette attente.
Les échecs OS ne deviennent pas des succès logiques ; les ressources
dont la destruction échoue restent disponibles pour nettoyage. Une destruction
partielle du contexte interdit toute nouvelle liaison jusqu'au nettoyage complet.
L'annulation pthread différée est suspendue pendant les invariants puis rétablie après
retrait du waiter et déverrouillage. L'annulation asynchrone reste hors contrat.
La sortie du thread retire sa liaison, sans détruire les événements du contexte.

```sh
python3 -B research/windows_native/loader/run_events_probe.py
```

Le 26 octobre 2026, ce runner a passé 944 contrôles ASan/UBSan : 460 sur les
événements, 207 sur les collisions entre fournisseurs et 277 sur la résolution
commune. Le compteur des événements peut varier selon l'ordonnancement du harnais.
Les tests couvrent notamment les signaux attribués avant Reset, deux signaux
successifs, les réveils parasites, les droits, les limites, l'annulation différée
et les échecs OS. Un broadcast de test réveille réellement les threads puis
renvoie une erreur pour vérifier qu'aucun signal logique n'a été publié.

Le PE synthétique appelle les cinq fonctions ; les quatre adresses obtenues par
`GetProcAddress` sont vérifiées avant appel. Une observation autour de la vraie
attente Darwin confirme qu'un pthread hôte ne peut émettre le signal qu'après
la libération atomique du mutex par cette attente. Le thread est joint avant
destruction du contexte. La sonde mémoire précédente est également repassée,
avec six observations Mach. Les cinq compilations sont séquentielles, à priorité
réduite ; les 29 empreintes, résultats, temporaires et groupes de processus sont
consignés dans `work/winapi-events-proof-attempt1.log`. Ces preuves restent CPU
et synthétiques, sans qualification d'un composant graphique ou d'un jeu.

## Sémaphores anonymes dans le même contexte

`CreateSemaphoreExA` et `ReleaseSemaphore` utilisent le même registre de handles
que les événements. Le premier reçoit ses six arguments selon l'ABI Windows x64.
La création accepte seulement des attributs et un nom nuls, des flags nuls,
les droits MODIFY_STATE/SYNCHRONIZE et des compteurs signés 32 bits : maximum
strictement positif, compteur initial compris entre zéro et ce maximum.
Ces formes sont des choix du prototype ; les paramètres employés par DXGI ne
sont pas connus.

Une attente réussie consomme un permis. Release exige un incrément positif et
vérifie d'abord qu'il ne dépasse pas `maximum - compteur`, même si des threads
attendent déjà. Un dépassement échoue avec `ERROR_TOO_MANY_POSTS` sans mutation.
Les permis sont ensuite attribués aux attentes, puis le surplus reste disponible.
Un permis attribué ne peut pas être pris par un nouvel appel sans attente. Le
travail est borné aux huit tickets, y compris pour un compteur `INT32_MAX` :
aucune allocation ni boucle proportionnelle au nombre de permis.

La sortie facultative `previousCount` doit être nulle ; toute autre adresse est
refusée sans déréférence ni modification. Set/Reset refusent les handles de
sémaphore ; Release refuse ceux d'événement. Wait et Close acceptent les deux
types. Les limites de délai, droits, annulation différée, fermeture pendant une
attente et nettoyage après échec restent celles du contexte existant. Un échec
de broadcast ne publie ni permis ni réveil. Aucun droit supplémentaire ni attente
infinie n'est activé.

```sh
python3 -B research/windows_native/loader/run_semaphore_probe.py
```

Le 26 octobre 2026, 1 352 contrôles ASan/UBSan ont passé : 393 sémaphores,
457 événements en régression, 207 collisions et 295 résolution commune. Les
compteurs des tests concurrents peuvent varier selon leur ordonnancement.
La suite vérifie notamment Release(3) avec deux attentes : deux permis attribués
et un seul permis disponible à un autre appel, sans vol des réveils déjà accordés.

La sonde PE appelle réellement la création à six arguments, vérifie trois
adresses dynamiques avant appel et attend un permis libéré par un pthread hôte.
Elle contrôle ensuite la consommation des permis, le dépassement refusé et la
fermeture. La sonde d'événements est également repassée. Les six compilations
sont séquentielles, à priorité réduite ; les deux threads de signalisation sont
joints dans leurs sondes respectives. Les trente empreintes et résultats sont
dans `work/winapi-semaphore-proof-attempt1.log`.

Le générateur avait d'abord refusé une fixture de 532 octets de code pour une
capacité de 512 ; ce refus avant compilation est conservé dans
`work/semaphore-fixture-negative-attempt1.json`. Des encodages x64 équivalents
plus courts ont corrigé la taille sans agrandir le fichier PE ni sa section.
Ces preuves ne chargent aucun composant Apple et ne qualifient aucun jeu.

## Dupliquer les handles sans dupliquer leur objet

`DuplicateHandle`, également importé par DXGI, utilise sept arguments Win64.
Le contexte distingue désormais seize objets de synchronisation et trente-deux
handles au maximum. Chaque handle possède ses droits et ses attentes en cours ;
l'événement ou le sémaphore partagé conserve son état, ses réveils attribués et
son compteur de références. Fermer un alias laisse les autres utilisables.
La dernière fermeture ne retire l'objet qu'après destruction réussie de la
condition pthread ; un échec conserve la référence pour une nouvelle tentative.

Seuls les deux pseudo-handles de processus courant `-1` sont acceptés, avec un
événement ou sémaphore du contexte courant et `inherit = FALSE`. L'option
`DUPLICATE_SAME_ACCESS` ignore les droits demandés et recopie ceux du handle
source. Sans cette option, les droits peuvent seulement être réduits, jusqu'à
zéro pour un handle uniquement fermable. L'extension de droits, les handles de
processus ou de threads, l'héritage et les transferts entre processus restent
hors contrat.

La sortie doit désigner huit octets accessibles en écriture dans une seule
allocation détenue par le contexte mémoire lié au thread. Les sorties non
alignées sont acceptées ; piles, images PE, pointeurs inconnus, pages protégées
et allocations en quarantaine sont refusés avant toute écriture. Cette exigence
est une limite du prototype, pas une propriété de l'API Windows. Aucun contexte
mémoire n'est lié automatiquement par l'appel.

`DUPLICATE_CLOSE_SOURCE` est refusé sans fermer la source : sa sémantique Windows,
qui ferme même en cas d'erreur, n'est pas implémentée. Les autres refus préservent
également la sortie, les handles et les références. Les droits plus larges que
ceux de la source sont refusés, même si Windows peut les autoriser dans certains
cas. Les valeurs réellement utilisées par DXGI ne sont toujours pas connues.

```sh
python3 -B research/windows_native/loader/run_duplicate_probe.py
```

Le 26 octobre 2026, 1 881 contrôles ASan/UBSan ont passé : 79 sorties mémoire,
436 duplication, 393 sémaphores, 462 événements, 207 collisions et 304 résolution
commune. Les compteurs concurrents peuvent varier selon l'ordonnancement. Deux
alias attendent simultanément, sur un événement automatique puis un sémaphore :
leurs compteurs restent distincts, leurs réveils partagés ne peuvent être volés,
et un troisième alias peut être fermé pendant ces attentes. Les tests couvrent
aussi les quotas séparés, les droits nuls ou réduits, les sorties non alignées
traversant une page, la quarantaine mémoire et les échecs de publication ou de
dernière fermeture.

Le PE de 3 584 octets appelle les sept arguments, avec les trois derniers sur la
pile Win64. L'adresse dynamique est contrôlée avant appel ; la sortie se trouve
dans une allocation détenue, avec canaris sur toute la page. L'alias partage
l'état de l'événement et reste utilisable après fermeture de la source. Les
sondes PE des événements et sémaphores ont également passé. Les neuf compilations
sont séquentielles à `nice 15`. Les 36 empreintes et résultats sont conservés dans
`work/winapi-duplicate-proof-attempt2.log` ; le contrôle des processus, temporaires
et du binaire installé est dans `work/winapi-duplicate-root-verification.json`.

Le premier essai, arrêté sur un diagnostic du bac à sable refusant `setpriority`
avant tout test, est conservé dans `work/winapi-duplicate-proof-attempt1.log`.
La reprise avec l'autorisation d'abaisser la priorité a terminé sans diagnostic.
Aucun composant Apple ni jeu n'a été exécuté ; l'application installée est inchangée.

## Résolution commune des fonctions déjà disponibles

`winapi_combined.c` rassemble les sept fonctions de base, les trois fonctions de
modules, les quatre fonctions mémoire et les huit fonctions de synchronisation.
Le résolveur ne crée aucun stub.
Les requêtes doivent désigner un nom exact, avec ordinal zéro et sans recherche
par ordinal. `NtQueryVirtualMemory` appartient seulement à `ntdll.dll` ; les vingt et une
autres fonctions appartiennent à `kernel32.dll` ou `kernelbase.dll`.

Les fournisseurs existants peuvent exposer la même fonction de base. Le
résolveur commun vérifie que leurs adresses concordent ; des réponses divergentes
ou incohérentes sont refusées, avec adresse de sortie nulle. Les noms inconnus,
les chemins et les API sets restent refusés. `GetProcAddress` utilise ce même
résolveur seulement après inscription explicite des trois tables de services
hôtes. Ces handles sont des tokens opaques, pas de fausses DLL chargées.

Un PE inscrit garde priorité sur le service hôte : son export manquant ne
déclenche aucun remplacement. Les contextes de modules, de mémoire et d'événements restent
liés séparément au thread. Chaque appelant doit suivre ses bindings réussis,
libérer seulement ceux qu'il a acquis et préserver tout contexte antérieur.
Le premier binding réussi d'un contexte de modules scelle ses inscriptions,
même si un binding mémoire échoue ensuite : ce n'est pas une transaction.
Résoudre une adresse ne suffit pas à rendre son appel opérationnel sans le
contexte requis. Les limites de chaque API, notamment la mémoire détenue,
restent identiques.

Le runner séquentiel ci-dessous vérifie d'abord les refus de collisions avec
des fournisseurs simulés, puis le raccordement aux fournisseurs réels, la
recherche dynamique et les bindings partiels. Les
deux suites sont instrumentées ASan/UBSan. Il exécute ensuite notre seul PE
embarqué : imports de modules statiques, recherche de deux adresses mémoire
par `GetProcAddress`, vérification exacte de ces adresses avant leur appel,
deux `VirtualProtect` et deux `NtQueryVirtualMemory` à six arguments.

```sh
python3 -B research/windows_native/loader/run_combined_probe.py
```

La sonde compare six observations Mach : la première page passe de RW à RX
puis RW, la seconde reste RW. Elle vérifie aussi les champs NT, `LastError`,
les paddings et les canaris des sorties. Aucune de ces pages de données n'est
exécutée. Seul l'appel à l'entrée PE générée est exempté du contrôle UBSan des
métadonnées de type de fonction, absentes de cette entrée ; aucune exclusion
globale. Les adresses disponibles sont couvertes par les tests de résolution,
sans prétendre que la sonde a appelé toutes les fonctions. Commandes, hashes, résultats
et nettoyage sont consignés dans `work/winapi-combined-proof.log`.

## Reconstruction bornée d'une frame x64

`x64_unwind.c` calcule une seule frame appelante dans une copie de contexte. Il
utilise une projection RVA entièrement lisible, un catalogue complet déclaré
par l'hôte et un instantané de pile borné. Il ne déréférence jamais les adresses
logiques RIP/RSP. Tous les enregistrements du catalogue sont validés, même ceux
qui ne contiennent pas le PC ; l'absence d'entrée ne devient une fonction leaf
que si l'hôte l'autorise explicitement pour du code qu'il connaît.

Le contrat accepte uniquement V1, flags zéro, sans registre de frame, avec
`PUSH_NONVOL`, `ALLOC_SMALL` et les deux formes de `ALLOC_LARGE`. Il traite le
prologue partiel, le corps et les suffixes d'épilogue canoniques ADD RSP/POP/RET.
À la frontière du prologue, il examine d'abord l'épilogue. Un épilogue plausible
mais non reconnu, un préfixe inhabituel, une métadonnée invalide ou une pile
tronquée provoque un refus. Les sorties restent inchangées, y compris si l'échec
survient après la lecture des sauvegardes, lors de la lecture du retour.

Ce module utilise l'ABI de l'hôte : il n'expose pas `RtlVirtualUnwind`, ne produit
pas un `CONTEXT` Windows complet et ne gère pas SEH. Il reconstruit RSP/RIP et les
registres généraux non volatils sauvegardés ; les registres volatils sont seulement
conservés, et SIMD/RFLAGS/TEB restent absents. Aucun signal, gestionnaire, reprise
du PC reconstruit ou chargement de DLL réelle n'est ajouté. L'hôte doit toujours
attester du code conforme à l'ABI et d'un PC sur une frontière d'instruction.

Les 863 contrôles inertes ASan/UBSan passent : prologues partiels, corps,
épilogues, bornes, métadonnées malformées et conservation des sorties après
échec. La sonde PE distincte capture deux frames réelles dans le corps de
fonctions synthétiques, sous Rosetta : 64 et 320 octets de pile, allocation
petite et grande, sauvegardes RBX/R12. L'appelant enregistre son RSP et son
adresse de retour attendue avant CALL, puis fixe ses sentinelles ; l'oracle
est donc indépendant du calcul d'unwind. Le résultat reconstruit est seulement
comparé, jamais exécuté.

```sh
python3 -B research/windows_native/loader/run_unwind_probe.py
```

La copie de pile intervient dans le callback : le shadow space de 32 octets
peut déjà avoir changé, mais les sauvegardes et le retour employés se trouvent
au-dessus. Ce n'est pas une capture atomique de toute la pile. Les prologues et
épilogues ont des preuves inertes ; les captures exécutées portent uniquement
sur le corps. La sonde est instrumentée ASan/UBSan ; seul le trampoline qui
appelle l'entrée PE générée est exempté du contrôle de métadonnées de type de
fonction, absentes de ce code machine. Aucun contrôle n'est désactivé globalement.
Les commandes, hashes et résultats restent dans `work/x64-unwind-tests.log`,
`work/x64-unwind-probe-final.log` et `work/x64-unwind-source-hashes.json`.

## Catalogue embarqué dans un PE synthétique

`pm_pe_load_synthetic_unwind_exe` est un chemin de recherche distinct, réservé
à nos EXE embarqués. Il exige une attestation explicite de catalogue complet et
un répertoire d'exception non vide. Une table `.pdata` ne prouve pas à elle seule
cette complétude. Le chargeur par défaut et le chemin DLL synthétique conservent
leur refus du répertoire d'exception ; aucune DLL réelle n'est admise ici.

Le catalogue vient des enregistrements `RUNTIME_FUNCTION` de l'image. Le même
validateur privé sert au chargeur et au dérouleur x64, sans nouvelle dépendance
de liaison pour les anciens utilisateurs du chargeur. Les bornes restent
étroites : image de 1 Mio, 4 096 entrées triées et sans chevauchement, V1 sans
flags ni registre de frame, trois opérations supportées. L'entrée de l'EXE doit
être couverte. Les fonctions leaf sans entrée restent désactivées.

Le code et les métadonnées doivent provenir du fichier et rester respectivement
RX et R, jusqu'au niveau des pages hôtes. Cela refuse notamment une métadonnée R
qui partagerait une page inscriptible. Les relocalisations et les écritures IAT,
y compris leurs zéros terminaux, ne peuvent toucher les plages de code ou de
métadonnées protégées. Le catalogue, les sections et les permissions sont validés
avant la création du mapping. Les collisions avec une écriture sont refusées
avant cette écriture, pendant les étapes de correction du mapping ; une collision
IAT tardive peut donc survenir après d'autres résolutions. Le nettoyage suit alors
le chemin d'échec normal.

Après les corrections autorisées, le chargeur copie les plages protégées depuis
le mapping réel et les revalide. Le reste de la projection est zéro ; cette vue
ne représente pas toute la mémoire du programme. `pm_pe_unwind_view` fournit une
vue empruntée liée au handle d'origine, au mapping et au thread de chargement.
Elle expire lors du déchargement. Un échec de `munmap` conserve les ressources
du handle vivant pour réessayer ; une vue déjà libérée n'est jamais réutilisable.

Ce raccordement ne déclenche aucun gestionnaire d'exception, n'enregistre aucune
table auprès d'un OS Windows et ne reprend aucun contexte reconstruit. Il fournit
au dérouleur borné les métadonnées de notre exécutable synthétique chargé.

```sh
python3 -B research/windows_native/loader/run_embedded_unwind_probe.py
```

Ce runner séquentiel passe 1 987 contrôles du chargeur existant, 863 du dérouleur
et 583 du nouveau chemin, sous ASan/UBSan. Les négatifs comprennent les pages
hôtes de 16 Kio simulées, les chevauchements partiels de corrections, les zéros
terminaux IAT, les handlers refusés, les handles copiés encore vivants, les
threads étrangers et les échecs d'allocation, protection et déchargement.

La sonde trouve trois entrées dans le répertoire d'exception intact du PE et
reconstruit deux frames réellement capturées, avec les oracles pré-CALL décrits
plus haut. Elle n'exécute ni contexte reconstruit ni gestionnaire. La petite
régression DLL existante passe également ses quatre notifications synthétiques,
dans sa configuration originale non instrumentée, distincte des suites ASan/UBSan.
Les preuves sont `work/embedded-unwind-proof-attempt1.log` et
`work/embedded-unwind-source-hashes.json` ; aucun jeu ou composant Apple n'est
chargé par ce runner.

## Ce qui manque pour Mortal Shell II

Le lecteur voisin `../pe_unwind.py` décode les tables d'exception AMD64 V1
sans charger les fichiers ni exécuter leurs gestionnaires :

```sh
python3 -B research/windows_native/pe_unwind.py /chemin/explicitement-choisi.dll
python3 -B research/windows_native/test_pe_unwind.py
```

Il distingue les slots d'opérandes des opérations, borne les chaînes et les
sorties, et refuse les versions, registres ou opérations hors de son contrat.
Les données propres aux gestionnaires restent opaques ; les tables dynamiques
ne sont pas inspectées. Le décodage ne valide ni le code machine correspondant,
ni la restauration d'un contexte, ni la gestion des exceptions Windows.

Le sous-ensemble est volontairement étroit : fichier de 16 Mio maximum, image de
64 Mio maximum, 32 sections, 1 024 symboles importés, 4 096 relocalisations.
Par défaut, seuls les répertoires export, import, relocalisation et IAT sont acceptés. Le
registre ne charge que des images déjà préparées. L'initialisation opt-in des
fixtures ne constitue pas un cycle de vie compatible avec des DLL Windows réelles.
TLS de l'exécutable, gestion complète des exceptions/unwind Windows, CRT, ressources, DLL
chargées à la demande, API sets, mémoire virtuelle complète/processus/threads Windows, Win32/NT,
audio, entrées, Steamworks et D3D12 ne sont pas implémentés. Certains sont refusés
explicitement dès le chargement. La fixture n'a pas été qualifiée sur Windows.

Ce code est un socle de recherche, pas un lanceur universel ni un environnement
sandboxé pour des exécutables non fiables. Le bouton Windows de Playmelt reste
indisponible et sa protection des rendus reste indépendante du prototype.
L'exécutable de Mortal Shell II n'a été ni chargé ni lancé.

## Dépendances observées le 25 octobre 2026

Lecture statique des quatre DLL PE du composant Apple 4.0 beta 3 déjà importé :
`d3d12.dll`, `d3d12core.dll`, `dxgi.dll` et `d3d11.dll`. Elles n'ont pas été chargées
en mémoire exécutable ni initialisées. L'inspecteur relève 55 couples DLL/symbole
distincts ; les empreintes et tables complètes sont conservées localement dans
`work/apple-pe-static-dependencies.json`.

`d3d12.dll` importe notamment `GetModuleHandleA/W`, `GetProcAddress`, `LoadLibraryA`,
`VirtualProtect`, `RaiseException` et `NtQueryVirtualMemory`. Les wrappers
`GetModuleHandleA/W` et `GetProcAddress` existent pour le registre fermé, et
`VirtualProtect` pour les seules allocations détenues décrites ci-dessus.
`NtQueryVirtualMemory` interroge ces seules allocations connues. Le chargement
automatique, `RaiseException` et la mémoire virtuelle générale Windows restent
absents. Les quatre DLL ont un point d'initialisation non nul et un répertoire
d'exceptions ; le chargeur actuel les refuse donc volontairement. DXGI dépend aussi
des fenêtres, écrans, événements, threads, sémaphores et du registre Windows.

La résolution de modules et l'initialisation synthétique ont maintenant des
preuves CPU distinctes. Il reste notamment la gestion complète des exceptions/unwind Windows, la mémoire virtuelle générale,
les synchronisations et le pont graphique réellement utilisés par ces composants. Ces
imports ne décrivent pas les dépendances propres de Mortal Shell II, dont aucun
binaire n'est disponible dans ce prototype. Une table d'import ne révèle pas non
plus toutes les fonctions recherchées dynamiquement ou les exigences du pont hôte.

Le décodage statique des mêmes fichiers, aux empreintes inchangées, relève 74
entrées `RUNTIME_FUNCTION`, toutes en V1 avec flags zéro. Leurs tables déclarent
54 `ALLOC_SMALL`, 74 `PUSH_NONVOL` et deux `ALLOC_LARGE`, sans gestionnaire ni
chaîne déclarés. Ces opérations ont guidé le sous-ensemble de reconstruction
décrit ci-dessus ; les contextes des DLL Apple n'ont pas été reconstruits. Cela ne prouve pas l'absence d'exceptions ou de tables
dynamiques. La preuve détaillée est `work/apple-pe-unwind-metadata.json` ; le
décodeur est couvert par 32 tests de fichiers synthétiques inertes.

Le 26 octobre, une lecture statique supplémentaire de DXGI avec Apple LLVM
21.0.0 a relevé onze références IAT ciblées : deux appels à VirtualAlloc/Free
et neuf sauts vers des imports. Dans les deux wrappers mémoire observés, les
arguments sont chargés depuis un enregistrement fourni ; les valeurs de cet
enregistrement restent inconnues. Les adresses des relais d'événements et de
sémaphores figurent dans une table de données, sans établir les valeurs des
droits, délais ou compteurs. Rien ne justifie donc d'élargir automatiquement les
formes mémoire, les droits ou les délais du prototype.

Les octets et les cibles IAT des onze instructions ont été comparés au fichier
réhaché. Les fenêtres de désassemblage servent de preuves locales ; elles ne
constituent pas une analyse complète des fonctions ou du flot de contrôle.
`work/dxgi-iat-callsite-evidence.json` et
`work/dxgi-static-argument-assessment.json` conservent les adresses, octets,
empreintes, commandes et limites. La première extraction vide est conservée
séparément ; elle a été corrigée en décodant directement les déplacements des
instructions. Aucun code de cette DLL n'a été exécuté.

## Références primaires

- [Microsoft : format PE](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format).
- [Microsoft : convention d'appel x64](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170).
- [Clang : attribut ms_abi](https://clang.llvm.org/docs/AttributeReference.html#ms-abi).
- [Apple : environnement Rosetta](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment).
- [Microsoft : QPC et mesure du temps](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).
- [Microsoft : format FILETIME](https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-filetime).
- [Microsoft : GetModuleHandleA](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandlea).
- [Microsoft : GetProcAddress](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress).
- [Microsoft : DllMain](https://learn.microsoft.com/en-us/windows/win32/dlls/dllmain).
- [Microsoft : exceptions et unwind x64](https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64).
- [Microsoft : prologues et épilogues x64](https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog).
- [Microsoft : VirtualProtect](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect).
- [Microsoft : VirtualAlloc](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc).
- [Microsoft : VirtualFree](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualfree).
- [Microsoft : CreateEventExA](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventexa).
- [Microsoft : SetEvent](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setevent).
- [Microsoft : ResetEvent](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-resetevent).
- [Microsoft : WaitForSingleObject](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject).
- [Microsoft : CloseHandle](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-closehandle).
- [Microsoft : DuplicateHandle](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle).
- [Microsoft : CreateSemaphoreExA](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsemaphoreexa).
- [Microsoft : ReleaseSemaphore](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-releasesemaphore).
- [Microsoft : droits des objets de synchronisation](https://learn.microsoft.com/en-us/windows/win32/sync/synchronization-object-security-and-access-rights).
- [Microsoft : pages et granularité d'allocation](https://learn.microsoft.com/en-us/windows/win32/memory/comparing-memory-allocation-methods).
- [Microsoft : constantes de protection](https://learn.microsoft.com/en-us/windows/win32/memory/memory-protection-constants).
- [Microsoft : NtQueryVirtualMemory](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntqueryvirtualmemory).
- [Microsoft : MEMORY_BASIC_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-memory_basic_information).
- [The Open Group : mprotect, édition consultée](https://pubs.opengroup.org/onlinepubs/7908799/xsh/mprotect.html).
- [Apple : mprotect](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mprotect.2.html).
- [Apple : munmap](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/munmap.2.html).
- [Apple : attente pthread relative dans libpthread](https://github.com/apple-oss-distributions/libpthread/blob/main/include/pthread/pthread.h).
- [Apple : état d'annulation pthread](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/pthread_setcancelstate.3.html).
