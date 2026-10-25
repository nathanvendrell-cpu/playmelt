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
contexte. Il n'existe aucune inscription de mémoire empruntée ni implémentation
de `VirtualAlloc`/`VirtualFree` Windows. Le contexte doit être lié explicitement
au thread appelant ; allocation, libération et destruction sont interdites tant
qu'il est lié. La sortie du thread libère la liaison, puis le propriétaire doit
détruire le contexte. Une erreur de `munmap` conserve le handle pour réessayer.

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

La suite CPU compte **415 contrôles PASS** avec ASan/UBSan : protections macOS
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

Les 633 contrôles CPU ASan/UBSan passent, ainsi que les 415 contrôles de
`VirtualProtect`. Le harnais ci-dessous exécute cinq appels depuis un PE
synthétique, dont les arguments cinq et six placés sur la pile, puis compare
les résultats à vingt observations des protections Mach des régions détenues :

```sh
python3 -B research/windows_native/loader/run_memory_query_probe.py
```

Les preuves sont conservées dans `work/ntquery-memory-probe.json` et
`work/ntquery-memory-tests-initial.log`. Aucun jeu, autre exécutable ou composant
Apple n'est accepté par ce harnais ; toutes ses allocations et processus sont
nettoyés après exécution.

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
Seuls les répertoires export, import, relocalisation et IAT sont acceptés. Le
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
- [Microsoft : constantes de protection](https://learn.microsoft.com/en-us/windows/win32/memory/memory-protection-constants).
- [Microsoft : NtQueryVirtualMemory](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntqueryvirtualmemory).
- [Microsoft : MEMORY_BASIC_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-memory_basic_information).
- [The Open Group : mprotect, édition consultée](https://pubs.opengroup.org/onlinepubs/7908799/xsh/mprotect.html).
- [Apple : mprotect](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mprotect.2.html).
