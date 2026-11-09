# Analyse Statique & Dépendances : Go Next! Demo (Mixidev)

Ce document formalise l'inventaire statique et les exigences d'exécution Windows pour la démo du jeu **Go Next!**, préparée pour le projet **Playmelt** (`MetalMax Gaming Hub`).

---

## 1. Provenance et Intégrité des Fichiers

* **Source** : Client Valve Steam natif authentifié (`download_depot`).
* **App ID** : `5066300` (*Go Next! Demo*).
* **Depot ID** : `5066301` (Édition Windows x86_64).
* **Manifest GID** : `6711404799512660565` (Branche `public`, build `26464252`).
* **Emplacement préparé** : `/Users/robtech/Library/Application Support/Playmelt/Games/GoNext/Windows`.
* **Volume** : 39 fichiers réguliers, 12 répertoires, **787 708 614 octets** (conforme au centime d'octet près au manifeste Valve).
* **Reçu d'intégrité** : [`work/gonext-installed-files.json`](file:///Users/robtech/03_PROJECTS/0%20-%207AGENCY%20Projet/1%20-%20APP/MetalMax%20Gaming%20Hub/work/gonext-installed-files.json).
* **Inventaire PE brut** : [`work/gonext-pe-inspection.json`](file:///Users/robtech/03_PROJECTS/0%20-%207AGENCY%20Projet/1%20-%20APP/MetalMax%20Gaming%20Hub/work/gonext-pe-inspection.json).

---

## 2. Architecture des Exécutables et Binaires (PE)

Le jeu est développé sous **Unity Engine** avec le backend de compilation C# **IL2CPP**.
L'inspection exhaustive relève **10 binaires PE Windows x86_64** :

| Binaire | Type | Taille | TLS statique | Dépendances directes |
|---|---|---|---|---|
| `Go Next demo.exe` | Exécutable principal | 667 Ko | Non | `UnityPlayer.dll` (symbole `UnityMain2`), `KERNEL32.dll` (71 symboles) |
| `UnityPlayer.dll` | Cœur du moteur Unity | 36,6 Mo | Oui (368 B, **2 callbacks**) | 28 DLLs (557 symboles), Delay-load D3D12 |
| `GameAssembly.dll` | Code gameplay IL2CPP | 95,4 Mo | Oui (8 B, 0 callback) | 15 DLLs (249 symboles dont `baselib.dll`) |
| `baselib.dll` | Primitives système Unity | 239 Ko | Oui | 3 DLLs (129 symboles KERNEL32/synch) |
| `D3D12/D3D12Core.dll` | Agility SDK DirectX 12 | 4,7 Mo | Oui (1 callback) | 45 jeux d'API-MS (229 symboles) |
| `dstorage.dll` | Microsoft DirectStorage | 206 Ko | Non | 22 DLLs (85 symboles) |
| `dstoragecore.dll` | DirectStorage Core | 1,4 Mo | Oui | 37 DLLs (161 symboles) |
| `steam_api64.dll` | Wrapper Steamworks | 319 Ko | Oui | 3 DLLs (92 symboles) |
| `lib_burst_generated.dll` | Calcul vectoriel Unity Burst | 458 Ko | Non | **0 import** (code purement autonome) |
| `UnityCrashHandler64.exe` | Gestionnaire d'incidents | 1,6 Mo | Oui (2 callbacks) | 13 DLLs (211 symboles) |

Total des symboles uniques identifiés dans l'arbre d'exécution : **928 symboles distincts** répartis sur **82 modules / api-ms DLLs**.

---

## 3. Les 6 Chantiers Techniques pour le Chargeur Playmelt

Pour faire tourner ce jeu sur Apple Silicon via le moteur hôte natif de Playmelt (sans Wine), voici les briques indispensables à combler :

### Brique 1 : Support de l'Unwind Metadata Version 2 et Changement d'Échelle
* **Constat** : Le décodeur actuel `pe_unwind.py` de Playmelt refuse tout format autre que la version 1 (`require(version == 1)`) et limite la table à 8 192 fonctions.
* **Réalité du jeu** : 
  * `Go Next demo.exe` contient des blocs d'unwind x64 en **Version 2** (encodage compact pour les épilogues introduit dans les versions récentes de MSVC/Clang).
  * `UnityPlayer.dll` contient **111 818 entrées de fonctions** dans sa table d'exceptions.
* **Action Playmelt** : Étendre le décodeur pour accepter la spécification AMD64 Unwind v2 et dimensionner la mémoire pour supporter >120 000 entrées RUNTIME_FUNCTION.

### Brique 2 : Exécution des Callbacks TLS
* **Constat** : Le prototype TLS actuel de Playmelt (`TLS_PROBE`) valide la copie du gabarit statique et l'accès via le segment `GS`, mais **refuse strictement les callbacks non nuls**.
* **Réalité du jeu** : `UnityPlayer.dll` et `D3D12Core.dll` déclarent des callbacks TLS obligatoires exécutables (`DLL_PROCESS_ATTACH` / `DLL_THREAD_ATTACH`) qui doivent s'exécuter avant le point d'entrée.

### Brique 3 : Implémentation du Sous-système Win32
L'inspection relève 928 symboles nécessaires. Les familles prioritaires sont :
1. **Windowing & Messages (`USER32.dll` - 134 symboles)** : `CreateWindowExW`, `DefWindowProcW`, `PeekMessageW`, `GetMessageW`, `DispatchMessageW`, gestion du curseur (`ShowCursor`, `ClipCursor`), redimensionnement.
2. **Entrées Manettes / Périphériques (`HID.DLL` - 14 symboles)** : Support DirectInput / Raw Input / XInput pour la détection du contrôleur.
3. **Synchronisation Windows moderne (`api-ms-win-core-synch-l1-2-0.dll`)** : Primitives `WaitOnAddress`, `WakeByAddressSingle`, `WakeByAddressAll` utilisées intensivement par le threading Unity.
4. **Fichiers & DirectStorage (`api-ms-win-core-file-l1-1-0.dll`, `dstorage.dll`)** : Lecture asynchrone IOCP (`CreateIoCompletionPort`, `GetOverlappedResultEx`).

### Brique 4 : Pont Graphique DirectX 11 / 12 vers Metal
* Le moteur graphique du jeu (`boot.config`) est configuré en :
  * `gfx-threading-mode=4` (Rendu multi-threadé avec jobs graphiques natifs).
  * `gfx-enable-gfx-jobs=1`.
* Il utilise `dxgi.dll` (`CreateDXGIFactory2`), `d3d11.dll` (`D3D11CreateDevice`) et dispose du runtime complet `D3D12/D3D12Core.dll` (Agility SDK).
* **Action Playmelt** : Raccorder la couche `d3dmetal` ou `dxmt` existante au chargeur pour fournir une implémentation virtuelle de `IDXGIFactory`, `ID3D11Device` ou `ID3D12Device` s'appuyant sur Apple Metal et `CAMetalLayer`.

### Brique 5 : Initialisation IL2CPP / C++ Runtime
* `GameAssembly.dll` (95 Mo) contient la totalité du code C# compilé du jeu en C++. Son initialisation dépend de `UnityPlayer!UnityMain2` et de `baselib.dll`.

### Brique 6 : Bridge Steamworks
* Présence de `Go Next demo_Data/Plugins/x86_64/steam_api64.dll`.
* Nécessite la transmission de l'AppID (`5066300`) au runtime Steam pour initialiser correctement les callbacks de succès et de statistiques.
