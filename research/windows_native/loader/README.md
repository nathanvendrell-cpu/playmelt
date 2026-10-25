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
est le seul à l'appeler, sur les octets embarqués produits par `probe_fixture.py`.
Il n'accepte aucun chemin d'exécutable. `pm_pe_unload()` rapporte le résultat réel
de `munmap` ; en cas d'échec, le handle reste disponible pour un nouvel essai.

Les DLL sont acceptées uniquement lorsque leur point d'entrée vaut zéro. Le
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

Les suites `test_pe_loader.c` et `test_winapi_subset.c` couvrent séparément les
rejets, les permissions, les allocations/libérations et les fonctions système.
La première utilise des doubles des appels mémoire, avec vérification
AddressSanitizer/UndefinedBehaviorSanitizer. Le harnais intégré utilise les vrais
appels mémoire de macOS. `test_pe_modules.c` couvre le registre avec des catalogues
simulés ; `test_probe_lifecycle.py` vérifie aussi le nettoyage d'un enfant qui
ignore SIGTERM après la sortie de son parent. Aucun GPU, modèle d'inférence ou shader n'est lancé.

## Ce qui manque pour Mortal Shell II

Le sous-ensemble est volontairement étroit : fichier de 16 Mio maximum, image de
64 Mio maximum, 32 sections, 1 024 symboles importés, 4 096 relocalisations.
Seuls les répertoires export, import, relocalisation et IAT sont acceptés. Le
registre ne charge que des images déjà préparées, sans initialisation DLL.
TLS de l'exécutable, gestion des exceptions/unwind, CRT, ressources, DLL
chargées à la demande, API sets, mémoire/processus/threads Windows, Win32/NT,
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
`VirtualProtect`, `RaiseException` et `NtQueryVirtualMemory`. Le registre de modules
prépare une partie de la résolution de symboles, mais n'implémente pas ces API
Windows. Les quatre DLL ont un point d'initialisation non nul et un répertoire
d'exceptions ; le chargeur actuel les refuse donc volontairement. DXGI dépend aussi
des fenêtres, écrans, événements, threads, sémaphores et du registre Windows.

La prochaine étape doit traiter les contrats de résolution de modules observés,
puis leur initialisation et leurs exceptions avec preuves CPU distinctes. Ces
imports ne décrivent pas les dépendances propres de Mortal Shell II, dont aucun
binaire n'est disponible dans ce prototype. Une table d'import ne révèle pas non
plus toutes les fonctions recherchées dynamiquement ou les exigences du pont hôte.

## Références primaires

- [Microsoft : format PE](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format).
- [Microsoft : convention d'appel x64](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170).
- [Clang : attribut ms_abi](https://clang.llvm.org/docs/AttributeReference.html#ms-abi).
- [Apple : environnement Rosetta](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment).
- [Microsoft : QPC et mesure du temps](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).
- [Microsoft : format FILETIME](https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-filetime).
