# Brief Codex — déployer deux correctifs perf (Claude M3, 14/11/2026)

Réponds en français. Demande de Nathan (14/11, 00 h 40) : « vois avec codex pour deployer tes correctifs ».
Tu édites déjà ce dépôt : intègre ces deux correctifs à ton prochain build/installation, sans rien écraser.

## Ce que Claude a modifié (uniquement `Core.swift`, non commité)

1. `localGameEnvironmentExports` : pour FF7 Rebirth (`rebirth` ou `33e6ac38b5a14098b079fd62d71aabc6`),
   ajout de `export WINEESYNC="1"` après `WINEMSYNC="0"`.
2. `ensureLaunchScript` : `launchExecutable` est toujours le chemin absolu
   (`targetDir.appendingPathComponent(chosen).path`), plus deux conditions de régénération du lanceur
   (chemin absolu absent ; Rebirth sans `WINEESYNC="1"`).

Vérifier : `git diff -- Core.swift | grep -E 'ESYNC|launchExecutable|shellLiteral\(targetDir'`.
Sauvegarde des fichiers d'avant : dossier scratchpad de la session Claude (`backup/`).

## Preuves

- Mesure FPS : cause reproduite avec un Wine isolé — `wine relatif.exe` garde l'argument relatif,
  que `session_benchmark.py` refuse (`target_not_identified`, 14 sessions sur 15).
- Banc `Products.noindex/wine-sync-review/wine-sync-bench.exe`, préfixe jetable, 20 000 échanges :
  serveur 495–550 ms · esync 234–267 ms · msync 75 ms. Synthétique : ne prédit pas les FPS.
- Compilation hors dépôt (-Onone) à 00 h 32 puis `--self-test` : 245 passed, 0 failed ;
  `tests/session_benchmark_test.py` : OK. Ton travail a changé depuis : à rejouer.

## À faire

- Garder ces lignes de `Core.swift` dans ton build ; sauvegarder l'app installée avant de la remplacer.
- Après installation : rejouer les auto-tests ; lancer aucun jeu sans Nathan.
- Non testé en jeu : Rebirth sous esync (retour arrière = retirer la ligne `WINEESYNC="1"`).
- Spider-Man 2 (lanceur Python propre) n'est pas couvert par le correctif de mesure.

## Hors périmètre (pas fait, ne pas inventer)

Limite FPS / upscaling MetalFX DX11, pont DLSS→MetalFX, DirectStorage SM2, mode Jeu macOS.
