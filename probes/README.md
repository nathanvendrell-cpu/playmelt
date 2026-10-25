# Playmelt · D3DMetal

Contrat technique de l’import Apple facultatif et de la future sonde DirectX 12.

| Vérification | État au 25 octobre 2026 |
| --- | --- |
| Import, transaction, chemins et plan isolé | 75 contrôles sur fichiers synthétiques : PASS |
| Compilation Swift de cette suite | PASS |
| Import d’un véritable téléchargement Apple | 4.0 bêta 3 importée via l’application ; 17 fichiers et 7 liens vérifiés |
| Préparation du préfixe et Steam DirectX 12 | Parcours implémenté, 148 contrôles de préparation PASS avec exécuteur Wine simulé ; pas exécutée sur le Wine réel |
| `d3dmetal-probe.cpp` | Source uniquement ; ni compilée ni exécutée |
| ABI entre le Wine retenu et D3DMetal | Non qualifiée |
| Chargement, création de périphérique GPU, jeu et performances | Non testés |

## Reproduire les contrôles

Depuis la racine du dépôt, avec le compilateur Swift macOS :

```sh
mkdir -p Products.noindex
swiftc RuntimeSetup.swift D3DMetalStore.swift tests/D3DMetalStoreTests.swift -o Products.noindex/d3dmetal-store-tests
Products.noindex/d3dmetal-store-tests
```

Résultat attendu : `D3DMetalStore fixtures: 75 PASS`. La suite génère des en-têtes PE et Mach-O artificiels dans son propre dossier temporaire sous `Products.noindex`, puis le nettoie. Elle ne lance ni Wine, ni réseau, ni GPU et n’utilise aucun binaire Apple. Elle couvre notamment les trois layouts, le refus des fichiers invalides, les verrous FIFO/liens/permissions, le rollback d’un échec d’écriture du reçu, l’idempotence, la préservation d’un import différent, les alias modifiés, les dépendances inconnues et les réponses de sonde périmées ou incohérentes.

## Dispositions de fichiers reconnues

Le dossier sélectionné doit contenir l’une des racines suivantes :

| Sélection | Racine normalisée |
| --- | --- |
| Dossier contenant `redist/lib/` | `redist/lib/` |
| Dossier contenant `lib/` | `lib/` |
| Dossier contenant directement `wine/` et `external/` | Le dossier sélectionné |

Chaque racine doit fournir `wine/x86_64-windows/{d3d11,d3d12,dxgi}.dll`, les ponts correspondants `wine/x86_64-unix/*.so`, et `external/D3DMetal.framework`. Les ponts Unix peuvent être des liens relatifs vers `external/libd3dshared.dylib` ; leurs cibles Mach-O et les autres dylib externes sont inspectées, avec résolution de `@loader_path` depuis la cible réelle. Les fichiers facultatifs `d3d10core`, `d3d12core` et `d3dshared` sont contrôlés s’ils existent. Le framework peut être plat ou utiliser `Versions/A/` et ses alias relatifs internes. Les en-têtes PE x64, Mach-O x86_64, commandes de chargement, tailles, dépendances, liens et empreintes sont inspectés sans chargement dynamique. Cette structure ne prouve ni l’origine Apple ni un droit d’utilisation.

Les notices `License.rtf` et `Acknowledgements.rtf` présentes dans le dossier sélectionné sont conservées sous `notices/` et incluses dans les empreintes. Aucun dossier parent n’est parcouru pour les trouver. Les adaptateurs `nvngx-on-metalfx` et `nvapi64` ne sont pas importés.

L’import reste unique : même contenu = opération idempotente ; contenu différent = refus sans remplacement. Le reçu est écrit dans le staging avant le renommage atomique du répertoire complet. Les fichiers d’applications tierces, les bouteilles et les overlays DXMT sont refusés. Playmelt ne télécharge, ne redistribue et ne modifie aucun binaire Apple ; il n’accepte aucune licence à la place de l’utilisateur.

## Plan de lancement et limites

`D3DMetalStore.launchPlan` prépare un préfixe `Runtime/D3DMetal/prefix` distinct du préfixe DXMT. Son environnement utilise uniquement l’overlay Apple dans `WINEDLLPATH_PREPEND`, le répertoire `external` dans les chemins de recherche natifs et la variable amont `CX_D3DMETALPATH`. Ce nom de variable appartient au contrat du pont ; il n’implique aucun accès à une installation CrossOver.

Le plan n’ajoute aucun fallback DXMT, y compris en 32 bits : le chemin graphique 32 bits et le client Steam de ce préfixe restent à qualifier. Les dépendances natives non résolues bloquent le plan. La présence des fichiers ne valide pas leur ABI avec Wine 10. `canExecute` reste faux ; aucun import ne rend un jeu lançable. Les profils centraux réservent DirectX 12/D3DMetal à Mortal Shell II (`2584270`) et DirectX 11/DXMT à Satisfactory (`526870`). Cela exprime un besoin de moteur, pas une compatibilité démontrée.

## Préparation du préfixe et protection des rendus

« Rendus en cours » est activé par défaut et enregistré dans les préférences. Le bridge natif refuse préparation Wine, installation Steam, installation et lancement de jeux tant qu’il reste actif. Le changement doit être confirmé par le natif avant que l’interface débloque les actions. Réactiver la protection annule les opérations de préparation et le lancement automatique en attente, sans arrêter un jeu, un client déjà ouvert ou un rendu externe.

Après désactivation explicite, le parcours proposé est : **Préparer DirectX 12 → Installer Steam → Installer le jeu**. `SteamWindowsBootstrap` lie le téléchargement officiel au descripteur et au préfixe sélectionnés ; une modification du moteur pendant le téléchargement fait échouer la demande. L’installateur Steam et sa connexion restent des étapes officielles interactives.

`D3DMetalRuntime` vérifie les empreintes de l’import, les dépendances, l’export `_macdrv_functions` et le chargement d’overlay `WINEDLLPATH_PREPEND` avant une éventuelle initialisation. Ces deux prérequis ont été trouvés par inspection statique du Wine installé ; ils ne prouvent pas la compatibilité de structure du contrat ABI. Un verrou exclusif, un contrôle de disque et la propriété du préfixe empêchent de réinitialiser des données existantes inconnues.

La préparation utilise `wineboot -u`, puis `wineserver -k` et `-w` avec le seul `WINEPREFIX` isolé. Durées et sorties sont bornées ; les deux étapes de fermeture sont tentées même après échec ou annulation. Le reçu de préparation n’est créé qu’après fermeture confirmée, validation des fichiers Windows et stabilité des identités. Les données partielles et caches sont conservés. Les notifications et relances de l’application ne réexécutent ni Wine ni un hachage intégral du paquet.

Le descripteur préparé permet de configurer Steam dans ce préfixe, mais ne qualifie aucun lancement graphique : tous les jeux sur cette route restent bloqués tant que `graphicsValidated` est faux. Mortal Shell II ne peut pas être envoyé au moteur DXMT, même en installation. Aucun de ces appels Wine ou Steam n’a été exécuté pendant les rendus.

Suite CPU de préparation, avec tous les appels Wine simulés :

```sh
swiftc RuntimeSetup.swift D3DMetalStore.swift D3DMetalRuntime.swift tests/D3DMetalRuntimeTests.swift -o Products.noindex/d3dmetal-runtime-tests
Products.noindex/d3dmetal-runtime-tests
```

Cette suite inclut un petit processus shell réel à sortie continue pour vérifier délai, arrêt et récupération du processus enfant. Elle ne crée aucun périphérique graphique.

## Future sonde : preuves requises

`prepareProbe` prépare un nonce et lie les empreintes de la sonde, de l’import et du moteur. Il n’exécute rien. La source C++ exige un SDK Windows x86_64 ; aucune commande de compilation Windows n’est présentée comme validée ici.

Un futur exécuteur devra, après autorisation explicite d’un test GPU :

1. Initialiser le préfixe D3DMetal isolé, vérifier son état inactif et exécuter exactement le binaire et l’environnement contrôlés.
2. Borner la durée et les sorties, corréler nonce, code de sortie et empreintes, puis terminer et récollecter uniquement ses propres processus.
3. Prouver les images PE et Mach-O réellement chargées, dont le framework D3DMetal importé, par une observation indépendante du processus hôte. `GetModuleFileNameW` peut retourner un chemin logique `C:\windows\system32` pour un overlay Wine : ce chemin seul ne distingue pas Apple d’un builtin ou de vkd3d.
4. Confirmer la création effective d’un périphérique DirectX 12 sur un adaptateur non logiciel. Une telle preuve ne validerait toujours ni un jeu ni ses performances.

Aujourd’hui, `validateProbeResponse` vérifie uniquement le contrat JSON et ses liens aux empreintes. Même une réponse conforme renvoie `probeResponseValidated=true`, **`loadTested=false` et `routeEnabled=false`**. Elle ne modifie pas l’état de qualification de l’import. Aucun exécuteur de sonde ni mécanisme d’activation automatique n’est implémenté.

## Sources épinglées

- [Apple — formule Game Porting Toolkit](https://github.com/apple/homebrew-apple/blob/2bc44284e24d39ed64d6f492a0e1f4c47a5ced08/Formula/game-porting-toolkit.rb), commit `2bc44284e24d39ed64d6f492a0e1f4c47a5ced08`. Cette formule décrit la version historique 1.1 ; elle ne constitue pas une spécification du GPTK 4 actuel.
- [Highball — environnement de bouteille](https://github.com/gauthierpiarrette/highball/blob/bbada878d142521a3267f0818a09cd62111b5789/Sources/HighballKit/Bottle.swift), commit `bbada878d142521a3267f0818a09cd62111b5789` : chemins du pont et variables d’environnement. Son fallback DXMT 32 bits n’est pas repris dans le plan isolé actuel.
- [Highball — manifeste du moteur](https://github.com/gauthierpiarrette/highball/blob/bbada878d142521a3267f0818a09cd62111b5789/spike/engine-manifest.json), même commit : versions, composants et contraintes amont. Playmelt ne revendique pas la qualification du moteur complet `r28` à partir de ses seuls composants sélectionnés.

Ces références étayent le contrat de structure ; elles ne remplacent pas une preuve de chargement avec les fichiers effectivement importés.

## Import officiel du 25 octobre 2026

Paquet 4.0 bêta 3 téléchargé depuis Apple Developer après connexion de l’utilisateur ; licence acceptée par l’utilisateur dans la fenêtre Apple. SHA-256 du DMG : `afa311da371f5b6dd970b45378a3d3df567cc9e535818f56f9b3f9d4c9537c1d`. L’import local occupe 71 001 933 octets, contient 17 fichiers contrôlés et 7 liens internes ; le framework indique `4.0b3`. Dix entrées Mach-O, dont les alias des ponts, ont été inspectées sans chargement. Le paquet et les binaires propriétaires restent hors du dépôt. Cette vérification est statique : l’ABI Wine, la création de périphérique, les shaders et Mortal Shell II restent non testés.
