# Prototype PE64 et appels Win64 sur macOS

Ce prototype charge et exécute **uniquement notre petit programme PE synthétique**
dans un hôte macOS x86_64. Il n'utilise ni Wine ni machine virtuelle. Sur Apple
Silicon, le processus x86_64 passe par Rosetta : ce n'est pas une exécution ARM64
native du code Windows. Le prototype n'est pas intégré au bouton Jouer de Playmelt.

## Ce qui est implémenté

`pe_loader.c` prépare une image PE32+ AMD64 en mémoire : validation des plages,
copie des sections et zéro initial, relocalisations DIR64/ABSOLUTE, liaison des
imports nommés par un resolver explicite, puis permissions par page. La mémoire
est d'abord en lecture/écriture, ensuite les sections de code passent en
lecture/exécution. Aucune page n'est simultanément accessible en écriture et
exécution. Un conflit de permissions entre sections partageant une page est refusé.

`pm_pe_load()` ne lance jamais le point d'entrée. Le harnais séparé `cpu_probe.c`
est le seul à l'appeler, sur les octets embarqués produits par `probe_fixture.py`.
Il n'accepte aucun chemin d'exécutable. `pm_pe_unload()` rapporte le résultat réel
de `munmap` ; en cas d'échec, le handle reste disponible pour un nouvel essai.

`winapi_subset.c` fournit sept fonctions via l'ABI Microsoft x64, uniquement pour
les noms précis de `kernel32.dll` ou `kernelbase.dll` :

| Fonction | Comportement actuel |
|---|---|
| `SetLastError`, `GetLastError` | Valeur distincte pour chaque thread hôte. Aucun TEB Windows n'est créé. |
| `GetCurrentProcessId` | Identifiant du processus hôte réel. |
| `QueryPerformanceCounter`, `QueryPerformanceFrequency` | Horloge continue macOS convertie en comptes ; fréquence exposée de 1 milliard de comptes/s, sans promesse de précision à la nanoseconde. |
| `GetTickCount64` | Temps de cette horloge en millisecondes, incluant la veille. |
| `GetSystemTimeAsFileTime` | Temps UTC dans le format Windows, unités de 100 ns depuis 1601. |

Les noms inconnus et les imports par ordinal sont refusés. Aucun succès fictif,
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

Les suites `test_pe_loader.c` et `test_winapi_subset.c` couvrent séparément les
rejets, les permissions, les allocations/libérations et les fonctions système.
La première utilise des doubles des appels mémoire, avec vérification
AddressSanitizer/UndefinedBehaviorSanitizer. Le harnais intégré utilise les vrais
appels mémoire de macOS. Aucun GPU, modèle d'inférence ou shader n'est lancé.

## Ce qui manque pour Mortal Shell II

Le sous-ensemble est volontairement étroit : fichier de 16 Mio maximum, image de
64 Mio maximum, 32 sections, 1 024 symboles importés, 4 096 relocalisations.
Seuls les répertoires import, relocalisation et IAT sont acceptés. TLS de
l'exécutable, gestion des exceptions/unwind, CRT, exports, ressources, DLL
chargées à la demande, API sets, mémoire/processus/threads Windows, Win32/NT,
audio, entrées, Steamworks et D3D12 ne sont pas implémentés. Certains sont refusés
explicitement dès le chargement. La fixture n'a pas été qualifiée sur Windows.

Ce code est un socle de recherche, pas un lanceur universel ni un environnement
sandboxé pour des exécutables non fiables. Le bouton Windows de Playmelt reste
indisponible et sa protection des rendus reste indépendante du prototype.
L'exécutable de Mortal Shell II n'a été ni chargé ni lancé.

## Références primaires

- [Microsoft : format PE](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format).
- [Microsoft : convention d'appel x64](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170).
- [Clang : attribut ms_abi](https://clang.llvm.org/docs/AttributeReference.html#ms-abi).
- [Apple : environnement Rosetta](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment).
- [Microsoft : QPC et mesure du temps](https://learn.microsoft.com/en-us/windows/win32/sysinfo/acquiring-high-resolution-time-stamps).
- [Microsoft : format FILETIME](https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-filetime).
