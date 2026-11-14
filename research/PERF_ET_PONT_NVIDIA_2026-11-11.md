# Playmelt — Performance en jeu et pont NVIDIA (DLSS → MetalFX)

Analyse du 11 novembre 2026. Portée : diagnostic et feuille de route. Aucun
fichier de code n'a été modifié par ce document. Toutes les mesures citées
proviennent des reçus du dépôt (`Products.noindex/game-settings-qa/`, `probes/`)
ou de sources externes référencées en fin de document.

---

## 1. État des lieux

### Architecture de production

- **Route DX12** : Wine 10 (x86_64 sous Rosetta) + **D3DMetal 4.0 bêta 3**
  (GPTK 4.0b3 du 20 oct. 2026, import utilisateur vérifié par SHA-256,
  17 fichiers + 7 liens). Préfixe isolé par jeu, receipts de préparation,
  verrous flock, politique de render-protection.
- **Route DX11** : DXMT (`playmelt-wine10-dxmt-20261017`), qui embarque ses
  propres `nvapi64.dll` (1,9 Mo) et `nvngx.dll` (1,6 Mo).
- **Profil dédié Spider-Man 2** (appid 2651280) : `spiderman2_profile.py`,
  réglages écrits en transaction dans `user.reg` (FSR, FrameGen, écran…),
  import de sauvegardes, journal de crash, mode **msync qualifié** pour une
  paire exacte engine/renderer (hash-pinnée).
- **Briques graphiques Playmelt (non connectées au jeu)** :
  `GraphicsFeatureContract` (contrat de descripteurs, 9 features),
  `GraphicsFrameAdapter` (conversions CPU couleur/motion/depth),
  `MetalFXFrameAdapter` (vrai `MTLFXTemporalScaler` fonctionnel,
  `gameFrameProviderConnected: false`), `GraphicsMemoryBudget`
  (comptabilité mémoire Playmelt-side).

### Mesures existantes (M3 Max 40 cœurs GPU, macOS 27.0.1)

| Source | Mesure |
|---|---|
| `performance-observation.json` | SM2 réglages max 2048×1152 : **21,4–30 FPS, médiane 26,8** (journal moteur épars) |
| `metal-qhd-01/analysis.json` | Fenêtre 2560×1600 : **43,83 FPS présentés**, GPU **20,05 ms/frame** en moyenne (627 échantillons) |
| `baseline-gpu-ioreg.txt` | Pendant le jeu : Tiler 65 %, Renderer 65 %, Device 68 %, wine pid avec 21 files Metal |
| `baseline-spiderman.sample.txt` | Empreinte mémoire wine **24,2 Go** ; thread dans `__wine_syscall_dispatcher` ; MetalFX 40.8 chargé |
| `draft-pr-current.md` | Sync A/B/A ≈ **485 / 60 / 486 ms** pour 20 000 échanges (msync ≈ 3 µs/échange, ~8× moins que hors msync) ; « ne prédit pas les FPS » |
| `dstorage-result.json` | Isolé : `dstoragecore.dll` **absent**, GetFactory → `0x80004001` |
| `dstorage-adjacent-result.json` | Adjacent à l'exe : GetFactory → **S_OK**, file créée (CPU only, pas GPU) |
| `probes/metal-native-capabilities.swift` | M3 Max annonce les **4 capacités MetalFX** (spatial, temporal, temporalDenoised, frameInterpolation) |

Retour utilisateur consigné : « Cinematics very good ; gameplay needs further
fluidity and performance tuning ». Exigence de la baseline max :
« NO graphics/display quality changes. Engine/code optimization only. »

---

## 2. Diagnostic performance

Le GPU n'est **pas saturé** (~65–68 %). Le temps se perd en amont :

1. **CPU traduit (Rosetta + Wine)** — goulot principal. Chaque syscall, chaque
   fixme logué, chaque sync primitive passe par la traduction. À ~26 FPS en
   max-settings, le frame budget est ~37 ms ; la part CPU traduite est
   majoritaire.
2. **DirectStorage non initialisé dans le jeu** — `dstoragecore.dll` absent de
   l'emplacement que le jeu sonde ; le streaming d'assets retombe sur un chemin
   de repli (hitching en déplacement rapide / cinématiques de traversée). La
   preuve adjacente montre que la DLL fonctionne dès qu'elle est trouvée.
3. **Compilation de shaders au premier run** — GPTK 4 a une compilation en deux
   phases (fast-path immédiat + optimiseur asynchrone) : la première session
   stutter, les suivantes sont propres (cache format nouveau, non réutilisé
   depuis GPTK 3). À documenter comme comportement attendu, pas comme régression.
4. **VSync sur écran 60 Hz** — l'écran externe principal est 60 Hz : un jeu qui
   ne tient pas 60 se verrouille à 30. L'écran interne est 120 Hz.
5. **Mémoire** — 24,2 Go pour SM2 en textures max ; sur machine 36 Go la
   pression unifiée devient un facteur (swap = saccades).

---

## 3. Plan d'optimisation performance (indépendant du pont NVIDIA)

Classé par impact attendu / effort.

### P1 — DirectStorage (impact fort sur le hitching, effort faible)
- Fournir `dstoragecore.dll`/`DStorageCore.dll` **à côté de l'exe du jeu**
  (le PE n'exporte ni `DStorageSDKPath` ni `DStorageSDKVersion` — le placement
  adjacent est la seule voie, cf. `probes/dstorage-diagnostic.md`).
- Intégrer au profil SM2 (même régime que les autres fichiers hash-pinnés :
  SHA-256 consigné, préfixe vérifié idle, rollback).
- Qualification : rejouer la collecte Metal QHD et comparer les statistiques
  de copie/streaming, pas seulement les FPS.

### P2 — Réduire le coût CPU traduit
- `WINEDEBUG=-all` dans les scripts de lancement de production (au lieu de
  `fixme-all`) : les fixme coûtent du CPU Rosetta à chaque appel.
- Garder **msync** sur la paire qualifiée ; ajouter une mesure A/B **en FPS
  réels** (le microbenchmark ne prédit pas les FPS — verrouiller cette
  décision sur du jeu, pas sur du synthétique).
- `ROSETTA_ADVERTISE_AVX=1` : déjà en place pour SM2 ; étendre la liste aux
  jeux dont le moteur tolère AVX (à qualifier par jeu).

### P3 — Politique écran / vsync / cap
- Exposer dans les réglages : cap dynamique 30/45/60 **décorrélé de la vsync**,
  recommandation 120 Hz (écran interne) pour les modes FrameGen.
- Documenter le verrouillage 60→30 Hz de la vsync sur l'écran externe.

### P4 — Mémoire
- SM2 : proposer un preset « High » (au lieu de « Very High ») quand la RAM
  totale ≤ 36 Go — réduit l'empreinte de plusieurs Go sans toucher au rendu
  perçu autant que le streaming.
- `GraphicsMemoryBudget` reste Playmelt-side : le brancher sur l'allocateur du
  futur renderer natif/compagnon, pas prétendre contrôler le jeu.

### P5 — Mesures manquantes (outillage)
- Powermetrics sans sudo interractif (fichier de droits ou collecte guidée) :
  la puissance/thermique est le seul axe jamais instrumenté.
- Metal System Trace finalisée (la seule trace collectée a timeout et a été
  écartée) — nécessaire pour objectiver les files Metal du pid wine.

---

## 4. Technologies NVIDIA : la traduction existe déjà — dans le payload Apple

### 4.1 Le mécanisme (preuve binaire + comportement documenté GPTK 4)

`nvngx-on-metalfx` est un **remplacement direct du NGX SDK NVIDIA** livré par
Apple dans le redist GPTK 4 :

- Exporte la **surface NGX DX12 complète** (`NVSDK_NGX_D3D12_Init`,
  `CreateFeature`, `EvaluateFeature`, `GetCapabilityParameters`, callbacks DLSS
  d'optimal settings…).
- Implémente **`NVSDK_NGX_Feature_SuperSampling`** → MetalFX Temporal, et
  **`NVSDK_NGX_Feature_FrameGeneration`** → l'interpolateur de frames Metal 4
  (`MTLFrameInterpolationDescriptor`, moteur neuronal Apple).
- La DLL du jeu tourne inchangée : le shim est substitué quand le jeu charge
  `nvngx.dll` ; DLSS 4 (transformer) retombe sur le comportement DLSS 3.
- Frame Generation nécessite macOS 26+ ; DLSS SR fonctionne aussi sur la route
  DXMT selon CodeWeavers.
- Référence de résultat : Cyberpunk 2077 **M3 Max** (même GPU que la machine
  cible) : ~45 FPS rendus → **~90 FPS présentés** avec DLSS Quality + FG.

Le `D3DMetal.framework` **déjà importé par Playmelt** contient la surface
`NvAPI_*` complète et lit **`D3DM_ENABLE_METALFX`** et **`D3DM_NVNGX_PATH`**
(vérifié par `strings` sur le binaire installé).

### 4.2 Ce que Playmelt exclut aujourd'hui (décision produit documentée)

- `D3DMetalStore.inspectFiles` (`D3DMetalStore.swift:292-301`) n'importe que
  `d3d11/d3d12/dxgi` (+ `d3d10core/d3d12core/d3dshared`) : **ni `nvngx`, ni
  `nvapi64`, ni `nvngx-on-metalfx`**.
- Le test `tests/D3DMetalStoreTests.swift:223` verrouille cette exclusion :
  `"NVIDIA shims not imported"`.
- Les `nvapi64.dll`/`nvngx.dll` de 1 032 octets dans les `system32` des
  préfixes sont des **stubs Wine**, pas le pont Apple.
- Les scripts de lancement (`Core.swift:469-495`) : pas de
  `D3DM_ENABLE_METALFX=1`, pas d'override `nvapi64,nvngx=b,n` sur la route
  D3DMetal (la route DXMT a `nvapi64=n,b` vers le shim DXMT).
- `GameSettings.swift:110` : la validation n'accepte que `upscaler: "fsr"`.
- SM2 : `spiderman2_profile.py:194` force `UpscaleMethod=3` (FSR) ; le jeu
  embarque les vraies DLL NVIDIA (`nvngx_dlss.dll` 44,5 Mo, `nvngx_dlssd.dll`
  65,9 Mo, `nvngx_dlssg.dll` 7,6 Mo + Streamline `sl.dlss*.dll`).

### 4.3 Matrice de faisabilité « temps réel, sans détruire les performances »

| Technologie NVIDIA | Voie | Temps réel en jeu | Coût perf | Verdict |
|---|---|---|---|---|
| **DLSS Super Resolution** | Pont `nvngx-on-metalfx` (Apple) | **Oui** | **Négatif** : le rendu interne baisse (≈66 % en Quality → pixels ×0,44), le FPS monte | **À débloquer en priorité** |
| **DLSS Frame Generation** | Pont → interpolateur Metal 4 | **Oui** (macOS 26+, jeux DLSS 3+) | ~quelques ms Neural Engine, latence d'une frame | **À débloquer** (utile surtout à 120 Hz) |
| **Reflex** | `NvAPI_*` de D3DMetal.framework | Partiel / à tester | Nul | Tester par jeu |
| **DLSS Ray Reconstruction** (`nvngx_dlssd`) | ~~Aucune traduction~~ **Corrigé le 12/11 :** D3DMetal 4.0b3 traduit DLSSD → `MTLFXTemporalDenoisedScaler` (voir § 8) | À qualifier en jeu | 4,5–15 ms GPU selon mode (§ 8) | Route `d3dmetal-nv-rt` |
| **DLSS 5 Neural Rendering** | Port MLX-DLSS (projet frère) | **Non** (voir §5) | 20–70 ms/frame | Recherche offline |
| **FSR 3 / FG (natif jeux)** | Chemin compute D3DMetal existant | Déjà en prod (SM2) | Inclus | Conserver comme repli |

### 4.4 Plan de déblocage — 4 phases (fichiers touchés, sans y toucher ici)

**Phase A — Import du pont (D3DMetalStore)**
1. Ré-obtenir le redist **GPTK 4.0 bêta 3** (même build que le framework
   importé — l'ABI du pont doit correspondre au D3DMetal installé) ;
   l'utilisateur re-sélectionne le dossier Apple (régime licence inchangé :
   `licenseAcceptedByPlaymelt: false`, import local, SHA-256).
2. Étendre `inspectFiles` : `nvngx`/`nvapi64` (+ noms `nvngx-on-metalfx` selon
   le layout 4.0b3), en `x86_64-windows` (PE) et `x86_64-unix` (Mach-O).
3. Mettre à jour `tests/D3DMetalStoreTests.swift` (l'assertion d'exclusion
   devient une assertion de présence + hashes).

**Phase B — Environnement de lancement (Core.swift / D3DMetalStore.launchEnvironment)**
1. Route D3DMetal : `D3DM_ENABLE_METALFX=1`, `D3DM_NVNGX_PATH` → pont importé,
   `WINEDLLOVERRIDES` += `nvapi64,nvngx=b,n` (builtin Apple d'abord).
2. Jeux **Streamline** (SM2 : `sl.dlss.dll`) : le plugin charge
   `nvngx_dlss.dll` par nom. Stratégie par profil hash-pinné : remplacement
   transactionnel du `nvngx_dlss.dll` du jeu par le pont (sauvegarde +
   restauration, préfixe idle), **ou** conserver FSR natif pour SM2 et
   réserver le pont aux jeux DLSS-only. À décider jeu par jeu.
3. Renforcer `localGameEnvironmentExports` / gabarits de script v3.

**Phase C — Contrat et réglages (GraphicsFeatureContract / GameSettings)**
1. Déclarer le pont comme `BackendDeclaration` explicite : feature
   `nvidiaDLSSSuperResolution`, api `directX12` côté jeu, implémentation
   `appleMetalFXTemporal` côté Metal. Le contrat refuse aujourd'hui la
   conversion d'API implicite (`backendAPIMismatchNoAutomaticTranslation`) :
   ajouter une catégorie **« pont de traduction déclaré et qualifié »** —
   c'est exactement la « traduction » demandée, représentée honnêtement.
2. `GameSettings.swift` : accepter `upscaler: "dlss-metalfx"` (libellé honnête
   « DLSS → MetalFX ») quand le pont est importé et le jeu éligible ;
   `frameGeneration` exposé avec la contrainte écran 120 Hz documentée.
3. SM2 : vérifier le mapping `UpscaleMethod` (0–4) vers DLSS via le parseur de
   log existant (`[Settings] Upscale Method:`), pas par supposition.

**Phase D — Qualification (même rigueur que les reçus existants)**
- A/B/A par jeu : FSR natif / pont DLSS / pont DLSS+FG — FPS médiane, GPU ms,
  latence présentée, artefacts (capture d'écran de référence).
- Receipts JSON, jeu non relancé après chaque changement non qualifié,
  rollback prouvé. Seuil d'acceptation : pas de régression > 5 % hors mode
  activé, pas de crash, HUD Metal confirmant `MetalFX`.

---

## 5. DLSS 5 Neural Rendering : pourquoi pas en temps réel (aujourd'hui)

Chiffres du port MLX-DLSS (projet frère, poids réels, réseau seul, M2 Max
38 cœurs ; M3 Max ≈ 20–30 % plus rapide) :

| Réseau | 768×1024 | 1088×1920 | 1080p vidéo |
|---|---|---|---|
| HT 71 blocs | 52,6 ms | 134 ms | 6,2–6,3 fps |
| **Small 31 blocs** (défaut 310.9.16) | **27,5 ms** | **72,8 ms** | 9,9–10,2 fps |

- Ajouter ~20–70 ms GPU par frame à un jeu dont le budget est ~37 ms
  **détruirait les performances**, même avec les ~35 % de marge GPU.
- Les entrées NR (couleur jitterée, motion signée, depth, contrôles
  artistiques, compteur de bruit) ne sont accessibles qu'**in-process, dans la
  boucle de rendu du jeu** — le pont Apple ne fait pas NR, et une interception
  maison au niveau D3D12 est un projet en soi.
- La parité NVIDIA reste un gate non atteint côté MLX-DLSS (temporel partiel
  mesuré : MAE 0,0054/64 frames ; small sans capture vendor).

**Voie honnête pour NR (déjà outillée dans `research/dlss5`)** :
1. **Offline / qualité** : captures autorisées → `qualify.py prepare` →
   exécution MLX-DLSS → `compare` (seuils explicites). Mode « beauté »
   cinématique/capture, pas gameplay.
2. **Post-process compagnon** (plus tard) : capture ScreenCaptureKit →
   traitement MLX → présentation. Budget latence +20–50 ms : acceptable pour
   du visionnage, pas pour du jeu compétitif ; coût GPU à isoler via
   `GraphicsMemoryBudget`.
3. **Metal 4 `MTLMLComputePipeline`** (headers GPTK 4, accélérateurs neuraux
   M5) : piste future pour de l'inférence inline dans les shaders — à surveiller,
   pas à engager.

`MetalFXFrameAdapter` existant : le pont Apple le rend **inutile pour les jeux
Windows** (le pont fait le même travail in-process, mieux intégré). Le conserver
pour le futur renderer natif (recherche `windows_native`) / le post-traitement ;
ne pas le prioriser face au pont.

---

## 6. Risques et garde-fous

- **Licence** : importer `nvngx-on-metalfx` relève du même régime que D3DMetal
  (fichiers fournis par l'utilisateur, licence Apple acceptée par lui, pas de
  redistribution). Ne jamais extraire/redistribuer les DLL NVIDIA du jeu.
- **Honnêteté produit** : l'UI doit dire « DLSS → MetalFX », pas « DLSS »
  (la qualité d'image est celle de MetalFX Temporal, pas du modèle NVIDIA).
- **Anti-triche** : GPTK 4 améliore la gestion des vérifications EAC/BattlEye
  mais les jeux protégés restent à exclure des routes pont (comme aujourd'hui).
- **Qualification par jeu** : un jeu qui marche « de travers » avec le pont ne
  doit jamais basculer automatiquement ; receipt par jeu obligatoire (même
  philosophie que `SteamGameLaunchProfile` et les profils hash-pinnés).
- **Ne pas casser l'existant** : la route FSR native de SM2 reste le repli
  par défaut tant que le pont n'est pas qualifié sur ce jeu.

## 7. Estimation d'impact (SM2, M3 Max)

| Configuration | FPS rendu (est.) | FPS présenté (est.) | Base |
|---|---|---|---|
| Actuel max-settings TAA (mesuré) | ~27 (médiane) | ~27 | `performance-observation.json` |
| QHD fenêtré FSR (mesuré) | ~44 | ~44 | `metal-qhd-01` |
| DLSS→MetalFX Quality + P1/P2 | 45–60 | 45–60 | rendu ×0,44 pixels + réf. Cyberpunk M3 Max |
| Idem + Frame Generation (120 Hz) | 45–60 | 90–120 | réf. Cyberpunk M3 Max (~45→~90) |

Ce sont des estimations d'ordre de grandeur, à remplacer par la qualification
A/B de la phase D. Le gain décisif ne vient pas d'un seul levier mais de la
combinaison : **pont DLSS (montée du FPS) + DirectStorage (suppression du
hitching) + CPU traduit allégé (stabilité du frame pacing)**.

---

## Sources externes

- [Skyfire Works — What Actually Changed in GPTK 4](https://skyfireworks.io/velocity/gptk4) : nvngx-on-metalfx, surface NGX exportée, FG → MTLFrameInterpolationDescriptor, two-phase shader compilation, MTLStorageModeShared, réf. Cyberpunk M3 Max ~45→~90 FPS.
- [myByways — Updating CrossOver to GPTK 3.0](https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0/) : fichiers à copier, `D3DM_ENABLE_METALFX=1`, `WINEDLLOVERRIDES nvapi64,nvngx=b,n`.
- [CodeWeavers — Advanced Settings CrossOver 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26) : « DLSS powered by MetalFX », D3DMetal ou DXMT.
- [RipperMoonKit — clair-obscur-dlss-metalfx.md](https://github.com/MoonTheRipper/RipperMoonKit/blob/main/docs/clair-obscur-dlss-metalfx.md) : forme de lancement testée, popup driver NVIDIA (avertissement moteur UE, pas un vrai driver).
- [Apple — Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) : GPTK 4.0 / Metal 4.
- [NVIDIA — DLSS 5 research](https://research.nvidia.com/labs/adlr/DLSS5/) : définition NR (pas un upscaler).
- MLX-DLSS (projet frère) `README.md`, `docs/embedding.md` § Performance, `docs/recovery-notes.md` : coûts d'inférence mesurés, gates de parité.

---

## 8. Correctif et mesures du 12 novembre 2026

### Ray Reconstruction : la traduction existe dans D3DMetal 4.0b3

Lecture du binaire importé (`Renderers/D3DMetal/payload/external/D3DMetal.framework`,
contentHash du payload `00794464…ccc8`) : chaînes `DLSSD.SpecularHitDistance`,
`DLSSD.ColorBeforeParticles`, `RayReconstruction.Hint.Render.Preset.*`,
`SuperSamplingDenoising.Available`, classes `ngx::Denoiser` et
`MDETemporalDenoisedScaler` reliées à `newTemporalDenoisedScalerWithDevice:`, message
« Denoiser not present on this OS ». `libd3dshared.dylib` exporte toute la surface
`NVSDK_NGX_D3D12_*`. Le ray tracing DX12 est traduit (`D3D12RaytracingStateObject`,
`MapDXRInstanceDescsToMetalInstanceDescs`) et commandé par `D3DM_SUPPORT_DXR`.

Ce qui manque encore : le shim PE `nvngx-on-metalfx.dll` du redist GPTK 4 (pont non
installé sur le M3 au 12/11) et une qualification en jeu. Rien n'a été lancé en jeu.

Changements : route par jeu `d3dmetal-nv-rt` (= pont + `D3DM_SUPPORT_DXR=1`) ;
`MetalFXRayReconstructionAdapter` réécrit en API typée (matrices caméra, reset
d'historique, contrôle formats/usages/échelle), sans revendication Neural Engine.
Il reste hors du chemin des jeux Windows.

### Coût MetalFX seul, M3 Max, macOS 27.0.1 (`probes/metalfx-2k-4k-cost.swift`)

Médiane du temps GPU de 30 images après 10 de chauffe, textures privées. C'est le coût
de la traduction seule ; le rendu du jeu s'y ajoute.

| Sortie | Mode | Rendu interne | Super Resolution | Ray Reconstruction |
|---|---|---|---|---|
| 2K | Qualité | 1707×960 | 0,60 ms | 6,82 ms |
| 2K | Équilibré | 1488×837 | 0,53 ms | 5,62 ms |
| 2K | Performance | 1280×720 | 0,46 ms | 4,51 ms |
| 2K | Ultra perf. | 853×480 | 0,35 ms | 2,68 ms |
| 4K | Qualité | 2560×1440 | 1,35 ms | 15,22 ms |
| 4K | Équilibré | 2233×1256 | 1,18 ms | 12,62 ms |
| 4K | Performance | 1920×1080 | 1,06 ms | 10,15 ms |
| 4K | Ultra perf. | 1280×720 | 0,79 ms | 5,48 ms |

Le débruiteur n'accepte qu'une échelle exacte par configuration (×1,5 / ×1,72 / ×2 / ×3).
Conseils affichés dans les réglages (« Guide 2K / 4K ») : 2K sans RT → Qualité ;
2K avec RT → Performance ; 4K sans RT → Performance ; 4K avec RT → Ultra performance.
